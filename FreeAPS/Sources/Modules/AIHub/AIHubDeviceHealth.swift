import CoreData
import Foundation
import UserNotifications

/// Sensor- & Patch-Gesundheit („Hardware-Check").
///
/// Phase 1:
/// - **Patch-Wechsel-Log**: `registerPatchActivation` wird vom
///   DeviceDataManager an der Stelle aufgerufen, an der pod-age.json
///   ohnehin geschrieben wird. Jede Änderung des Aktivierungsdatums ist
///   exakt der Wechsel-Zeitpunkt → lückenlose Historie ab Einbau
///   (Laufzeit-Drift-Analysen folgen in Phase 2, sobald 2–3 Wechsel da sind).
/// - **Setzstellen-Rotation**: 8 Stellen (Bauch/Oberarm/Oberschenkel/Po,
///   je links/rechts). Der Nutzer markiert seine genutzten Stellen und
///   trägt pro Patch die Stelle ein; Vorschlag = am längsten pausierte
///   Stelle. Beim erkannten Wechsel erinnert eine lokale Notification.
/// - **Nächtliche Kompressions-Lows**: steiler Abfall + schnelle
///   vollständige Erholung ohne Mahlzeit → Artefakt statt echte Hypo.
/// - **Sensor-Rauschen über die Laufzeit**: Sprungrate pro
///   Sensor-Laufzeit-Tag; Sensor-Historie kommt aus cgm-state.json
///   (dort landet jeder Sensor-Start als Treatment — rückwirkend nutzbar).
///
/// Muster wie die übrigen Module: alles lokal und deterministisch, die
/// KI-Einordnung optional und pro Tag/Periode gecacht.
enum AIHubDeviceHealth {
    // MARK: - Setzstellen

    enum Site: String, CaseIterable, Identifiable, Codable {
        case abdomenLeft
        case abdomenRight
        case armLeft
        case armRight
        case thighLeft
        case thighRight
        case buttockLeft
        case buttockRight

        var id: String { rawValue }
        var label: String { hubT("dh.site.\(rawValue)") }
    }

    /// Getrennte Rotations-Kreise: Pumpen-Patch und CGM-Sensor haben
    /// eigene Stellen-Sets, Logs und Vorschläge.
    enum DeviceKind: String {
        case patch
        case sensor
    }

    /// Vom Nutzer markierte, in der Rotation genutzte Stellen (pro Gerät).
    static func enabledSites(for kind: DeviceKind) -> Set<Site> {
        let raw = UserDefaults.standard.stringArray(forKey: "iAPS.aiHubSites.\(kind.rawValue)")
            // Migration: der erste Wurf kannte nur einen (Patch-)Kreis.
            ?? (kind == .patch ? UserDefaults.standard.stringArray(forKey: "iAPS.aiHubSites") : nil)
            ?? []
        return Set(raw.compactMap(Site.init(rawValue:)))
    }

    static func setEnabledSites(_ sites: Set<Site>, for kind: DeviceKind) {
        UserDefaults.standard.set(
            sites.map(\.rawValue).sorted(),
            forKey: "iAPS.aiHubSites.\(kind.rawValue)"
        )
    }

    // MARK: - Patch-Wechsel-Log

    struct PatchEvent: JSON, Equatable {
        let activatedAt: Date
        var site: String?
    }

    static let patchLogFile = "aihub/patch_log.json"

    /// Vom DeviceDataManager bei jedem Pump-Status aufgerufen (dort, wo
    /// pod-age.json geschrieben wird). Hängt NEUE Aktivierungen ans Log
    /// und erinnert per Notification an die Rotation. 60-s-Toleranz gegen
    /// Zeitstempel-Jitter (gleiche Vorsicht wie beim cgm-state-Dedup).
    static func registerPatchActivation(_ activatedAt: Date, storage: FileStorage) {
        storage.transaction { storage in
            var log = storage.retrieve(patchLogFile, as: [PatchEvent].self) ?? []
            if let last = log.last, abs(last.activatedAt.timeIntervalSince(activatedAt)) < 60 {
                return
            }
            let previousSite = log.last(where: { $0.site != nil })?.site
                .flatMap(Site.init(rawValue:))
            log.append(PatchEvent(activatedAt: activatedAt, site: nil))
            // Log begrenzen — für Laufzeit-Analysen reichen die letzten ~120
            // Wechsel (≈ ein Jahr bei 3-Tage-Patches) locker aus.
            if log.count > 120 {
                log.removeFirst(log.count - 120)
            }
            storage.save(log, as: patchLogFile)
            notifyRotation(previousSite: previousSite, log: log)
        }
    }

    /// Sensor-Setzstellen-Log: die Session-Starts selbst kommen aus
    /// cgm-state.json (GlucoseStorage), hier stehen nur die Zuordnungen.
    static let sensorLogFile = "aihub/sensor_site_log.json"

    private static func logFile(for kind: DeviceKind) -> String {
        kind == .patch ? patchLogFile : sensorLogFile
    }

    /// Stelle für den jüngsten (oder einen bestimmten) Wechsel eintragen.
    static func assignSite(_ site: Site, to activatedAt: Date, kind: DeviceKind) {
        let storage = BaseFileStorage()
        storage.transaction { storage in
            let file = logFile(for: kind)
            var log = storage.retrieve(file, as: [PatchEvent].self) ?? []
            guard let index = log.lastIndex(where: {
                abs($0.activatedAt.timeIntervalSince(activatedAt)) < 60
            }) else { return }
            log[index].site = site.rawValue
            storage.save(log, as: file)
        }
    }

    /// Gleicht das Sensor-Log mit den Session-Starts aus cgm-state.json ab:
    /// neue Starts werden (ohne Stelle) angehängt, Zuordnungen bleiben.
    private static func syncedSensorLog(starts: [Date], storage: FileStorage) -> [PatchEvent] {
        var result: [PatchEvent] = []
        storage.transaction { storage in
            var log = storage.retrieve(sensorLogFile, as: [PatchEvent].self) ?? []
            var changed = false
            for start in starts.suffix(120) {
                if !log.contains(where: { abs($0.activatedAt.timeIntervalSince(start)) < 60 }) {
                    log.append(PatchEvent(activatedAt: start, site: nil))
                    changed = true
                }
            }
            if changed {
                log.sort { $0.activatedAt < $1.activatedAt }
                if log.count > 120 {
                    log.removeFirst(log.count - 120)
                }
                storage.save(log, as: sensorLogFile)
            }
            result = log
        }
        return result
    }

    /// Am längsten pausierte der markierten Stellen (nie benutzte zuerst),
    /// die zuletzt genutzte IMMER ausgenommen. Erst ab zwei markierten
    /// Stellen sinnvoll — bei einer einzigen gibt es nichts zu rotieren
    /// (nil, die View zeigt dann einen Hinweis).
    static func suggestedSite(log: [PatchEvent], enabled: Set<Site>) -> Site? {
        guard enabled.count >= 2 else { return nil }
        var lastUse: [Site: Date] = [:]
        for event in log {
            if let site = event.site.flatMap(Site.init(rawValue:)) {
                lastUse[site] = event.activatedAt
            }
        }
        let lastUsed = log.last(where: { $0.site != nil })?.site.flatMap(Site.init(rawValue:))
        let candidates = enabled.filter { $0 != lastUsed }
        return candidates.min { a, b in
            let dateA = lastUse[a] ?? .distantPast
            let dateB = lastUse[b] ?? .distantPast
            if dateA != dateB { return dateA < dateB }
            return a.rawValue < b.rawValue // stabil bei Gleichstand
        }
    }

    /// Rotations-Erinnerung beim erkannten Patch-Wechsel — nur wenn der
    /// Nutzer die Rotation nutzt (Stellen markiert hat).
    private static func notifyRotation(previousSite: Site?, log: [PatchEvent]) {
        let enabled = enabledSites(for: .patch)
        guard !enabled.isEmpty else { return }
        let suggestion = suggestedSite(log: log, enabled: enabled)

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = hubT("dh.notif.title")
            content.body = hubT(
                "dh.notif.body",
                previousSite?.label ?? "—",
                suggestion?.label ?? "—"
            )
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "iAPS.aiHubPatchSite",
                content: content,
                trigger: nil // sofort
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    // MARK: - Analyse-Modelle

    struct CompressionEvent: Identifiable {
        let id = UUID()
        let date: Date
        let minMgdl: Int
        let dropMgdl: Int
        let recoveryMinutes: Int
    }

    struct NoiseByDay: Identifiable {
        let day: Int // Sensor-Laufzeit-Tag, 1-basiert
        let jumpsPerDay: Double
        var id: Int { day }
    }

    struct Result {
        let days: Int
        // Status
        let patchActivatedAt: Date?
        let sensorStartedAt: Date?
        // Rotation (getrennte Kreise für Patch und Sensor)
        let patchLog: [PatchEvent]
        let pendingChange: PatchEvent? // jüngster Patch-Wechsel ohne Stelle
        let lastSite: Site?
        let suggestion: Site?
        let sensorLog: [PatchEvent]
        let sensorPending: PatchEvent? // jüngster Sensor-Start ohne Stelle
        let sensorLastSite: Site?
        let sensorSuggestion: Site?
        // Kompression
        let nightHypoCount: Int
        let compressionEvents: [CompressionEvent]
        // Rauschen
        let jumpsPerDayOverall: Double
        let noiseByDay: [NoiseByDay]
        let noiseRisesLate: Bool
        let firstDayNoisy: Bool
        // Meta
        let facts: [String]
        let isMmol: Bool
        let readingCount: Int
    }

    // MARK: - Analyse (synchron, off-main aufrufen)

    static func analyze(days: Int) -> Result {
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)

        var readings: [(date: Date, glucose: Int)] = []
        var mealDates: [Date] = []

        context.performAndWait {
            let readingsReq = NSFetchRequest<Readings>(entityName: "Readings")
            readingsReq.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
            readingsReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            readings = ((try? context.fetch(readingsReq)) ?? [])
                .compactMap { row in row.date.map { ($0, Int(row.glucose)) } }

            let mealsReq = NSFetchRequest<Meals>(entityName: "Meals")
            mealsReq.sortDescriptors = [NSSortDescriptor(key: "actualDate", ascending: true)]
            mealDates = ((try? context.fetch(mealsReq)) ?? [])
                .compactMap { row in
                    guard let date = row.actualDate ?? row.createdAt, date >= cutoff,
                          ((row.value(forKey: "carbs") as? NSNumber)?.doubleValue ?? 0) > 0
                    else { return nil }
                    return date
                }
        }

        let storage = BaseFileStorage()
        let isMmol = (storage.retrieveRaw(OpenAPS.Settings.bgTargets) ?? "")
            .lowercased().contains("mmol")

        // Sensor-Historie: jeder Sensor-Start liegt als Treatment in
        // cgm-state.json (siehe GlucoseStorage) — rückwirkend verfügbar.
        let sensorStarts = (storage.retrieve(OpenAPS.Monitor.cgmState, as: [NigtscoutTreatment].self) ?? [])
            .compactMap(\.createdAt)
            .sorted()

        let log = storage.retrieve(patchLogFile, as: [PatchEvent].self) ?? []
        let lastSite = log.last(where: { $0.site != nil })?.site.flatMap(Site.init(rawValue:))
        let pending = log.last.flatMap { $0.site == nil ? $0 : nil }

        let sensorLog = syncedSensorLog(starts: sensorStarts, storage: storage)
        let sensorLastSite = sensorLog.last(where: { $0.site != nil })?.site
            .flatMap(Site.init(rawValue:))
        let sensorPending = sensorLog.last.flatMap { $0.site == nil ? $0 : nil }

        let compression = readings.count >= 100
            ? compressionEvents(readings: readings, mealDates: mealDates)
            : []
        let nightHypos = readings.count >= 100
            ? AIHubGlucoseStats.hypoEpisodes(in: readings)
            .filter { Calendar.current.component(.hour, from: $0.start) < 6 }.count
            : 0
        let noise = noiseAnalysis(readings: readings, sensorStarts: sensorStarts, days: days)

        return Result(
            days: days,
            patchActivatedAt: storage.retrieve(OpenAPS.Monitor.podAge, as: Date.self),
            sensorStartedAt: sensorStarts.last,
            patchLog: log,
            pendingChange: pending,
            lastSite: lastSite,
            suggestion: suggestedSite(log: log, enabled: enabledSites(for: .patch)),
            sensorLog: sensorLog,
            sensorPending: sensorPending,
            sensorLastSite: sensorLastSite,
            sensorSuggestion: suggestedSite(log: sensorLog, enabled: enabledSites(for: .sensor)),
            nightHypoCount: nightHypos,
            compressionEvents: compression,
            jumpsPerDayOverall: noise.overall,
            noiseByDay: noise.byDay,
            noiseRisesLate: noise.risesLate,
            firstDayNoisy: noise.firstDayNoisy,
            facts: buildFacts(
                days: days,
                compression: compression,
                nightHypos: nightHypos,
                noise: noise,
                log: log,
                sensorLog: sensorLog,
                sensorStarts: sensorStarts
            ),
            isMmol: isMmol,
            readingCount: readings.count
        )
    }

    // MARK: - Kompressions-Detektor

    /// Nächtlicher steiler Abfall mit schneller, (fast) vollständiger
    /// Erholung ohne Mahlzeit im Umfeld — typisches Aufliege-Artefakt:
    /// - Minimum < 75 mg/dl zwischen 22:00 und 07:00
    /// - Abfall ≥ 35 mg/dl vom Maximum der 30 min davor, binnen ≤ 25 min
    /// - binnen 45 min zurück auf (Vorwert − 15) oder höher
    /// - keine geloggte Mahlzeit ± 60 min
    private static func compressionEvents(
        readings: [(date: Date, glucose: Int)],
        mealDates: [Date]
    ) -> [CompressionEvent] {
        let calendar = Calendar.current
        var events: [CompressionEvent] = []
        var blockedUntil = Date.distantPast

        for (index, reading) in readings.enumerated() {
            guard reading.glucose < 75, reading.date > blockedUntil else { continue }
            let hour = calendar.component(.hour, from: reading.date)
            guard hour >= 22 || hour < 7 else { continue }

            // Lokales Minimum: nächster Wert nicht tiefer
            if index + 1 < readings.count, readings[index + 1].glucose < reading.glucose { continue }

            let before = readings[..<index]
                .suffix(while: { reading.date.timeIntervalSince($0.date) <= 30 * 60 })
            guard let peak = before.max(by: { $0.glucose < $1.glucose }) else { continue }
            let drop = peak.glucose - reading.glucose
            guard drop >= 35,
                  reading.date.timeIntervalSince(peak.date) <= 25 * 60 else { continue }

            let after = readings[(index + 1)...]
                .prefix(while: { $0.date.timeIntervalSince(reading.date) <= 45 * 60 })
            guard let recovery = after.first(where: { $0.glucose >= peak.glucose - 15 })
            else { continue }

            let mealNearby = mealDates.contains {
                abs($0.timeIntervalSince(reading.date)) <= 60 * 60
            }
            guard !mealNearby else { continue }

            events.append(CompressionEvent(
                date: reading.date,
                minMgdl: reading.glucose,
                dropMgdl: drop,
                recoveryMinutes: max(5, Int(recovery.date.timeIntervalSince(reading.date) / 60))
            ))
            blockedUntil = recovery.date.addingTimeInterval(30 * 60)
        }
        return events.reversed() // neueste zuerst
    }

    // MARK: - Rausch-Analyse

    private struct Noise {
        let overall: Double
        let byDay: [NoiseByDay]
        let risesLate: Bool
        let firstDayNoisy: Bool
    }

    /// Sprünge: |Δ| > 25 mg/dl zwischen aufeinanderfolgenden Werten mit
    /// ≤ 7 min Abstand. Gruppiert nach Sensor-Laufzeit-Tag (1-basiert).
    private static func noiseAnalysis(
        readings: [(date: Date, glucose: Int)],
        sensorStarts: [Date],
        days: Int
    ) -> Noise {
        guard readings.count >= 100 else {
            return Noise(overall: 0, byDay: [], risesLate: false, firstDayNoisy: false)
        }

        var jumpsByDay: [Int: Int] = [:]
        var readingsByDay: [Int: Int] = [:]
        var totalJumps = 0

        for index in 1 ..< readings.count {
            let current = readings[index]
            let previous = readings[index - 1]
            let gap = current.date.timeIntervalSince(previous.date)
            guard gap > 0, gap <= 7 * 60 else { continue }

            // Sensor-Laufzeit-Tag zum Zeitpunkt des Werts
            guard let start = sensorStarts.last(where: { $0 <= current.date }) else { continue }
            let day = Int(current.date.timeIntervalSince(start) / 86400) + 1
            guard day <= 20 else { continue } // Ausreißer/fehlende Starts kappen

            readingsByDay[day, default: 0] += 1
            if abs(current.glucose - previous.glucose) > 25 {
                jumpsByDay[day, default: 0] += 1
                totalJumps += 1
            }
        }

        // Sprünge pro Tag normalisiert (288 Werte = 1 Tag)
        let byDay = readingsByDay.keys.sorted().compactMap { day -> NoiseByDay? in
            guard let count = readingsByDay[day], count >= 144 else { return nil } // ≥ ½ Tag Daten
            let jumps = Double(jumpsByDay[day] ?? 0)
            return NoiseByDay(day: day, jumpsPerDay: jumps / Double(count) * 288)
        }

        let early = byDay.filter { $0.day >= 2 && $0.day <= 6 }.map(\.jumpsPerDay)
        let late = byDay.filter { $0.day >= 7 }.map(\.jumpsPerDay)
        let earlyMean = early.isEmpty ? 0 : early.reduce(0, +) / Double(early.count)
        let lateMean = late.isEmpty ? 0 : late.reduce(0, +) / Double(late.count)
        let firstDay = byDay.first(where: { $0.day == 1 })?.jumpsPerDay ?? 0

        return Noise(
            overall: Double(totalJumps) / Double(days),
            byDay: byDay,
            risesLate: !late.isEmpty && !early.isEmpty && lateMean > earlyMean * 1.8 && lateMean > 3,
            firstDayNoisy: earlyMean > 0 && firstDay > earlyMean * 1.8 && firstDay > 3
        )
    }

    // MARK: - KI-Fakten & Prompt

    private static func buildFacts(
        days: Int,
        compression: [CompressionEvent],
        nightHypos: Int,
        noise: Noise,
        log: [PatchEvent],
        sensorLog: [PatchEvent],
        sensorStarts: [Date]
    ) -> [String] {
        var facts: [String] = []
        facts.append(
            "Period: last \(days) days. Sensor sessions on record: \(sensorStarts.count). " +
                "Patch changes on record: \(log.count) (logging started when this module shipped)."
        )
        facts.append(String(
            format: "CGM noise: %.1f jumps/day overall (jump = >25 mg/dL between 5-min readings). " +
                "Noise rises late in sensor life: %@. First sensor day noisy: %@.",
            noise.overall,
            noise.risesLate ? "yes" : "no",
            noise.firstDayNoisy ? "yes" : "no"
        ))
        facts.append(
            "Nocturnal hypo episodes: \(nightHypos); of related patterns, \(compression.count) look like " +
                "compression artifacts (steep nocturnal drop >=35 mg/dL within 25 min, full recovery " +
                "within 45 min, no meal nearby)."
        )
        let patchCounts = Dictionary(grouping: log.compactMap(\.site), by: { $0 })
            .map { "\($0.key): \($0.value.count)" }
            .sorted()
        if !patchCounts.isEmpty {
            facts.append("Pump patch site usage: " + patchCounts.joined(separator: ", ") + ".")
        }
        let sensorCounts = Dictionary(grouping: sensorLog.compactMap(\.site), by: { $0 })
            .map { "\($0.key): \($0.value.count)" }
            .sorted()
        if !sensorCounts.isEmpty {
            facts.append("CGM sensor site usage: " + sensorCounts.joined(separator: ", ") + ".")
        }
        return facts
    }

    static func narrativePrompt(for result: Result) -> String {
        """
        You are the AI assistant inside iAPS (DIY closed-loop insulin app). A deterministic \
        analysis looked at CGM sensor noise, likely nocturnal compression artifacts and the \
        pump-patch site rotation of the last \(result.days) days. Write a short assessment in \
        \(AIHubL10n.aiAnswerLanguageName).

        Rules:
        - 2 to 4 bullet points starting with "•", each 1–2 sentences, most important first.
        - Compression lows are ARTIFACTS (sensor pressed while sleeping), not real hypos — if \
        present, explain that briefly and suggest checking sensor placement/sleeping position.
        - If noise rises late in sensor life or the first day is noisy, say what that means \
        practically (trust trends less, calibrate expectations).
        - Encourage site rotation if the usage list is lopsided.
        - No dosing advice. No greeting, no closing line.
        - Glucose values in the data are mg/dL; present them in \(result
            .isMmol ? "mmol/L (divide by 18, one decimal)" : "mg/dL").

        === DATA ===
        \(result.facts.joined(separator: "\n"))
        """
    }

    // MARK: - Narrative-Cache (pro Tag und Periode)

    private static func cacheKey(days: Int) -> String { "iAPS.aiHubDeviceText.\(days)" }
    private static func cacheDateKey(days: Int) -> String { "iAPS.aiHubDeviceDate.\(days)" }

    static func cachedNarrative(days: Int) -> String? {
        guard let date = UserDefaults.standard.object(forKey: cacheDateKey(days: days)) as? Date,
              Calendar.current.isDateInToday(date)
        else { return nil }
        return UserDefaults.standard.string(forKey: cacheKey(days: days))
    }

    static func storeNarrative(_ text: String, days: Int) {
        UserDefaults.standard.set(text, forKey: cacheKey(days: days))
        UserDefaults.standard.set(Date(), forKey: cacheDateKey(days: days))
    }
}

private extension ArraySlice {
    /// Wie `suffix(while:)` — nimmt Elemente vom Ende, solange das Prädikat
    /// erfüllt ist (Swift bietet nur `prefix(while:)`).
    func suffix(while predicate: (Element) -> Bool) -> [Element] {
        var result: [Element] = []
        for element in reversed() {
            guard predicate(element) else { break }
            result.append(element)
        }
        return result.reversed()
    }
}
