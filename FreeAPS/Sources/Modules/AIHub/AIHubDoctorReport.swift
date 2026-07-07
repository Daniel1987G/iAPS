import CoreData
import Foundation
import UIKit
import WebKit

/// Arztbericht-Export: strukturierter PDF-Bericht über 30/90 Tage für den
/// Praxisbesuch — Zeit in Bereichen (internationaler Konsens inkl. < 54),
/// Kennzahlen (Mittelwert, GMI, SD, CV, CGM-Abdeckung), Hypo-Bilanz mit
/// der Forensik-Klassifizierung, Insulin/Carbs, komplettes Therapieprofil
/// und die wichtigsten Loop-Einstellungen.
///
/// Muster wie die übrigen Module: Zahlen komplett lokal und deterministisch
/// (gemeinsamer Kern AIHubGlucoseStats + Hypo-Forensik); die optionale
/// KI-Zusammenfassung wird klar gekennzeichnet und pro Tag/Periode gecacht.
/// PDF: lokalisiertes HTML → UIMarkupTextPrintFormatter → A4-Seiten
/// (automatische Paginierung), Weitergabe übers System-Share-Sheet.
enum AIHubDoctorReport {
    // MARK: - Modelle

    struct Segment {
        let timeText: String
        let valueText: String
    }

    struct ReportData {
        let days: Int
        let generatedAt: Date
        let isMmol: Bool

        // Glykämie
        let readingCount: Int
        let coverage: Double // 0–1, gegen 288 Messwerte/Tag
        let meanMgdl: Double
        let sdMgdl: Double
        let cv: Double
        let gmi: Double // %
        // Zeit in Bereichen (internationaler Konsens), Anteile 0–1
        let veryLow: Double // < 54
        let low: Double // 54–69
        let inRange: Double // 70–180
        let high: Double // 181–250
        let veryHigh: Double // > 250

        // Hypoglykämien (aus der Hypo-Forensik). Tupel-Feld heißt bewusst
        // `total`, nicht `count` — SwiftFormats isEmpty-Regel schreibt
        // `.count > 0` sonst zu `!.isEmpty` um (Int hat kein isEmpty).
        let hypoCount: Int
        let nocturnalCount: Int
        let meanHypoDurationMinutes: Int
        let causeCounts: [(label: String, total: Int)]

        // Insulin & Kohlenhydrate
        let tddMean: Double
        let basalPerDay: Double
        let loggedCarbsPerDay: Double
        let carbsComplete: Bool

        // Therapieprofil (Anzeige-Einheiten)
        let basalSegments: [Segment]
        let isfSegments: [Segment]
        let crSegments: [Segment]
        let targetSegments: [Segment]

        // Loop-Einstellungen
        let maxIOBText: String
        let maxCOBText: String
        let smbEnabled: Bool
        let thresholdText: String
        let appVersion: String

        var basalShare: Double { tddMean > 0 ? basalPerDay / tddMean : 0 }
    }

    // MARK: - Datenaufbau (synchron, off-main aufrufen)

    static func build(days: Int) -> ReportData? {
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let calendar = Calendar.current

        var readings: [(date: Date, glucose: Int)] = []
        var tddByDay: [Date: Double] = [:]
        var carbsTotal = 0.0

        context.performAndWait {
            let readingsReq = NSFetchRequest<Readings>(entityName: "Readings")
            readingsReq.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
            readingsReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            readings = ((try? context.fetch(readingsReq)) ?? [])
                .compactMap { row in row.date.map { ($0, Int(row.glucose)) } }

            let reasonsReq = NSFetchRequest<Reasons>(entityName: "Reasons")
            reasonsReq.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
            for row in (try? context.fetch(reasonsReq)) ?? [] {
                if let date = row.date, let tdd = row.tdd?.doubleValue, tdd > 0 {
                    tddByDay[calendar.startOfDay(for: date)] = tdd
                }
            }

            // Meals: `date` ist beim Speichern nicht gesetzt — `actualDate`
            // ist das zuverlässige Datum (siehe InsightsExportLite).
            let mealsReq = NSFetchRequest<Meals>(entityName: "Meals")
            mealsReq.sortDescriptors = [NSSortDescriptor(key: "actualDate", ascending: true)]
            for row in (try? context.fetch(mealsReq)) ?? [] {
                guard let date = row.actualDate ?? row.createdAt, date >= cutoff,
                      let carbs = (row.value(forKey: "carbs") as? NSNumber)?.doubleValue, carbs > 0
                else { continue }
                carbsTotal += carbs
            }
        }

        guard readings.count >= 100,
              let summary = AIHubGlucoseStats.summary(of: readings) else { return nil }

        let isMmol = (BaseFileStorage().retrieveRaw(OpenAPS.Settings.bgTargets) ?? "")
            .lowercased().contains("mmol")

        let total = Double(readings.count)
        let veryLow = Double(readings.filter { $0.glucose < 54 }.count) / total
        let high = Double(readings.filter { $0.glucose > 180 && $0.glucose <= 250 }.count) / total
        let veryHigh = Double(readings.filter { $0.glucose > 250 }.count) / total

        // Hypo-Bilanz aus der Forensik (gleiche Klassifizierung wie im Modul)
        let forensics = AIHubHypoForensics.analyze(days: days)
        let causeCounts = AIHubHypoForensics.Cause.allCases
            .map { (label: $0.label, total: forensics.count(of: $0)) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }

        let tddMean = tddByDay.isEmpty ? 0 : tddByDay.values.reduce(0, +) / Double(tddByDay.count)
        let preferences = BaseFileStorage().retrieve(OpenAPS.Settings.preferences, as: Preferences.self)
            ?? Preferences()
        let smbEnabled = preferences.enableSMBAlways || preferences.enableSMBWithCOB ||
            preferences.enableSMBWithTemptarget || preferences.enableSMBAfterCarbs ||
            preferences.enableSMB_high_bg
        let threshold = Double(truncating: preferences.threshold_setting as NSNumber)

        return ReportData(
            days: days,
            generatedAt: Date(),
            isMmol: isMmol,
            readingCount: readings.count,
            coverage: min(1, total / (Double(days) * 288)),
            meanMgdl: summary.meanMgdl,
            sdMgdl: summary.cv * summary.meanMgdl,
            cv: summary.cv,
            gmi: 3.31 + 0.02392 * summary.meanMgdl,
            veryLow: veryLow,
            low: summary.below - veryLow,
            inRange: summary.tir,
            high: high,
            veryHigh: veryHigh,
            hypoCount: forensics.episodes.count,
            nocturnalCount: forensics.episodes.filter(\.isNocturnal).count,
            meanHypoDurationMinutes: forensics.meanDurationMinutes,
            causeCounts: causeCounts,
            tddMean: tddMean,
            basalPerDay: basalSum(),
            loggedCarbsPerDay: carbsTotal / Double(days),
            carbsComplete: UserDefaults.standard.aiHubCarbsComplete,
            basalSegments: basalSegments(),
            isfSegments: isfSegments(),
            crSegments: crSegments(),
            targetSegments: targetSegments(),
            maxIOBText: trimmed(Double(truncating: preferences.maxIOB as NSNumber)),
            maxCOBText: trimmed(Double(truncating: preferences.maxCOB as NSNumber)),
            smbEnabled: smbEnabled,
            thresholdText: AIHubTherapyAnalysis.formatGlucose(threshold, isMmol: isMmol),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        )
    }

    // MARK: - HTML (lokalisiert, Anzeige-Einheiten)

    static func html(for data: ReportData, aiSummary: String?) -> String {
        let unit = hubT("sim.unit.insulin")
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        let generated = dateFormatter.string(from: data.generatedAt)
        let from = dateFormatter.string(
            from: data.generatedAt.addingTimeInterval(-Double(data.days) * 24 * 3600)
        )

        func glucose(_ mgdl: Double) -> String {
            AIHubTherapyAnalysis.formatGlucose(mgdl, isMmol: data.isMmol)
        }
        func pct(_ share: Double, digits: Int = 1) -> String {
            num(share * 100, digits: digits) + " %"
        }
        func row(_ label: String, _ value: String) -> String {
            "<tr><td>\(label)</td><td class=\"v\">\(value)</td></tr>"
        }
        func segmentTable(_ title: String, _ segments: [Segment]) -> String {
            guard !segments.isEmpty else { return "" }
            let rows = segments
                .map { "<tr><td>\($0.timeText)</td><td class=\"v\">\($0.valueText)</td></tr>" }
                .joined()
            // .keep: Überschrift + Tabelle möglichst auf einer Seite halten
            return "<div class=\"keep\"><h3>\(title)</h3><table>\(rows)</table></div>"
        }

        // Gestapelter TIR-Balken als Tabelle (überlebt den HTML→PDF-Renderer)
        let buckets: [(share: Double, color: String)] = [
            (data.veryLow, "#8e1b1b"),
            (data.low, "#d64545"),
            (data.inRange, "#3aa655"),
            (data.high, "#e8a33d"),
            (data.veryHigh, "#d97e12")
        ]
        let barCells = buckets
            .filter { $0.share > 0.001 }
            .map { "<td style=\"background:\($0.color);width:\(max(2, Int($0.share * 100)))%\">&nbsp;</td>" }
            .joined()
        let rangeBounds = data.isMmol
            ? (very: "3,0", low: "3,9", high: "10,0", veryHigh: "13,9")
            : (very: "54", low: "70", high: "180", veryHigh: "250")
        let tirRows = [
            ("\(hubT("dr.tir.veryhigh")) (&gt; \(rangeBounds.veryHigh))", pct(data.veryHigh)),
            ("\(hubT("dr.tir.high")) (\(rangeBounds.high)–\(rangeBounds.veryHigh))", pct(data.high)),
            ("\(hubT("dr.tir.inrange")) (\(rangeBounds.low)–\(rangeBounds.high))", "<b>" + pct(data.inRange) + "</b>"),
            ("\(hubT("dr.tir.low")) (\(rangeBounds.very)–\(rangeBounds.low))", pct(data.low)),
            ("\(hubT("dr.tir.verylow")) (&lt; \(rangeBounds.very))", pct(data.veryLow))
        ].map { row($0.0, $0.1) }.joined()

        var hypoSection = "<table>" +
            row(hubT("dr.l.episodes"), "\(data.hypoCount)") +
            row(hubT("dr.l.nocturnal"), "\(data.nocturnalCount)") +
            (data.hypoCount > 0 ? row(hubT("dr.l.hypoduration"), "\(data.meanHypoDurationMinutes) min") : "") +
            "</table>"
        if !data.causeCounts.isEmpty {
            let causes = data.causeCounts
                .map { row($0.label, "\($0.total)×") }
                .joined()
            hypoSection += "<h3>\(hubT("dr.l.causes"))</h3><table>\(causes)</table>"
        }

        let carbsNote = data.carbsComplete ? "" : " <span class=\"note\">\(hubT("dr.carbs.incomplete"))</span>"

        var aiBlock = ""
        if let aiSummary = aiSummary, !aiSummary.isEmpty {
            aiBlock = """
            <div class="keep"><h2>\(hubT("dr.h.ai"))</h2>
            <p class="ai">\(aiSummary.replacingOccurrences(of: "\n", with: "<br>"))</p></div>
            """
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            body { font-family: -apple-system, Helvetica, sans-serif; font-size: 12px; color: #111;
                   -webkit-print-color-adjust: exact; print-color-adjust: exact; }
            h1 { font-size: 20px; margin-bottom: 2px; }
            h2 { font-size: 15px; margin: 18px 0 6px 0; border-bottom: 1px solid #999; padding-bottom: 3px; }
            h3 { font-size: 12px; margin: 10px 0 4px 0; }
            table { border-collapse: collapse; width: 100%; }
            td { border: 1px solid #ccc; padding: 4px 8px; }
            td.v { text-align: right; font-variant-numeric: tabular-nums; width: 38%; }
            .meta { color: #555; font-size: 11px; margin-bottom: 4px; }
            .note { color: #777; font-size: 10px; }
            .ai { border: 1px solid #b9a7e0; background: #f4effc; padding: 8px; font-size: 11.5px; }
            .footer { color: #777; font-size: 9.5px; margin-top: 22px; border-top: 1px solid #ccc; padding-top: 6px; }
            .bar { margin: 6px 0 8px 0; }
            .bar td { border: none; padding: 0; height: 14px; font-size: 1px; }
            /* Saubere Seitenumbrüche: Zeilen nie zerschneiden; Überschriften
               werden per .keep-Div fest mit ihrem ersten Inhaltsblock
               verklebt — page-break-after:avoid ignoriert WebKit beim
               Paginieren (Test: "Therapieprofil" verwaist auf Seite 1). */
            tr { page-break-inside: avoid; }
            .keep { page-break-inside: avoid; }
        </style>
        </head>
        <body>
        <h1>\(hubT("dr.h.title"))</h1>
        <div class="meta">\(hubT("dr.h.period")): \(from) – \(generated) (\(data.days) \(hubT("dr.days")))</div>
        <div class="meta">\(hubT("dr.h.generated")): \(generated) · \(hubT("dr.l.app")): iAPS \(data.appVersion) (oref)</div>

        <div class="keep">
        <h2>\(hubT("dr.h.glycemia"))</h2>
        <table>
        \(row(hubT("dr.l.mean"), glucose(data.meanMgdl)))
        \(row(hubT("dr.l.gmi"), num(data.gmi, digits: 1) + " %"))
        \(row(hubT("dr.l.sd"), glucose(data.sdMgdl)))
        \(row(hubT("dr.l.cv"), pct(data.cv, digits: 0)))
        \(row(hubT("dr.l.coverage"), pct(data.coverage, digits: 0) + " (\(data.readingCount) \(hubT("dr.l.readings")))"))
        </table>
        </div>

        <div class="keep">
        <h2>\(hubT("dr.h.tir"))</h2>
        <table class="bar"><tr>\(barCells)</tr></table>
        <table>\(tirRows)</table>
        </div>

        <div class="keep">
        <h2>\(hubT("dr.h.hypos"))</h2>
        \(hypoSection)
        </div>

        <div class="keep">
        <h2>\(hubT("dr.h.insulin"))</h2>
        <table>
        \(row(hubT("dr.l.tdd"), num(data.tddMean, digits: 1) + " \(unit)"))
        \(row(hubT("dr.l.basalday"), num(data.basalPerDay, digits: 1) + " \(unit) (\(pct(data.basalShare, digits: 0)))"))
        \(row(hubT("dr.l.carbs"), num(data.loggedCarbsPerDay, digits: 0) + " g" + carbsNote))
        </table>
        </div>

        <div class="keep">
        <h2>\(hubT("dr.h.profile"))</h2>
        \(segmentTable(hubT("dr.l.basalprofile"), data.basalSegments))
        </div>
        \(segmentTable(hubT("dr.l.isf"), data.isfSegments))
        \(segmentTable(hubT("dr.l.cr"), data.crSegments))
        \(segmentTable(hubT("dr.l.target"), data.targetSegments))

        <div class="keep">
        <h2>\(hubT("dr.h.loop"))</h2>
        <table>
        \(row(hubT("dr.l.maxiob"), data.maxIOBText + " \(unit)"))
        \(row(hubT("dr.l.maxcob"), data.maxCOBText + " g"))
        \(row(hubT("dr.l.smb"), data.smbEnabled ? hubT("dr.yes") : hubT("dr.no")))
        \(row(hubT("dr.l.threshold"), data.thresholdText))
        </table>
        </div>

        \(aiBlock)

        <div class="footer">\(hubT("dr.footer"))</div>
        </body>
        </html>
        """
    }

    // MARK: - PDF

    /// Schreibt das PDF ins Temp-Verzeichnis (Dateiname mit Datum) und
    /// liefert die URL fürs Share-Sheet.
    static func writePDF(_ data: Data, generatedAt: Date) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iAPS-Report-\(formatter.string(from: generatedAt)).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - KI-Zusammenfassung

    static func narrativePrompt(for data: ReportData) -> String {
        var facts: [String] = []
        facts.append(String(
            format: "Period: last %d days. Mean glucose %.0f mg/dL, GMI %.1f%%, SD %.0f, CV %.0f%%, " +
                "CGM coverage %.0f%%.",
            data.days,
            data.meanMgdl,
            data.gmi,
            data.sdMgdl,
            data.cv * 100,
            data.coverage * 100
        ))
        facts.append(String(
            format: "Time in ranges: <54: %.1f%%, 54-69: %.1f%%, 70-180: %.1f%%, 181-250: %.1f%%, >250: %.1f%%.",
            data.veryLow * 100,
            data.low * 100,
            data.inRange * 100,
            data.high * 100,
            data.veryHigh * 100
        ))
        facts.append(
            "Hypo episodes: \(data.hypoCount) (\(data.nocturnalCount) nocturnal), " +
                "mean duration \(data.meanHypoDurationMinutes) min."
        )
        facts.append(String(
            format: "Mean TDD %.1f U, profile basal %.1f U/day (%.0f%%), logged carbs %.0f g/day (%@).",
            data.tddMean,
            data.basalPerDay,
            data.basalShare * 100,
            data.loggedCarbsPerDay,
            data.carbsComplete ? "complete logging" : "possibly incomplete logging"
        ))

        return """
        You are the AI assistant inside iAPS (DIY closed-loop insulin app, oref/OpenAPS algorithm). \
        Write a short summary paragraph for a diabetes report the user brings to their doctor. \
        Language: \(AIHubL10n.aiAnswerLanguageName).

        Rules:
        - ONE paragraph, 3 to 5 sentences, neutral and factual tone (it will be read by a clinician).
        - Summarize glycemic control, variability and the hypoglycemia picture; name at most one \
        notable pattern worth discussing.
        - No treatment instructions, no dosing advice, no praise/emotion — observations only.
        - Glucose values in the data are mg/dL; present them in \(data
            .isMmol ? "mmol/L (divide by 18, one decimal)" : "mg/dL").
        - No greeting, no closing line.

        === DATA ===
        \(facts.joined(separator: "\n"))
        """
    }

    // MARK: - Narrative-Cache (pro Tag und Periode)

    private static func cacheKey(days: Int) -> String { "iAPS.aiHubReportText.\(days)" }
    private static func cacheDateKey(days: Int) -> String { "iAPS.aiHubReportDate.\(days)" }

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

    // MARK: - Profil-Segmente (Rohdateien wie AIHubTherapyAnalysis/MealSim)

    private static func basalSum() -> Double {
        guard let entries = basalEntries(), !entries.isEmpty else { return 0 }
        var sum = 0.0
        for (index, entry) in entries.enumerated() {
            let end = index + 1 < entries.count ? entries[index + 1].minute : 24 * 60
            sum += entry.value * Double(end - entry.minute) / 60.0
        }
        return sum
    }

    private static func basalSegments() -> [Segment] {
        let unit = hubT("sim.unit.insulin")
        return segments(from: basalEntries()) { num($0, digits: 2) + " \(unit)/h" }
    }

    private static func isfSegments() -> [Segment] {
        guard let raw = BaseFileStorage().retrieveRaw(OpenAPS.Settings.insulinSensitivities),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["sensitivities"] as? [[String: Any]]
        else { return [] }
        let isMmol = ((object["units"] as? String) ?? "").lowercased().contains("mmol")
        let unit = (isMmol ? "mmol/L" : "mg/dL") + "/" + hubT("sim.unit.insulin")
        let entries = list.compactMap { entry -> (minute: Int, value: Double)? in
            guard let value = (entry["sensitivity"] as? NSNumber)?.doubleValue, value > 0 else { return nil }
            return ((entry["offset"] as? NSNumber)?.intValue ?? 0, value)
        }.sorted { $0.minute < $1.minute }
        return segments(from: entries) { num($0, digits: isMmol ? 1 : 0) + " \(unit)" }
    }

    private static func crSegments() -> [Segment] {
        guard let raw = BaseFileStorage().retrieveRaw(OpenAPS.Settings.carbRatios),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["schedule"] as? [[String: Any]]
        else { return [] }
        let unit = "g/" + hubT("sim.unit.insulin")
        let entries = list.compactMap { entry -> (minute: Int, value: Double)? in
            guard let ratio = (entry["ratio"] as? NSNumber)?.doubleValue, ratio > 0 else { return nil }
            return ((entry["offset"] as? NSNumber)?.intValue ?? 0, ratio)
        }.sorted { $0.minute < $1.minute }
        return segments(from: entries) { num($0, digits: 1) + " \(unit)" }
    }

    private static func targetSegments() -> [Segment] {
        guard let raw = BaseFileStorage().retrieveRaw(OpenAPS.Settings.bgTargets),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["targets"] as? [[String: Any]]
        else { return [] }
        let isMmol = ((object["units"] as? String) ?? "").lowercased().contains("mmol")
        let unit = isMmol ? "mmol/L" : "mg/dL"
        let entries = list.compactMap { entry -> (minute: Int, value: Double)? in
            guard let low = (entry["low"] as? NSNumber)?.doubleValue, low > 0 else { return nil }
            return ((entry["offset"] as? NSNumber)?.intValue ?? 0, low)
        }.sorted { $0.minute < $1.minute }
        return segments(from: entries) { num($0, digits: isMmol ? 1 : 0) + " \(unit)" }
    }

    private static func basalEntries() -> [(minute: Int, value: Double)]? {
        guard let raw = BaseFileStorage().retrieveRaw(OpenAPS.Settings.basalProfile),
              let data = raw.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return entries.compactMap { entry -> (minute: Int, value: Double)? in
            guard let rate = (entry["rate"] as? NSNumber)?.doubleValue else { return nil }
            return ((entry["minutes"] as? NSNumber)?.intValue ?? 0, rate)
        }.sorted { $0.minute < $1.minute }
    }

    private static func segments(
        from entries: [(minute: Int, value: Double)]?,
        format: (Double) -> String
    ) -> [Segment] {
        guard let entries = entries, !entries.isEmpty else { return [] }
        return entries.enumerated().map { index, entry in
            let end = index + 1 < entries.count ? entries[index + 1].minute : 24 * 60
            return Segment(
                timeText: String(
                    format: "%02d:%02d – %02d:%02d",
                    entry.minute / 60,
                    entry.minute % 60,
                    (end / 60) % 24,
                    end % 60
                ),
                valueText: format(entry.value)
            )
        }
    }

    // MARK: - Helpers

    /// Locale-bewusste Zahl (deutsches Komma im deutschen Bericht).
    private static func num(_ value: Double, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = false
        return formatter.string(from: value as NSNumber) ?? String(format: "%.\(digits)f", value)
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : num(value, digits: 2)
    }
}

/// HTML → A4-PDF über echtes WebKit: `WKWebView.viewPrintFormatter()`
/// respektiert die page-break-CSS-Regeln — der einfache
/// UIMarkupTextPrintFormatter zerschnitt Tabellenzeilen mitten am
/// Seitenumbruch (Richards Test-Feedback).
///
/// Main-Thread only. Die WebView lebt für die Dauer des Renderings als
/// starke Referenz in der Instanz; ein kurzer Layout-Aufschub nach
/// didFinish stellt sicher, dass WebKit fertig gesetzt hat.
final class AIHubPDFRenderer: NSObject, WKNavigationDelegate {
    static let shared = AIHubPDFRenderer()

    private var webView: WKWebView?
    private var completion: ((Data?) -> Void)?

    func render(html: String, completion: @escaping (Data?) -> Void) {
        // Laufendes Rendering nicht überlappen — der Button ist ohnehin
        // während des Renderns deaktiviert.
        guard self.completion == nil else {
            completion(nil)
            return
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 595.2, height: 841.8))
        webView.navigationDelegate = self
        self.webView = webView
        self.completion = completion
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.finish(with: webView)
        }
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        deliver(nil)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        deliver(nil)
    }

    private func finish(with webView: WKWebView) {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)

        // A4 bei 72 dpi, 36 pt Rand
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 36, dy: 36), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, .zero, nil)
        for pageIndex in 0 ..< renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: pageIndex, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        deliver(data as Data)
    }

    private func deliver(_ data: Data?) {
        let done = completion
        completion = nil
        webView = nil
        done?(data)
    }
}
