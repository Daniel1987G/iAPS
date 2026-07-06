import Foundation

/// Gemeinsamer Statistik-Kern der AI-Hub-Analysen (Recap, Therapy Insights,
/// künftige Module wie Hypo-Forensik).
///
/// Genau EINE Definition für Periodenstatistik und Hypo-Episoden: vorher
/// rechneten Recap und Therapy Insights beides unabhängig — bei einer
/// Änderung der Episoden-Definition wären die Module auseinandergelaufen
/// (Recap zeigt „8 Hypos", die andere Engine analysiert 9).
enum AIHubGlucoseStats {
    struct Summary {
        let readingCount: Int
        let meanMgdl: Double
        let tir: Double // 70–180, 0–1
        let below: Double // Anteil < 70
        let above: Double // Anteil > 180
        let cv: Double // Variationskoeffizient, 0–1
    }

    /// nil bei leerer Eingabe. Mindestmengen (z. B. ≥ 50 Readings)
    /// verantworten die Aufrufer — die Anforderungen unterscheiden sich.
    static func summary(of readings: [(date: Date, glucose: Int)]) -> Summary? {
        guard !readings.isEmpty else { return nil }
        let values = readings.map { Double($0.glucose) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let sd = variance.squareRoot()
        return Summary(
            readingCount: readings.count,
            meanMgdl: mean,
            tir: Double(readings.filter { $0.glucose >= 70 && $0.glucose <= 180 }.count) / Double(values.count),
            below: Double(readings.filter { $0.glucose < 70 }.count) / Double(values.count),
            above: Double(readings.filter { $0.glucose > 180 }.count) / Double(values.count),
            cv: mean > 0 ? sd / mean : 0
        )
    }

    /// Startzeitpunkte zusammenhängender Hypo-Episoden: Phasen < 70 mg/dl;
    /// eine Lücke > 20 min zwischen niedrigen Werten trennt Episoden.
    /// Readings müssen zeitlich aufsteigend sortiert sein.
    static func hypoEpisodeStarts(in readings: [(date: Date, glucose: Int)]) -> [Date] {
        var starts: [Date] = []
        var inEpisode = false
        var lastLowDate: Date?
        for reading in readings {
            if reading.glucose < 70 {
                if let last = lastLowDate, reading.date.timeIntervalSince(last) > 20 * 60 {
                    inEpisode = false
                }
                if !inEpisode {
                    starts.append(reading.date)
                    inEpisode = true
                }
                lastLowDate = reading.date
            } else {
                inEpisode = false
            }
        }
        return starts
    }
}
