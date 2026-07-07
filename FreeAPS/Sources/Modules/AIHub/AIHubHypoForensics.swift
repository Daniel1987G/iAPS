import CoreData
import Foundation

/// Hypo-Forensik: klassifiziert jede Hypo-Episode (< 70 mg/dl, aus dem
/// gemeinsamen Kern AIHubGlucoseStats) anhand des Loop-Kontexts kurz vor
/// dem Start — und macht aus Einzel-Ereignissen ein Muster-Bild.
///
/// Muster wie Recap/Loop Check: komplett lokal und deterministisch; das
/// LLM liefert optional eine Einordnung auf Basis englischer Fakten-Zeilen
/// und wird pro Tag/Periode gecacht.
///
/// Klassifizierung (erste zutreffende Regel gewinnt):
/// 1. Mahlzeit   — COB > 0 im letzten Zyklus oder ≥ 10 g geloggte Carbs
///                 in den 3 h davor → Mahlzeiten-Insulin zu viel/zu früh.
/// 2. Überkorrektur — max. BG ≥ 180 in den 4 h davor UND IOB ≥ 1 U →
///                 die Korrektur schießt übers Ziel hinaus.
/// 3. Stapelung  — IOB ≥ 1 U ohne vorherigen hohen Wert → Boli/SMBs
///                 überlappen sich.
/// 4. Basal      — IOB < 1 U und COB = 0 → basal-getrieben (Regel aus
///                 Therapy Insights übernommen).
/// 5. Unklar     — kein Loop-Zyklus nah genug am Episodenstart.
enum AIHubHypoForensics {
    // MARK: - Modelle

    enum Cause: Int, CaseIterable, Identifiable {
        case meal
        case overcorrection
        case stacking
        case basal
        case unknown

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .meal: return hubT("hf.cause.meal")
            case .overcorrection: return hubT("hf.cause.overcorr")
            case .stacking: return hubT("hf.cause.stacking")
            case .basal: return hubT("hf.cause.basal")
            case .unknown: return hubT("hf.cause.unknown")
            }
        }

        var detail: String {
            switch self {
            case .meal: return hubT("hf.cause.meal.desc")
            case .overcorrection: return hubT("hf.cause.overcorr.desc")
            case .stacking: return hubT("hf.cause.stacking.desc")
            case .basal: return hubT("hf.cause.basal.desc")
            case .unknown: return hubT("hf.cause.unknown.desc")
            }
        }

        /// Maschinenlesbares Label für die KI-Fakten.
        var factLabel: String {
            switch self {
            case .meal: return "meal-related"
            case .overcorrection: return "overcorrection"
            case .stacking: return "insulin stacking"
            case .basal: return "basal-driven"
            case .unknown: return "unclassified"
            }
        }
    }

    struct Episode: Identifiable {
        let id = UUID()
        let start: Date
        let minMgdl: Int
        let durationMinutes: Int
        let cause: Cause
        let iobAtStart: Double
        let cobAtStart: Double
        /// Höchster BG in den 4 h vor dem Start (0 = keine Daten).
        let maxBGBefore: Int
        /// Geloggte Kohlenhydrate in den 3 h vor dem Start.
        let carbsBefore: Double
        /// 00:00–06:00 Uhr lokal.
        let isNocturnal: Bool
    }

    struct Result {
        let days: Int
        /// Neueste zuerst.
        let episodes: [Episode]
        /// Episoden-Zahl der gleich langen Vorperiode (nil = zu wenig Daten).
        let previousCount: Int?
        let meanMinMgdl: Double
        let meanDurationMinutes: Int
        let nocturnalShare: Double // 0–1
        /// Englische Fakten-Zeilen für den KI-Prompt.
        let facts: [String]
        let isMmol: Bool
        let readingCount: Int

        func count(of cause: Cause) -> Int {
            episodes.filter { $0.cause == cause }.count
        }
    }

    // MARK: - Analyse (synchron, off-main aufrufen)

    static func analyze(days: Int) -> Result {
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        let now = Date()
        let splitDate = now.addingTimeInterval(-Double(days) * 24 * 3600)
        // Vorperiode für den Vergleich, plus 4 h Kontext-Polster davor.
        let cutoff = now.addingTimeInterval(-Double(days) * 2 * 24 * 3600 - 4 * 3600)

        var readings: [(date: Date, glucose: Int)] = []
        var cycles: [(date: Date, iob: Double, cob: Double)] = []
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
            cycles = ((try? context.fetch(reasonsReq)) ?? [])
                .compactMap { row in
                    row.date.map { ($0, row.iob?.doubleValue ?? 0, row.cob?.doubleValue ?? 0) }
                }

            // Meals: `date` ist beim Speichern nicht gesetzt — `actualDate`
            // ist das zuverlässige Datum (siehe InsightsExportLite).
            let mealsReq = NSFetchRequest<Meals>(entityName: "Meals")
            mealsReq.sortDescriptors = [NSSortDescriptor(key: "actualDate", ascending: true)]
            meals = ((try? context.fetch(mealsReq)) ?? [])
                .compactMap { row -> (Date, Double)? in
                    guard let date = row.actualDate ?? row.createdAt, date >= cutoff,
                          let carbs = (row.value(forKey: "carbs") as? NSNumber)?.doubleValue, carbs > 0
                    else { return nil }
                    return (date, carbs)
                }
        }

        let isMmol = (BaseFileStorage().retrieveRaw(OpenAPS.Settings.bgTargets) ?? "")
            .lowercased().contains("mmol")

        let currentReadings = readings.filter { $0.date >= splitDate }
        guard currentReadings.count >= 100 else {
            return Result(
                days: days,
                episodes: [],
                previousCount: nil,
                meanMinMgdl: 0,
                meanDurationMinutes: 0,
                nocturnalShare: 0,
                facts: [],
                isMmol: isMmol,
                readingCount: currentReadings.count
            )
        }

        let calendar = Calendar.current
        let cycleDates = cycles.map(\.date)
        let readingDates = readings.map(\.date)

        let episodes = AIHubGlucoseStats.hypoEpisodes(in: currentReadings)
            .map { raw -> Episode in
                classify(
                    raw,
                    cycles: cycles,
                    cycleDates: cycleDates,
                    readings: readings,
                    readingDates: readingDates,
                    meals: meals,
                    calendar: calendar
                )
            }
            .sorted { $0.start > $1.start }

        // Vorperiode: nur zählen, und nur wenn sie halbwegs Daten hat.
        let previousReadings = readings.filter { $0.date < splitDate }
        let previousCount = previousReadings.count >= 100
            ? AIHubGlucoseStats.hypoEpisodes(in: previousReadings).count
            : nil

        let nocturnal = episodes.filter(\.isNocturnal).count
        let meanMin = episodes.isEmpty
            ? 0
            : episodes.map { Double($0.minMgdl) }.reduce(0, +) / Double(episodes.count)
        let meanDuration = episodes.isEmpty
            ? 0
            : episodes.map(\.durationMinutes).reduce(0, +) / episodes.count

        return Result(
            days: days,
            episodes: episodes,
            previousCount: previousCount,
            meanMinMgdl: meanMin,
            meanDurationMinutes: meanDuration,
            nocturnalShare: episodes.isEmpty ? 0 : Double(nocturnal) / Double(episodes.count),
            facts: buildFacts(
                episodes: episodes,
                days: days,
                previousCount: previousCount,
                nocturnal: nocturnal,
                meanMin: meanMin,
                meanDuration: meanDuration
            ),
            isMmol: isMmol,
            readingCount: currentReadings.count
        )
    }

    // MARK: - Klassifizierung

    private static let iobThreshold = 1.0 // U — darüber gilt Insulin als treibend
    private static let carbsWindow: TimeInterval = 3 * 3600
    private static let highWindow: TimeInterval = 4 * 3600
    private static let highThreshold = 180

    private static func classify(
        _ raw: AIHubGlucoseStats.HypoEpisode,
        cycles: [(date: Date, iob: Double, cob: Double)],
        cycleDates: [Date],
        readings: [(date: Date, glucose: Int)],
        readingDates: [Date],
        meals: [(date: Date, carbs: Double)],
        calendar: Calendar
    ) -> Episode {
        let start = raw.start

        // Letzter Loop-Zyklus bis 45 min vor Episodenstart (wie Therapy
        // Insights' Basal-Regel).
        let cycleIndex = lowerBound(cycleDates, start)
        var contextCycle: (date: Date, iob: Double, cob: Double)?
        if cycleIndex > 0 {
            let candidate = cycles[cycleIndex - 1]
            if start.timeIntervalSince(candidate.date) <= 45 * 60 {
                contextCycle = candidate
            }
        }

        let carbsBefore = meals
            .filter { $0.date >= start.addingTimeInterval(-carbsWindow) && $0.date < start }
            .map(\.carbs)
            .reduce(0, +)

        let lower = lowerBound(readingDates, start.addingTimeInterval(-highWindow))
        let upper = lowerBound(readingDates, start)
        let maxBGBefore = lower < upper ? readings[lower ..< upper].map(\.glucose).max() ?? 0 : 0

        let cause: Cause
        if let cycle = contextCycle {
            if cycle.cob > 0 || carbsBefore >= 10 {
                cause = .meal
            } else if cycle.iob >= iobThreshold, maxBGBefore >= highThreshold {
                cause = .overcorrection
            } else if cycle.iob >= iobThreshold {
                cause = .stacking
            } else {
                cause = .basal
            }
        } else {
            cause = .unknown
        }

        let hour = calendar.component(.hour, from: start)
        return Episode(
            start: start,
            minMgdl: raw.minMgdl,
            durationMinutes: raw.durationMinutes,
            cause: cause,
            iobAtStart: contextCycle?.iob ?? 0,
            cobAtStart: contextCycle?.cob ?? 0,
            maxBGBefore: maxBGBefore,
            carbsBefore: carbsBefore,
            isNocturnal: hour < 6
        )
    }

    // MARK: - KI-Fakten & Prompt

    private static func buildFacts(
        episodes: [Episode],
        days: Int,
        previousCount: Int?,
        nocturnal: Int,
        meanMin: Double,
        meanDuration: Int
    ) -> [String] {
        guard !episodes.isEmpty else {
            return ["No hypo episodes (< 70 mg/dL) in the last \(days) days."]
        }
        var facts: [String] = []
        var overview = "\(episodes.count) hypo episodes (< 70 mg/dL) in the last \(days) days"
        if let previous = previousCount {
            overview += " (previous \(days) days: \(previous))"
        }
        overview += String(
            format: ". Mean low %.0f mg/dL, mean duration %d min, %d nocturnal (00:00-06:00).",
            meanMin,
            meanDuration,
            nocturnal
        )
        facts.append(overview)

        let counts = Cause.allCases
            .map { cause in (cause, episodes.filter { $0.cause == cause }.count) }
            .filter { $0.1 > 0 }
            .map { "\($0.0.factLabel): \($0.1)" }
        facts.append("Classification: " + counts.joined(separator: ", ") + ".")
        facts.append(
            UserDefaults.standard.aiHubCarbsComplete
                ? "The user logs every meal — carb-free windows are facts."
                : "Carb logging is incomplete — 'no carbs logged' may still mean food was eaten."
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for episode in episodes.prefix(10) {
            facts.append(String(
                format: "%@: min %d mg/dL, %d min, IOB %.1f U, COB %.0f g, " +
                    "carbs logged 3h before: %.0f g, max BG 4h before: %d -> %@",
                formatter.string(from: episode.start),
                episode.minMgdl,
                episode.durationMinutes,
                episode.iobAtStart,
                episode.cobAtStart,
                episode.carbsBefore,
                episode.maxBGBefore,
                episode.cause.factLabel
            ))
        }
        return facts
    }

    static func narrativePrompt(for result: Result) -> String {
        var lines: [String] = []
        lines.append(
            """
            You are the AI assistant inside iAPS (DIY closed-loop insulin app, oref/OpenAPS \
            algorithm). A deterministic analysis classified the user's hypoglycemia episodes \
            of the last \(result.days) days by their likely driver. Write a short assessment \
            in \(AIHubL10n.aiAnswerLanguageName).

            Rules:
            - 3 to 5 bullet points starting with "•", each 1–3 sentences, most important first.
            - Focus on the DOMINANT pattern: what connects the episodes, at which times of day \
            they cluster, and what a cautious next step could be (small changes, one at a time; \
            basal/ISF/CR tuning belongs in Therapy Insights).
            - The classification is a heuristic — phrase causes as likelihoods, not verdicts.
            - Never give concrete bolus doses. Settings changes are the user's own decision and \
            worth discussing with their care team — say this once at most, briefly.
            - Glucose values in the data are mg/dL; present them in \(result
                .isMmol ? "mmol/L (divide by 18, one decimal)" : "mg/dL").
            - No greeting, no closing line, only the bullet points.
            """
        )
        lines.append("=== HYPO ANALYSIS ===")
        lines.append(result.facts.joined(separator: "\n"))
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Narrative-Cache (pro Tag und Periode, wie Recap/Loop Check)

    private static func cacheKey(days: Int) -> String { "iAPS.aiHubHypoText.\(days)" }
    private static func cacheDateKey(days: Int) -> String { "iAPS.aiHubHypoDate.\(days)" }

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

    // MARK: - Helpers

    private static func lowerBound(_ dates: [Date], _ target: Date) -> Int {
        var low = 0
        var high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
