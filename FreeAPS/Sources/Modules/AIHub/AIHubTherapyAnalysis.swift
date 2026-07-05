import CoreData
import Foundation

/// Deterministische Therapie-Analyse für den AI Hub („Therapy Insights").
///
/// Bewusst OHNE LLM: Score und Vorschläge (Basal, ISF, CR) werden lokal aus
/// Readings, Reasons, Meals und dem aktiven Profil gerechnet — kostenlos,
/// offline, reproduzierbar. Kernregel aus der wöchentlichen Analyse
/// übernommen: Hypos ohne aktives Bolus-Insulin (IOB < 1) und ohne COB sind
/// basal-getrieben → Basal senken, nicht SMB/ISF anfassen. ISF wird nur aus
/// carb-freien Korrektur-Episoden bewertet, CR nur aus geloggten Mahlzeiten
/// (≥ 20 g — kleinere Mengen loggt der Nutzer erfahrungsgemäß nicht
/// zuverlässig; mit `aiHubCarbsComplete` ≥ 10 g, weil dann auch kleine
/// Mahlzeiten verlässlich erfasst sind. Das Flag gibt ISF/CR-Vorschlägen
/// außerdem einen Konfidenz-Bonus: „carb-frei" und „isolierte Mahlzeit"
/// sind dann Fakten statt Vermutungen).
enum AIHubTherapyAnalysis {
    // MARK: - Modelle

    struct Stats {
        let readingCount: Int
        let days: Int
        let meanMgdl: Double
        let tir: Double // Anteil 70–180, 0–1
        let below: Double // Anteil < 70
        let above: Double // Anteil > 180
        let cv: Double // Variationskoeffizient, 0–1

        var gmi: Double { 3.31 + 0.02392 * meanMgdl }
    }

    /// Ein Loop-Zyklus aus der Reasons-Entity. `glucose` und `isf` sind in
    /// denselben (Nutzer-)Einheiten gespeichert — in (dBG/dt)/ISF kürzen sie
    /// sich weg, das Ergebnis ist einheitenunabhängig U/h.
    struct Cycle {
        let date: Date
        let iob: Double
        let cob: Double
        let glucose: Double
        let rate: Double
        let isf: Double
        let smb: Double
    }

    struct Suggestion: Identifiable {
        enum Kind {
            case basalIncrease
            case basalDecrease
            case isfRaise // ISF-Zahl anheben = schwächere Korrekturen
            case isfLower // ISF-Zahl senken = stärkere Korrekturen
            case crRaise // mehr g/U = weniger Mahlzeiten-Insulin
            case crLower // weniger g/U = mehr Mahlzeiten-Insulin
        }

        /// Maschinenlesbare Form des Vorschlags für die direkte Übernahme
        /// ins aktive Profil (AIHubTherapyApply). Werte in Profil-Einheiten,
        /// identisch gerundet zu den angezeigten Texten.
        enum ApplyPayload {
            /// Basal-Block [startMinute, endMinute) mit Faktor skalieren.
            case basal(startMinute: Int, endMinute: Int, factor: Double)
            /// ISF des Slots mit diesem Offset auf den Wert setzen.
            case isf(slotStartMinute: Int, proposed: Double)
            /// CR des Slots mit diesem Offset auf den Wert setzen.
            case cr(slotStartMinute: Int, proposed: Double)
        }

        let id = UUID()
        let kind: Kind
        /// "HH:mm – HH:mm" des Profil-Slots/Blocks; nil = ganztägig.
        let timeText: String?
        let currentText: String
        let proposedText: String
        let confidence: Int // 0–100
        let rationale: String
        let apply: ApplyPayload
    }

    struct Result {
        let stats: Stats?
        let suggestions: [Suggestion]
        let isMmol: Bool
        /// Vorschläge, die wegen einer kürzlichen Übernahme (Cooldown)
        /// zurückgehalten wurden — die View zeigt dann einen Hinweis.
        let suppressedCount: Int
    }

    // MARK: - Score

    /// 0–100: 50 Punkte TIR (80 % = voll), 25 Punkte Hypo-Vermeidung
    /// (≥ 5 % unter 70 = null), 25 Punkte Stabilität (CV ≤ 30 % = voll,
    /// ≥ 50 % = null).
    static func score(for stats: Stats) -> (value: Int, label: String) {
        let tirFactor = min(stats.tir / 0.80, 1.0)
        let lowFactor = max(0.0, 1.0 - stats.below / 0.05)
        let cvFactor = max(0.0, 1.0 - max(0.0, stats.cv - 0.30) / 0.20)
        let value = Int((50 * tirFactor + 25 * lowFactor + 25 * cvFactor).rounded())
        let label: String
        switch value {
        case 90...: label = hubT("ti.score.excellent")
        case 75...: label = hubT("ti.score.good")
        case 60...: label = hubT("ti.score.solid")
        default: label = hubT("ti.score.needswork")
        }
        return (value, label)
    }

    // MARK: - Analyse

    /// Synchron — Caller dispatcht off-main.
    static func analyze(days: Int) -> Result {
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let calendar = Calendar.current

        var readings: [(date: Date, glucose: Int)] = []
        var reasons: [Cycle] = []
        var meals: [(date: Date, carbs: Double)] = []

        context.performAndWait {
            let readingsReq = NSFetchRequest<Readings>(entityName: "Readings")
            readingsReq.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
            readingsReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            readings = ((try? context.fetch(readingsReq)) ?? [])
                .compactMap { row in row.date.map { ($0, Int(row.glucose)) } }

            let reasonsReq = NSFetchRequest<Reasons>(entityName: "Reasons")
            reasonsReq.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
            reasonsReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            reasons = ((try? context.fetch(reasonsReq)) ?? [])
                .compactMap { row in
                    row.date.map {
                        Cycle(
                            date: $0,
                            iob: row.iob?.doubleValue ?? 0,
                            cob: row.cob?.doubleValue ?? 0,
                            glucose: row.glucose?.doubleValue ?? 0,
                            rate: row.rate?.doubleValue ?? 0,
                            isf: row.isf?.doubleValue ?? 0,
                            smb: row.smb?.doubleValue ?? 0
                        )
                    }
                }

            // Meals: `date` ist beim Speichern nicht gesetzt — `actualDate`
            // ist das zuverlässige Datum. Core Data enthält nur echte
            // Einträge, keine FPU-Äquivalente.
            let mealsReq = NSFetchRequest<Meals>(entityName: "Meals")
            mealsReq.sortDescriptors = [NSSortDescriptor(key: "actualDate", ascending: true)]
            meals = ((try? context.fetch(mealsReq)) ?? [])
                .compactMap { row -> (Date, Double)? in
                    guard let date = row.actualDate ?? row.createdAt, date >= cutoff else { return nil }
                    let carbs = (row.value(forKey: "carbs") as? NSNumber)?.doubleValue ?? 0
                    return carbs > 0 ? (date, carbs) : nil
                }
                .sorted { $0.0 < $1.0 }
        }

        let isMmol = (BaseFileStorage().retrieveRaw(OpenAPS.Settings.bgTargets) ?? "")
            .lowercased().contains("mmol")

        guard readings.count >= 50 else {
            return Result(stats: nil, suggestions: [], isMmol: isMmol, suppressedCount: 0)
        }

        // Gesamt-Statistik
        let values = readings.map { Double($0.glucose) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let sd = variance.squareRoot()
        let stats = Stats(
            readingCount: readings.count,
            days: days,
            meanMgdl: mean,
            tir: Double(readings.filter { $0.glucose >= 70 && $0.glucose <= 180 }.count) / Double(readings.count),
            below: Double(readings.filter { $0.glucose < 70 }.count) / Double(readings.count),
            above: Double(readings.filter { $0.glucose > 180 }.count) / Double(readings.count),
            cv: mean > 0 ? sd / mean : 0
        )

        let basal = basalSuggestions(
            cycles: reasons,
            meals: meals,
            calendar: calendar
        )
        var isf = isfSuggestions(
            readings: readings,
            reasons: reasons,
            meals: meals,
            calendar: calendar,
            isMmol: isMmol
        )
        // Overshoot-Detektor nur für Slots, zu denen die klassische
        // Korrektur-Analyse nichts sagt — sie hat die stärkere Evidenz.
        let classicSlots = Set(isf.compactMap { suggestion -> Int? in
            if case let .isf(slotStartMinute, _) = suggestion.apply { return slotStartMinute }
            return nil
        })
        isf += mealOvershootSuggestions(
            cycles: reasons,
            meals: meals,
            calendar: calendar,
            excludedSlots: classicSlots
        )
        let cr = crSuggestions(
            readings: readings,
            meals: meals,
            calendar: calendar,
            isMmol: isMmol
        )

        // Cooldown: Slots, die in den letzten Tagen per Übernahme geändert
        // wurden, nicht erneut vorschlagen — die Analyse rechnet sonst auf
        // Daten der ALTEN Einstellung und würde dieselbe Änderung gleich
        // nochmal stapeln.
        var suppressed = 0
        let available = (basal + isf + cr).filter { suggestion in
            let coolingDown: Bool
            switch suggestion.apply {
            case let .basal(startMinute, _, _):
                coolingDown = AIHubTherapyApply.isCoolingDown(target: .basal, slot: startMinute)
            case let .isf(slotStartMinute, _):
                coolingDown = AIHubTherapyApply.isCoolingDown(target: .isf, slot: slotStartMinute)
            case let .cr(slotStartMinute, _):
                coolingDown = AIHubTherapyApply.isCoolingDown(target: .cr, slot: slotStartMinute)
            }
            if coolingDown { suppressed += 1 }
            return !coolingDown
        }

        let combined = available.sorted { $0.confidence > $1.confidence }
        return Result(
            stats: stats,
            suggestions: Array(combined.prefix(4)),
            isMmol: isMmol,
            suppressedCount: suppressed
        )
    }

    // MARK: - Basal-Engine (Clean-Drift)

    // Misst den Basal-BEDARF direkt statt auf Outcomes (Hypos, erhöhte
    // Mittelwerte) zu reagieren: über "saubere" Zell-Paare (kein wirkendes
    // Carb, IOB niedrig, kein kürzlicher SMB) gilt
    //
    //     required = laufende Rate + (dBG/dt) / ISF   [U/h]
    //
    // = die Rate, die BG flach hielte. Median pro Profil-Segment, Confidence
    // aus dem Standardfehler des Medians, Shrinkage Richtung Ist-Profil und
    // harte Schritt-Caps. Methodik am 90d-Export gegen die Python-Referenz
    // (fullday_basal.py) validiert. Bewusst KEINE "Block-Mittelwert hoch →
    // Basal hoch"-Regel: bei unvollständigem Carb-Logging deutet die
    // ungetrackte Mahlzeiten als Basalmangel (klassischer AutoTune-Bias).
    private static let cleanIOBMax = 0.30 // U — Paar nur sauber, wenn IOB beider Zellen darunter
    private static let cleanNoSMBMinutes = 90.0 // min ohne SMB ≥ significantSMB (Rest-Wirkung!)
    private static let significantSMB = 0.10 // U
    private static let carbWindowMinutes = 120.0 // min Absorptionsfenster nach Carb-Onset
    private static let riseOnsetMgdl = 25.0 // BG-Anstieg in ≤ 20 min → ungetrackte Mahlzeit
    private static let minCleanPairs = 40 // Small-n-Schutz pro Segment
    private static let seTight = 0.03 // U/h — SE darunter: volle Confidence
    private static let seLoose = 0.12 // U/h — SE darüber: Confidence 0
    private static let minConfToMove = 0.30
    private static let maxAbsStep = 0.10 // U/h pro Anwendung
    private static let maxRelStep = 0.20 // 20 % pro Anwendung
    private static let minDeltaApply = 0.05 // U/h — kleinere Änderungen nicht vorschlagen

    private static func basalSuggestions(
        cycles: [Cycle],
        meals: [(date: Date, carbs: Double)],
        calendar: Calendar
    ) -> [Suggestion] {
        guard let schedule = basalSchedule(), !schedule.isEmpty, cycles.count > 100 else { return [] }

        // mmol-Erkennung nur für den Rise-Schwellwert (required selbst ist
        // einheitenunabhängig, weil glucose und isf dieselben Einheiten haben).
        let glucoseValues = cycles.map(\.glucose).filter { $0 > 0 }.sorted()
        let isMmolData = !glucoseValues.isEmpty && glucoseValues[glucoseValues.count / 2] < 30
        let riseDelta = isMmolData ? riseOnsetMgdl / 18.0 : riseOnsetMgdl

        // Carb-Onsets: geloggte Mahlzeiten + Rapid-Rise-Proxy für ungetrackte.
        var onsets: [Date] = meals.map(\.date)
        var i = 0
        while i < cycles.count {
            let base = cycles[i]
            guard base.glucose > 0 else { i += 1
                continue }
            var found = false
            var j = i + 1
            while j < cycles.count,
                  cycles[j].date.timeIntervalSince(base.date) <= 20 * 60
            {
                if cycles[j].glucose > 0, cycles[j].glucose - base.glucose >= riseDelta {
                    onsets.append(base.date)
                    found = true
                    break
                }
                j += 1
            }
            // Nach einem Onset 30 min weiterspringen, sonst Onset-Ketten
            i = found ? lowerBound(cycles.map(\.date), base.date.addingTimeInterval(30 * 60)) : i + 1
        }
        onsets.sort()

        func isCarbActive(_ date: Date) -> Bool {
            containsDate(onsets, after: date.addingTimeInterval(-carbWindowMinutes * 60), until: date)
        }

        // Minuten seit letztem signifikanten SMB
        var minutesSinceSMB = [Double](repeating: .infinity, count: cycles.count)
        var lastSMB: Date?
        for (index, cycle) in cycles.enumerated() {
            if cycle.smb >= significantSMB { lastSMB = cycle.date }
            if let lastSMB = lastSMB {
                minutesSinceSMB[index] = cycle.date.timeIntervalSince(lastSMB) / 60
            }
        }

        // Saubere Zell-Paare → required_rate, dem Profil-Segment zugeordnet
        let startMinutes = schedule.map(\.startMinute)
        var requiredBySegment: [[Double]] = Array(repeating: [], count: schedule.count)
        var daysBySegment: [Set<Date>] = Array(repeating: [], count: schedule.count)

        for index in 0 ..< max(cycles.count - 1, 0) {
            let a = cycles[index]
            let b = cycles[index + 1]
            let dtMin = b.date.timeIntervalSince(a.date) / 60
            guard dtMin >= 3, dtMin <= 8 else { continue }
            guard a.glucose > 0, b.glucose > 0, a.isf > 0 else { continue }
            guard a.iob <= cleanIOBMax, b.iob <= cleanIOBMax else { continue }
            guard minutesSinceSMB[index] >= cleanNoSMBMinutes else { continue }
            guard !isCarbActive(a.date), !isCarbActive(b.date) else { continue }

            let bgRatePerHour = (b.glucose - a.glucose) / dtMin * 60
            let required = a.rate + bgRatePerHour / a.isf
            let segment = slotIndex(forMinute: minuteOfDay(a.date, calendar), in: startMinutes)
            requiredBySegment[segment].append(required)
            daysBySegment[segment].insert(calendar.startOfDay(for: a.date))
        }

        var suggestions: [Suggestion] = []
        for (segment, entry) in schedule.enumerated() {
            let currentRate = entry.rate
            // Faktor-Apply kann eine 0-Rate nicht anheben — Segment auslassen
            guard currentRate > 0 else { continue }
            let required = requiredBySegment[segment].sorted()
            let n = required.count
            guard n >= minCleanPairs else { continue }

            let median = required[n / 2]
            let iqr = required[n * 3 / 4] - required[n / 4]
            let se = (iqr / 1.349) / Double(n).squareRoot()
            let confidence = min(1, max(0, 1 - (se - seTight) / (seLoose - seTight)))
            guard confidence >= minConfToMove else { continue }

            // Shrinkage Richtung Ist-Profil + Schritt-Cap + Mindest-Schritt
            let shrunk = currentRate + confidence * (median - currentRate)
            let maxStep = max(maxAbsStep, maxRelStep * currentRate)
            let applied = currentRate + min(maxStep, max(-maxStep, shrunk - currentRate))
            let proposed = roundedRate(applied)
            guard abs(proposed - currentRate) >= minDeltaApply else { continue }

            let segmentEnd = segment + 1 < schedule.count ? schedule[segment + 1].startMinute : 24 * 60
            let key = proposed < currentRate ? "ti.rationale.drift.decrease" : "ti.rationale.drift.increase"
            suggestions.append(Suggestion(
                kind: proposed < currentRate ? .basalDecrease : .basalIncrease,
                timeText: timeRange(entry.startMinute, segmentEnd),
                currentText: String(format: "%.2f U/h", currentRate),
                proposedText: String(format: "%.2f U/h", proposed),
                confidence: Int((confidence * 100).rounded()),
                rationale: hubT(
                    key,
                    n,
                    daysBySegment[segment].count,
                    String(format: "%.2f", median),
                    String(format: "%.2f", currentRate)
                ),
                apply: .basal(
                    startMinute: entry.startMinute,
                    endMinute: segmentEnd,
                    factor: proposed / currentRate
                )
            ))
        }

        return Array(suggestions.sorted { $0.confidence > $1.confidence }.prefix(3))
    }

    // MARK: - ISF-Engine

    /// Korrektur-Episoden: Loop-Zyklus mit IOB ≥ 1, COB = 0 und BG ≥ 160,
    /// die folgenden 3 h frei von COB und geloggten Carbs. Bewertet wird der
    /// tatsächliche Abfall gegen die Profil-Erwartung (IOB × ISF) sowie
    /// Hypos im 4-h-Fenster.
    private static func isfSuggestions(
        readings: [(date: Date, glucose: Int)],
        reasons: [Cycle],
        meals: [(date: Date, carbs: Double)],
        calendar: Calendar,
        isMmol _: Bool
    ) -> [Suggestion] {
        guard let profile = isfProfile(), !profile.entries.isEmpty else { return [] }

        let readingDates = readings.map(\.date)
        let cobDates = reasons.filter { $0.cob > 0 }.map(\.date)
        let mealDates = meals.map(\.date)

        // (Slot-Index, Hypo im Fenster, Korrektur deutlich zu schwach, End-BG)
        var episodes: [(slot: Int, isHypo: Bool, isWeak: Bool, endBG: Double)] = []
        var blockedUntil = Date.distantPast

        for reason in reasons {
            guard reason.date > blockedUntil, reason.iob >= 1.0, reason.cob <= 0 else { continue }
            guard let startBG = nearestGlucose(to: reason.date, tolerance: 10 * 60, readings, readingDates),
                  startBG >= 160 else { continue }
            let windowEnd = reason.date.addingTimeInterval(3 * 3600)

            // Kontamination: COB oder geloggte Carbs rund ums Fenster → Episode verwerfen
            guard !containsDate(cobDates, after: reason.date, until: windowEnd),
                  !containsDate(mealDates, after: reason.date.addingTimeInterval(-3600), until: windowEnd)
            else { blockedUntil = windowEnd
                continue }

            guard let endBG = nearestGlucose(to: windowEnd, tolerance: 20 * 60, readings, readingDates)
            else { blockedUntil = windowEnd
                continue }

            let minBG = minGlucose(
                from: reason.date,
                to: reason.date.addingTimeInterval(4 * 3600),
                readings,
                readingDates
            ) ?? endBG
            let slot = slotIndex(forMinute: minuteOfDay(reason.date, calendar), in: profile.entries.map(\.startMinute))
            let expectedDrop = reason.iob * profile.entries[slot].mgdlPerU
            episodes.append((
                slot: slot,
                isHypo: minBG < 70,
                isWeak: (startBG - endBG) < 0.5 * expectedDrop && endBG > 160,
                endBG: endBG
            ))
            blockedUntil = windowEnd
        }

        // Vollständiges Logging macht den Carb-frei-Filter zum Faktum
        // statt zur Vermutung → Vorschläge dürfen höher gewichtet werden.
        let carbBonus = UserDefaults.standard.aiHubCarbsComplete ? 10 : 0

        var suggestions: [Suggestion] = []
        for (index, entry) in profile.entries.enumerated() {
            let slotEpisodes = episodes.filter { $0.slot == index }
            guard slotEpisodes.count >= 4 else { continue }
            let hypoCount = slotEpisodes.filter(\.isHypo).count
            let weakCount = slotEpisodes.filter(\.isWeak).count
            let timeText = slotTimeText(profile.entries.map(\.startMinute), index)

            if hypoCount >= 2, hypoCount * 2 >= slotEpisodes.count {
                // Korrekturen enden zu oft im Unterzucker → ISF-Zahl anheben
                let proposed = roundedISF(entry.display * 1.10, isMmol: profile.isMmol)
                guard proposed > entry.display else { continue }
                suggestions.append(Suggestion(
                    kind: .isfRaise,
                    timeText: timeText,
                    currentText: formatISF(entry.display, isMmol: profile.isMmol),
                    proposedText: formatISF(proposed, isMmol: profile.isMmol),
                    confidence: min(90, 45 + hypoCount * 15 + carbBonus),
                    rationale: hubT("ti.rationale.isf.raise", hypoCount, slotEpisodes.count),
                    apply: .isf(slotStartMinute: entry.startMinute, proposed: proposed)
                ))
            } else if hypoCount == 0, weakCount * 5 >= slotEpisodes.count * 3 {
                // Korrekturen bringen konsistent weniger als die Hälfte der
                // erwarteten Senkung → ISF-Zahl senken
                let proposed = roundedISF(entry.display * 0.90, isMmol: profile.isMmol)
                guard proposed < entry.display else { continue }
                let weakMeanEnd = slotEpisodes.filter(\.isWeak).map(\.endBG).reduce(0, +) / Double(weakCount)
                suggestions.append(Suggestion(
                    kind: .isfLower,
                    timeText: timeText,
                    currentText: formatISF(entry.display, isMmol: profile.isMmol),
                    proposedText: formatISF(proposed, isMmol: profile.isMmol),
                    confidence: min(90, Int(Double(weakCount) / Double(slotEpisodes.count) * 90) + carbBonus),
                    rationale: hubT(
                        "ti.rationale.isf.lower",
                        weakCount,
                        slotEpisodes.count,
                        formatGlucose(weakMeanEnd, isMmol: profile.isMmol)
                    ),
                    apply: .isf(slotStartMinute: entry.startMinute, proposed: proposed)
                ))
            }
        }
        return suggestions
    }

    // MARK: - Mahlzeiten-Überschuss (SMB-Overshoot)

    // Ergänzt die klassische Korrektur-Analyse für Auto-ISF-Nutzer mit
    // unangekündigten Mahlzeiten: Dort gibt es kaum isolierte Korrektur-Boli
    // (Rettungs-Kohlenhydrate kontaminieren die Fenster zusätzlich), und die
    // typische Hypo entsteht NACH abgeklungenem IOB als Tail des SMB-Stacks,
    // der auf den Mahlzeiten-Anstieg geantwortet hat. Detektor:
    // Anstiegs-Onset → SMB-Summe im 2-h-Fenster → Hypo < 70 innerhalb
    // 0:45–5:00 h danach = Überschuss-Ereignis. Häufung in einem ISF-Slot →
    // ISF dort anheben (sanftere SMB-Antwort).
    private static let overshootMinSMBSum = 1.0 // U im 2-h-Fenster nach Onset
    private static let overshootMinEvents = 4 // pro ISF-Slot
    private static let overshootHypoStart = 45.0 * 60 // s nach Onset
    private static let overshootHypoEnd = 5.0 * 3600 // s nach Onset

    private static func mealOvershootSuggestions(
        cycles: [Cycle],
        meals: [(date: Date, carbs: Double)],
        calendar: Calendar,
        excludedSlots: Set<Int>
    ) -> [Suggestion] {
        guard let profile = isfProfile(), !profile.entries.isEmpty, cycles.count > 100 else { return [] }

        let glucoseValues = cycles.map(\.glucose).filter { $0 > 0 }.sorted()
        let isMmolData = !glucoseValues.isEmpty && glucoseValues[glucoseValues.count / 2] < 30
        let riseDelta = isMmolData ? riseOnsetMgdl / 18.0 : riseOnsetMgdl
        let hypoLimit = isMmolData ? 70.0 / 18.0 : 70.0

        // Onsets: geloggte Mahlzeiten + Rapid-Rise-Proxy, ≥ 2 h auseinander
        var onsets: [Date] = meals.map(\.date)
        var index = 0
        while index < cycles.count {
            let base = cycles[index]
            guard base.glucose > 0 else { index += 1
                continue }
            var found = false
            var j = index + 1
            while j < cycles.count, cycles[j].date.timeIntervalSince(base.date) <= 20 * 60 {
                if cycles[j].glucose > 0, cycles[j].glucose - base.glucose >= riseDelta {
                    onsets.append(base.date)
                    found = true
                    break
                }
                j += 1
            }
            index = found
                ? lowerBound(cycles.map(\.date), base.date.addingTimeInterval(2 * 3600))
                : index + 1
        }
        onsets.sort()
        var deduped: [Date] = []
        for onset in onsets where onset.timeIntervalSince(deduped.last ?? .distantPast) >= 2 * 3600 {
            deduped.append(onset)
        }

        // Qualifizierte Onsets: SMB-Summe ≥ Schwelle im 2-h-Fenster
        var qualified: [Date] = []
        for onset in deduped {
            var smbSum = 0.0
            for cycle in cycles {
                let dt = cycle.date.timeIntervalSince(onset)
                if dt < 0 { continue }
                if dt > 2 * 3600 { break }
                smbSum += cycle.smb
            }
            if smbSum >= overshootMinSMBSum { qualified.append(onset) }
        }

        // Hypo-EPISODEN (Beginn eines <70-Laufs), jede genau EINEM Onset
        // zugeordnet (dem letzten im Attributionsfenster) — die 5-h-Fenster
        // aufeinanderfolgender Mahlzeiten überlappen sonst und ein Hypo
        // würde mehrere Events als Overshoot markieren.
        var hypoStarts: [Date] = []
        var inHypo = false
        for cycle in cycles where cycle.glucose > 0 {
            if cycle.glucose < hypoLimit {
                if !inHypo { hypoStarts.append(cycle.date) }
                inHypo = true
            } else {
                inHypo = false
            }
        }
        var overshootOnsets = Set<Date>()
        for hypo in hypoStarts {
            let candidate = qualified.last(where: {
                let dt = hypo.timeIntervalSince($0)
                return dt >= overshootHypoStart && dt <= overshootHypoEnd
            })
            if let candidate = candidate { overshootOnsets.insert(candidate) }
        }

        var eventsBySlot: [Int: (total: Int, hypo: Int)] = [:]
        let slotStarts = profile.entries.map(\.startMinute)
        for onset in qualified {
            let slot = slotIndex(forMinute: minuteOfDay(onset, calendar), in: slotStarts)
            var entry = eventsBySlot[slot] ?? (0, 0)
            entry.total += 1
            if overshootOnsets.contains(onset) { entry.hypo += 1 }
            eventsBySlot[slot] = entry
        }

        var suggestions: [Suggestion] = []
        for (slot, counts) in eventsBySlot {
            guard !excludedSlots.contains(profile.entries[slot].startMinute) else { continue }
            // ≥ 1/3 der Antworten endet im Hypo (und mindestens 3): bei
            // Hypo-Häufung ist die 50 %-Schwelle der Korrektur-Analyse zu
            // träge — Richards 14d-Daten: 44 % Overshoot-Quote ganztags.
            guard counts.total >= overshootMinEvents,
                  counts.hypo * 3 >= counts.total, counts.hypo >= 3 else { continue }
            let entry = profile.entries[slot]
            let proposed = roundedISF(entry.display * 1.10, isMmol: profile.isMmol)
            guard proposed > entry.display else { continue }
            suggestions.append(Suggestion(
                kind: .isfRaise,
                timeText: slotTimeText(slotStarts, slot),
                currentText: formatISF(entry.display, isMmol: profile.isMmol),
                proposedText: formatISF(proposed, isMmol: profile.isMmol),
                confidence: min(85, 40 + counts.hypo * 12),
                rationale: hubT("ti.rationale.isf.overshoot", counts.total, counts.hypo),
                apply: .isf(slotStartMinute: entry.startMinute, proposed: proposed)
            ))
        }
        return suggestions
    }

    // MARK: - CR-Engine

    /// Mahlzeiten-Episoden: geloggte Mahlzeiten ≥ 20 g bzw. ≥ 10 g bei
    /// vollständigem Logging (Einträge < 90 min Abstand zusammengefasst).
    /// Isolation bewusst LOCKER (2 h davor frei, 2,5 h danach frei): Wer
    /// regelmäßig alle 2–3 h isst, hat praktisch nie 4 h Abstand — die alte
    /// 4-h-Isolation ließ dann fast keine Episoden übrig (14d-Daten: 6 von
    /// 68 Mahlzeiten). Bewertet wird der BG bei +2,5 h (Peak-Rückgang statt
    /// voller Absorption) gegen den Vor-Mahlzeiten-Wert sowie Hypos bis
    /// +3,5 h. Die Zu-hoch-Schwelle ist entsprechend konservativer, weil
    /// eine gut dosierte Mahlzeit bei +2,5 h legitim noch erhöht sein kann.
    private static func crSuggestions(
        readings: [(date: Date, glucose: Int)],
        meals: [(date: Date, carbs: Double)],
        calendar: Calendar,
        isMmol: Bool
    ) -> [Suggestion] {
        guard let profile = crProfile(), !profile.isEmpty else { return [] }

        let readingDates = readings.map(\.date)

        // Einträge < 90 min Abstand zu einer Mahlzeit zusammenfassen
        var merged: [(date: Date, carbs: Double)] = []
        for meal in meals {
            if let last = merged.last, meal.date.timeIntervalSince(last.date) < 90 * 60 {
                merged[merged.count - 1].carbs += meal.carbs
            } else {
                merged.append(meal)
            }
        }

        // Bei vollständigem Logging sind auch kleine Mahlzeiten verlässlich
        // erfasst und die Fenster-Isolation ist ein Faktum → niedrigere
        // Schwelle, Konfidenz-Bonus.
        let carbsComplete = UserDefaults.standard.aiHubCarbsComplete
        let minMealCarbs: Double = carbsComplete ? 10 : 20
        let carbBonus = carbsComplete ? 10 : 0

        // (Slot-Index, Hypo bis +5 h, deutlich erhöht bei +4 h, Anstieg)
        var episodes: [(slot: Int, isHypo: Bool, isHigh: Bool, rise: Double)] = []

        for (index, meal) in merged.enumerated() where meal.carbs >= minMealCarbs {
            // Vor-BG braucht 2 h Ruhe davor; Auswertung braucht 2,5 h ohne
            // Folge-Mahlzeit. Mehr Isolation ist bei häufigem Essen unerfüllbar.
            if index > 0, meal.date.timeIntervalSince(merged[index - 1].date) < 2 * 3600 { continue }
            if index + 1 < merged.count, merged[index + 1].date.timeIntervalSince(meal.date) < 2.5 * 3600 { continue }

            guard let preBG = nearestGlucose(to: meal.date, tolerance: 30 * 60, readings, readingDates),
                  let endBG = nearestGlucose(
                      to: meal.date.addingTimeInterval(2.5 * 3600),
                      tolerance: 30 * 60,
                      readings,
                      readingDates
                  )
            else { continue }
            let minBG = minGlucose(
                from: meal.date,
                to: meal.date.addingTimeInterval(3.5 * 3600),
                readings,
                readingDates
            ) ?? endBG
            let slot = slotIndex(forMinute: minuteOfDay(meal.date, calendar), in: profile.map(\.startMinute))
            episodes.append((
                slot: slot,
                isHypo: minBG < 70,
                isHigh: endBG - preBG > 60 && endBG > 180,
                rise: endBG - preBG
            ))
        }

        var suggestions: [Suggestion] = []
        for (index, entry) in profile.enumerated() {
            let slotEpisodes = episodes.filter { $0.slot == index }
            guard slotEpisodes.count >= 4 else { continue }
            let hypoCount = slotEpisodes.filter(\.isHypo).count
            let highCount = slotEpisodes.filter(\.isHigh).count
            let timeText = slotTimeText(profile.map(\.startMinute), index)

            if hypoCount >= 2, hypoCount * 2 >= slotEpisodes.count {
                // Nach Mahlzeiten zu oft Unterzucker → mehr Gramm pro Einheit
                let proposed = roundedCR(entry.ratio * 1.10)
                guard proposed > entry.ratio else { continue }
                suggestions.append(Suggestion(
                    kind: .crRaise,
                    timeText: timeText,
                    currentText: formatCR(entry.ratio),
                    proposedText: formatCR(proposed),
                    confidence: min(90, 45 + hypoCount * 15 + carbBonus),
                    rationale: hubT("ti.rationale.cr.raise", hypoCount, slotEpisodes.count),
                    apply: .cr(slotStartMinute: entry.startMinute, proposed: proposed)
                ))
            } else if hypoCount == 0, highCount * 5 >= slotEpisodes.count * 3 {
                // Mahlzeiten enden konsistent deutlich über dem Ausgangswert
                // → weniger Gramm pro Einheit
                let proposed = roundedCR(entry.ratio * 0.90)
                guard proposed < entry.ratio else { continue }
                let highMeanRise = slotEpisodes.filter(\.isHigh).map(\.rise).reduce(0, +) / Double(highCount)
                suggestions.append(Suggestion(
                    kind: .crLower,
                    timeText: timeText,
                    currentText: formatCR(entry.ratio),
                    proposedText: formatCR(proposed),
                    confidence: min(90, Int(Double(highCount) / Double(slotEpisodes.count) * 90) + carbBonus),
                    rationale: hubT(
                        "ti.rationale.cr.lower",
                        highCount,
                        slotEpisodes.count,
                        formatGlucose(highMeanRise, isMmol: isMmol)
                    ),
                    apply: .cr(slotStartMinute: entry.startMinute, proposed: proposed)
                ))
            }
        }
        return suggestions
    }

    // MARK: - Profil-Dateien

    /// Liest basal_profile.json: `[{"start":"00:00:00","minutes":0,"rate":0.85}, …]`
    private static func basalSchedule() -> [(startMinute: Int, rate: Double)]? {
        guard let raw = BaseFileStorage().retrieveRaw(OpenAPS.Settings.basalProfile),
              let data = raw.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return entries.compactMap { entry in
            guard let rate = (entry["rate"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (entry["minutes"] as? NSNumber)?.intValue ?? 0
            return (minutes, rate)
        }.sorted { $0.startMinute < $1.startMinute }
    }

    private static func rate(forHour hour: Int, in schedule: [(startMinute: Int, rate: Double)]) -> Double {
        schedule.last(where: { $0.startMinute <= hour * 60 })?.rate ?? schedule.first?.rate ?? 0
    }

    /// Liest insulin_sensitivities.json. `display` ist der Wert in
    /// Profil-Einheiten (so wie in den Einstellungen sichtbar),
    /// `mgdlPerU` der Rechenwert.
    private static func isfProfile() -> (entries: [(startMinute: Int, mgdlPerU: Double, display: Double)], isMmol: Bool)? {
        guard let raw = BaseFileStorage().retrieveRaw(OpenAPS.Settings.insulinSensitivities),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["sensitivities"] as? [[String: Any]]
        else { return nil }
        let isMmol = ((object["units"] as? String) ?? "").lowercased().contains("mmol")
        let entries = list.compactMap { entry -> (Int, Double, Double)? in
            guard let value = (entry["sensitivity"] as? NSNumber)?.doubleValue, value > 0 else { return nil }
            let offset = (entry["offset"] as? NSNumber)?.intValue ?? 0
            return (offset, isMmol ? value * 18.0 : value, value)
        }.sorted { $0.0 < $1.0 }
        return (entries, isMmol)
    }

    /// Liest carb_ratios.json: `{"units":"grams","schedule":[{"offset":0,"ratio":10}, …]}`
    private static func crProfile() -> [(startMinute: Int, ratio: Double)]? {
        guard let raw = BaseFileStorage().retrieveRaw(OpenAPS.Settings.carbRatios),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["schedule"] as? [[String: Any]]
        else { return nil }
        return list.compactMap { entry -> (Int, Double)? in
            guard let ratio = (entry["ratio"] as? NSNumber)?.doubleValue, ratio > 0 else { return nil }
            let offset = (entry["offset"] as? NSNumber)?.intValue ?? 0
            return (offset, ratio)
        }.sorted { $0.startMinute < $1.startMinute }
    }

    private static func slotIndex(forMinute minute: Int, in startMinutes: [Int]) -> Int {
        startMinutes.lastIndex(where: { $0 <= minute }) ?? 0
    }

    /// Zeitfenster eines Profil-Slots; nil bei nur einem Eintrag (ganztägig).
    private static func slotTimeText(_ startMinutes: [Int], _ index: Int) -> String? {
        guard startMinutes.count > 1 else { return nil }
        let end = index + 1 < startMinutes.count ? startMinutes[index + 1] : 24 * 60
        return timeRange(startMinutes[index], end)
    }

    // MARK: - Reading-Lookups (binäre Suche über sortierte Daten)

    private static func lowerBound(_ dates: [Date], _ target: Date) -> Int {
        var low = 0
        var high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func containsDate(_ dates: [Date], after start: Date, until end: Date) -> Bool {
        let index = lowerBound(dates, start)
        return index < dates.count && dates[index] <= end
    }

    private static func nearestGlucose(
        to target: Date,
        tolerance: TimeInterval,
        _ readings: [(date: Date, glucose: Int)],
        _ dates: [Date]
    ) -> Double? {
        let index = lowerBound(dates, target)
        var best: (interval: TimeInterval, glucose: Int)?
        for candidate in [index - 1, index] where candidate >= 0 && candidate < readings.count {
            let interval = abs(readings[candidate].date.timeIntervalSince(target))
            if interval <= tolerance, interval < (best?.interval ?? .infinity) {
                best = (interval, readings[candidate].glucose)
            }
        }
        return best.map { Double($0.glucose) }
    }

    private static func minGlucose(
        from start: Date,
        to end: Date,
        _ readings: [(date: Date, glucose: Int)],
        _ dates: [Date]
    ) -> Double? {
        let lower = lowerBound(dates, start)
        let upper = lowerBound(dates, end)
        guard lower < upper else { return nil }
        return readings[lower ..< upper].map { Double($0.glucose) }.min()
    }

    // MARK: - Helpers

    private static func roundedRate(_ rate: Double) -> Double {
        max(0.05, (rate / 0.05).rounded() * 0.05)
    }

    private static func roundedISF(_ value: Double, isMmol: Bool) -> Double {
        isMmol ? (value * 10).rounded() / 10 : value.rounded()
    }

    private static func roundedCR(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func formatISF(_ value: Double, isMmol: Bool) -> String {
        isMmol ? String(format: "%.1f mmol/L/U", value) : String(format: "%.0f mg/dL/U", value)
    }

    private static func formatCR(_ value: Double) -> String {
        String(format: "%.1f g/U", value)
    }

    private static func minuteOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func timeRange(_ startMinute: Int, _ endMinute: Int) -> String {
        String(
            format: "%02d:%02d – %02d:%02d",
            startMinute / 60,
            startMinute % 60,
            (endMinute / 60) % 24,
            endMinute % 60
        )
    }

    static func formatGlucose(_ mgdl: Double, isMmol: Bool) -> String {
        isMmol ? String(format: "%.1f mmol/L", mgdl / 18.0) : "\(Int(mgdl.rounded())) mg/dL"
    }
}
