import CoreData
import Foundation

/// Settings-Audit („Loop Check"): hält die oref-Einstellungen
/// (preferences.json, Pumpen-Limits, Basal-Profil) gegen die tatsächlichen
/// Loop-Daten der letzten 14/30/90 Tage.
///
/// Muster wie Recap: die Checks rechnen komplett lokal und deterministisch
/// aus Reasons/Readings/Meals — kostenlos, offline, reproduzierbar. Das LLM
/// liefert optional eine Einordnung; als Prompt-Grundlage dienen englische
/// Fakten-Zeilen mit denselben Zahlen (NICHT die lokalisierten UI-Texte)
/// plus die kompakte preferences.json, damit das Modell auch Dinge sehen
/// kann, die kein Detektor abdeckt. Die Einordnung wird pro Tag/Periode
/// gecacht.
///
/// Die Checks prüfen, ob Einstellungen den Loop BREMSEN oder ihm
/// widersprechen — Profil-Feintuning (Basal/ISF/CR pro Tageszeit) bleibt
/// Sache von Therapy Insights.
enum AIHubSettingsAudit {
    // MARK: - Modelle

    enum Severity: Int, Comparable {
        case ok = 0
        case info = 1
        case warn = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Finding: Identifiable {
        let id = UUID()
        let severity: Severity
        let title: String
        let detail: String
    }

    struct Result {
        let days: Int
        /// Sortiert: Auffälliges zuerst, dann Hinweise, dann OK.
        let findings: [Finding]
        /// Englische Fakten-Zeilen für den KI-Prompt (gleiche Zahlen wie
        /// die Findings, aber sprachunabhängig).
        let facts: [String]
        let cycleCount: Int
        let isMmol: Bool
    }

    // MARK: - Analyse (synchron, off-main aufrufen)

    static func analyze(days: Int) -> Result {
        let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)

        var readings: [Int] = []
        var cycles: [(glucose: Double, iob: Double, ratio: Double, rate: Double, smb: Double)] = []
        var tddByDay: [Date: Double] = [:]
        var meals: [(date: Date, carbs: Double)] = []

        context.performAndWait {
            let readingsReq = NSFetchRequest<Readings>(entityName: "Readings")
            readingsReq.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
            readings = ((try? context.fetch(readingsReq)) ?? []).map { Int($0.glucose) }

            let reasonsReq = NSFetchRequest<Reasons>(entityName: "Reasons")
            reasonsReq.predicate = NSPredicate(format: "date >= %@", cutoff as NSDate)
            reasonsReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            let calendar = Calendar.current
            for row in (try? context.fetch(reasonsReq)) ?? [] {
                cycles.append((
                    glucose: row.glucose?.doubleValue ?? 0,
                    iob: row.iob?.doubleValue ?? 0,
                    ratio: row.ratio?.doubleValue ?? 1,
                    rate: row.rate?.doubleValue ?? 0,
                    smb: row.smb?.doubleValue ?? 0
                ))
                // TDD: letzter Wert pro Tag (rollierender 24h-Wert), wie Recap
                if let date = row.date, let tdd = row.tdd?.doubleValue, tdd > 0 {
                    tddByDay[calendar.startOfDay(for: date)] = tdd
                }
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

        let storage = BaseFileStorage()
        let preferences = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self) ?? Preferences()
        let pumpSettings = storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self)
        let isMmol = (storage.retrieveRaw(OpenAPS.Settings.bgTargets) ?? "").lowercased().contains("mmol")

        // Mindestens ~½ Tag Loop-Zyklen und CGM-Daten, sonst keine Aussage
        guard cycles.count >= 100, readings.count >= 100 else {
            return Result(days: days, findings: [], facts: [], cycleCount: cycles.count, isMmol: isMmol)
        }

        let tddMean = tddByDay.isEmpty ? 0 : tddByDay.values.reduce(0, +) / Double(tddByDay.count)

        var findings: [Finding] = []
        var facts: [String] = []

        findings.append(maxIOBCheck(cycles: cycles, preferences: preferences, facts: &facts))
        if let pump = pumpSettings {
            findings.append(maxBasalCheck(cycles: cycles, pump: pump, facts: &facts))
        }
        findings.append(autosensCheck(cycles: cycles, preferences: preferences, facts: &facts))
        findings.append(smbCheck(cycles: cycles, readings: readings, preferences: preferences, facts: &facts))
        if let pump = pumpSettings {
            findings.append(diaCheck(pump: pump, preferences: preferences, facts: &facts))
        }
        findings.append(maxCOBCheck(meals: meals, preferences: preferences, facts: &facts))
        if let basalShare = basalShareCheck(tddMean: tddMean, facts: &facts) {
            findings.append(basalShare)
        }
        findings.append(thresholdCheck(readings: readings, preferences: preferences, isMmol: isMmol, facts: &facts))

        return Result(
            days: days,
            findings: findings.sorted { $0.severity > $1.severity },
            facts: facts,
            cycleCount: cycles.count,
            isMmol: isMmol
        )
    }

    // MARK: - Checks

    /// Max IOB: 0 legt SMBs/Extra-Insulin komplett still; sonst zählt der
    /// Anteil der Hoch-BG-Zyklen (> 180), in denen das IOB an der Kappe lag.
    private static func maxIOBCheck(
        cycles: [(glucose: Double, iob: Double, ratio: Double, rate: Double, smb: Double)],
        preferences: Preferences,
        facts: inout [String]
    ) -> Finding {
        let maxIOB = Double(truncating: preferences.maxIOB as NSNumber)
        let title = hubT("audit.maxiob.title")

        guard maxIOB > 0 else {
            facts.append("max_iob is 0: the loop can only reduce basal, it never adds insulin above the profile basal.")
            return Finding(severity: .warn, title: title, detail: hubT("audit.maxiob.zero"))
        }

        let maxIOBText = trimmed(maxIOB)
        let highCycles = cycles.filter { $0.glucose > 180 }
        guard highCycles.count >= 20 else {
            facts.append("max_iob \(maxIOBText) U: too few high-glucose cycles to judge (no problem visible).")
            return Finding(severity: .ok, title: title, detail: hubT("audit.maxiob.ok", maxIOBText))
        }

        let capped = highCycles.filter { $0.iob >= 0.9 * maxIOB }.count
        let share = Int((Double(capped) / Double(highCycles.count) * 100).rounded())
        facts.append(
            "max_iob \(maxIOBText) U: in \(share)% of high-glucose loop cycles (>180 mg/dL) " +
                "IOB was at >=90% of the cap (\(capped) of \(highCycles.count) cycles)."
        )
        if share >= 30 {
            return Finding(severity: .warn, title: title, detail: hubT("audit.maxiob.capped", share, maxIOBText))
        }
        if share >= 10 {
            return Finding(severity: .info, title: title, detail: hubT("audit.maxiob.capped", share, maxIOBText))
        }
        return Finding(severity: .ok, title: title, detail: hubT("audit.maxiob.ok", maxIOBText))
    }

    /// Max Basal: Anteil der Hoch-BG-Zyklen, in denen die Temp-Basal am
    /// Pumpen-Deckel lief — der Loop wollte mehr geben, durfte aber nicht.
    private static func maxBasalCheck(
        cycles: [(glucose: Double, iob: Double, ratio: Double, rate: Double, smb: Double)],
        pump: PumpSettings,
        facts: inout [String]
    ) -> Finding {
        let maxBasal = Double(truncating: pump.maxBasal as NSNumber)
        let title = hubT("audit.maxbasal.title")
        let maxBasalText = trimmed(maxBasal)

        let highCycles = cycles.filter { $0.glucose > 180 }
        guard maxBasal > 0, highCycles.count >= 20 else {
            facts.append("maxBasal \(maxBasalText) U/h: too few high-glucose cycles to judge (no problem visible).")
            return Finding(severity: .ok, title: title, detail: hubT("audit.maxbasal.ok", maxBasalText))
        }

        let capped = highCycles.filter { $0.rate >= 0.95 * maxBasal }.count
        let share = Int((Double(capped) / Double(highCycles.count) * 100).rounded())
        facts.append(
            "maxBasal \(maxBasalText) U/h: in \(share)% of high-glucose cycles the temp basal " +
                "ran at >=95% of the pump ceiling (\(capped) of \(highCycles.count) cycles)."
        )
        if share >= 30 {
            return Finding(severity: .warn, title: title, detail: hubT("audit.maxbasal.capped", share, maxBasalText))
        }
        if share >= 10 {
            return Finding(severity: .info, title: title, detail: hubT("audit.maxbasal.capped", share, maxBasalText))
        }
        return Finding(severity: .ok, title: title, detail: hubT("audit.maxbasal.ok", maxBasalText))
    }

    /// Autosens/Dynamische Ratio dauerhaft am Limit = das Grundprofil ist
    /// systematisch zu schwach/zu stark und der Algorithmus kompensiert nur.
    private static func autosensCheck(
        cycles: [(glucose: Double, iob: Double, ratio: Double, rate: Double, smb: Double)],
        preferences: Preferences,
        facts: inout [String]
    ) -> Finding {
        let maxRatio = Double(truncating: preferences.autosensMax as NSNumber)
        let minRatio = Double(truncating: preferences.autosensMin as NSNumber)
        let title = hubT("audit.autosens.title")
        let maxText = trimmed(maxRatio)
        let minText = trimmed(minRatio)

        let pinnedHigh = cycles.filter { $0.ratio >= maxRatio - 0.01 }.count
        let pinnedLow = cycles.filter { $0.ratio <= minRatio + 0.01 }.count
        let highShare = Int((Double(pinnedHigh) / Double(cycles.count) * 100).rounded())
        let lowShare = Int((Double(pinnedLow) / Double(cycles.count) * 100).rounded())
        facts.append(
            "autosens/dynamic ratio pinned at upper limit (autosens_max \(maxText)) in \(highShare)% " +
                "and at lower limit (autosens_min \(minText)) in \(lowShare)% of \(cycles.count) loop cycles."
        )

        if highShare >= 35 {
            return Finding(severity: .warn, title: title, detail: hubT("audit.autosens.high", maxText, highShare))
        }
        if lowShare >= 35 {
            return Finding(severity: .warn, title: title, detail: hubT("audit.autosens.low", minText, lowShare))
        }
        if highShare >= 15 {
            return Finding(severity: .info, title: title, detail: hubT("audit.autosens.high", maxText, highShare))
        }
        if lowShare >= 15 {
            return Finding(severity: .info, title: title, detail: hubT("audit.autosens.low", minText, lowShare))
        }
        return Finding(severity: .ok, title: title, detail: hubT("audit.autosens.ok", minText, maxText))
    }

    /// SMB-Konfiguration gegen die Datenlage: viel Zeit über 180 ohne SMBs
    /// ist die klassische Bremse; UAM aus bei unvollständigem Carb-Logging
    /// verschenkt die Reaktion auf unangekündigte Mahlzeiten.
    private static func smbCheck(
        cycles: [(glucose: Double, iob: Double, ratio: Double, rate: Double, smb: Double)],
        readings: [Int],
        preferences: Preferences,
        facts: inout [String]
    ) -> Finding {
        let title = hubT("audit.smb.title")
        let smbEnabled = preferences.enableSMBAlways || preferences.enableSMBWithCOB ||
            preferences.enableSMBWithTemptarget || preferences.enableSMBAfterCarbs ||
            preferences.enableSMB_high_bg
        let aboveShare = Int((Double(readings.filter { $0 > 180 }.count) / Double(readings.count) * 100).rounded())

        guard smbEnabled else {
            facts.append("All SMB switches are off. Time above 180 mg/dL: \(aboveShare)%.")
            if aboveShare > 25 {
                return Finding(severity: .warn, title: title, detail: hubT("audit.smb.off.high", aboveShare))
            }
            return Finding(severity: .info, title: title, detail: hubT("audit.smb.off"))
        }

        let usage = Int((Double(cycles.filter { $0.smb > 0 }.count) / Double(cycles.count) * 100).rounded())
        facts.append(
            "SMBs are enabled and were delivered in \(usage)% of loop cycles. " +
                "enableUAM: \(preferences.enableUAM). Time above 180 mg/dL: \(aboveShare)%."
        )
        if !preferences.enableUAM, !UserDefaults.standard.aiHubCarbsComplete {
            return Finding(severity: .info, title: title, detail: hubT("audit.smb.uam"))
        }
        return Finding(severity: .ok, title: title, detail: hubT("audit.smb.ok", usage))
    }

    /// DIA unter 5 h unterschätzt das IOB moderner Analoga (Stacking-Gefahr);
    /// die bilineare Kurve ist ein Altlast-Modell.
    private static func diaCheck(
        pump: PumpSettings,
        preferences: Preferences,
        facts: inout [String]
    ) -> Finding {
        let dia = Double(truncating: pump.insulinActionCurve as NSNumber)
        let title = hubT("audit.dia.title")
        let diaText = trimmed(dia)
        facts.append("DIA (insulin action) \(diaText) h, insulin curve: \(preferences.curve.rawValue).")

        if dia < 5 {
            return Finding(severity: .warn, title: title, detail: hubT("audit.dia.short", diaText))
        }
        if preferences.curve == .bilinear {
            return Finding(severity: .info, title: title, detail: hubT("audit.dia.bilinear"))
        }
        return Finding(severity: .ok, title: title, detail: hubT("audit.dia.ok", diaText, preferences.curve.rawValue))
    }

    /// Max COB gegen die größte geloggte Mahlzeit (Einträge < 90 min
    /// zusammengefasst, wie die CR-Engine): gekappte Carbs = spätes Insulin.
    private static func maxCOBCheck(
        meals: [(date: Date, carbs: Double)],
        preferences: Preferences,
        facts: inout [String]
    ) -> Finding {
        let maxCOB = Int(truncating: preferences.maxCOB as NSNumber)
        let title = hubT("audit.maxcob.title")

        var merged: [(date: Date, carbs: Double)] = []
        for meal in meals {
            if let last = merged.last, meal.date.timeIntervalSince(last.date) < 90 * 60 {
                merged[merged.count - 1].carbs += meal.carbs
            } else {
                merged.append(meal)
            }
        }
        let largest = Int(merged.map(\.carbs).max() ?? 0)
        facts.append("maxCOB \(maxCOB) g, largest logged meal in the period (90-min merged): \(largest) g.")

        if largest > maxCOB {
            return Finding(severity: .warn, title: title, detail: hubT("audit.maxcob.over", largest, maxCOB))
        }
        if Double(largest) > 0.8 * Double(maxCOB) {
            return Finding(severity: .info, title: title, detail: hubT("audit.maxcob.near", largest, maxCOB))
        }
        return Finding(severity: .ok, title: title, detail: hubT("audit.maxcob.ok", maxCOB, largest))
    }

    /// Klassische Faustregel: Basal ~40–50 % des TDD. Deutlich darüber
    /// maskiert fehlende Mahlzeiten-Boli und begünstigt Hypos, deutlich
    /// darunter trägt der Bolus den Tag.
    private static func basalShareCheck(tddMean: Double, facts: inout [String]) -> Finding? {
        guard tddMean > 0, let schedule = basalSchedule(), !schedule.isEmpty else { return nil }

        // Tages-Basal aus dem Profil: Rate × Blockdauer, letzter Block bis 24:00
        var dailyBasal = 0.0
        for (index, entry) in schedule.enumerated() {
            let end = index + 1 < schedule.count ? schedule[index + 1].startMinute : 24 * 60
            dailyBasal += entry.rate * Double(end - entry.startMinute) / 60.0
        }
        guard dailyBasal > 0 else { return nil }

        let share = Int((dailyBasal / tddMean * 100).rounded())
        let title = hubT("audit.basalshare.title")
        let tddText = String(format: "%.1f", tddMean)
        facts.append(
            "Profile basal sum \(String(format: "%.1f", dailyBasal)) U/day = \(share)% of mean TDD (\(tddText) U). " +
                "Typical is 40-50%."
        )

        if share > 60 {
            return Finding(severity: .info, title: title, detail: hubT("audit.basalshare.high", share, tddText))
        }
        if share < 30 {
            return Finding(severity: .info, title: title, detail: hubT("audit.basalshare.low", share, tddText))
        }
        return Finding(severity: .ok, title: title, detail: hubT("audit.basalshare.ok", share))
    }

    /// Sicherheits-Schwelle (threshold_setting) gegen die reale Hypo-Quote:
    /// bei häufigen Hypos schneidet eine höhere Schwelle das Insulin früher ab.
    private static func thresholdCheck(
        readings: [Int],
        preferences: Preferences,
        isMmol: Bool,
        facts: inout [String]
    ) -> Finding {
        let threshold = Double(truncating: preferences.threshold_setting as NSNumber)
        let title = hubT("audit.threshold.title")
        let thresholdText = AIHubTherapyAnalysis.formatGlucose(threshold, isMmol: isMmol)
        let lowShare = Double(readings.filter { $0 < 70 }.count) / Double(readings.count) * 100
        let lowText = String(format: "%.1f", lowShare)
        facts.append(
            "Safety threshold (threshold_setting) \(trimmed(threshold)) mg/dL, " +
                "time below 70 mg/dL: \(lowText)%."
        )

        if lowShare > 4 {
            return Finding(severity: .info, title: title, detail: hubT("audit.threshold.hypos", lowText, thresholdText))
        }
        return Finding(severity: .ok, title: title, detail: hubT("audit.threshold.ok", thresholdText, lowText))
    }

    // MARK: - KI-Einordnung

    static func narrativePrompt(for result: Result) -> String {
        let storage = BaseFileStorage()
        var lines: [String] = []
        lines.append(
            """
            You are the AI assistant inside iAPS (DIY closed-loop insulin app, oref/OpenAPS \
            algorithm). A deterministic audit compared the user's oref settings with their \
            actual loop data of the last \(result.days) days. Write a short assessment in \
            \(AIHubL10n.aiAnswerLanguageName).

            Rules:
            - 3 to 5 bullet points starting with "•", each 1–3 sentences, most important first.
            - Focus on the flagged findings: explain in plain language WHY the setting and the \
            data don't fit together and what a cautious next step could be (small changes, one \
            at a time). You may also point out anything notable in the raw preferences that \
            the audit facts don't cover.
            - Never give concrete bolus doses. Settings changes are the user's own decision \
            and worth discussing with their care team — say this once at most, briefly.
            - Glucose values in the data are mg/dL; present them in \(result
                .isMmol ? "mmol/L (divide by 18, one decimal)" : "mg/dL").
            - No greeting, no closing line, only the bullet points.
            """
        )
        lines.append("=== AUDIT FACTS ===")
        lines.append(result.facts.joined(separator: "\n"))
        if let raw = storage.retrieveRaw(OpenAPS.Settings.preferences) {
            lines.append("=== RAW PREFERENCES.JSON ===")
            lines.append(compactJSON(raw))
        }
        if let raw = storage.retrieveRaw(OpenAPS.Settings.settings) {
            lines.append("=== PUMP SETTINGS ===")
            lines.append(compactJSON(raw))
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Narrative-Cache (pro Tag und Periode, wie Recap)

    private static func cacheKey(days: Int) -> String { "iAPS.aiHubAuditText.\(days)" }
    private static func cacheDateKey(days: Int) -> String { "iAPS.aiHubAuditDate.\(days)" }

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

    /// Liest basal_profile.json (wie AIHubTherapyAnalysis).
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

    /// "2.5" statt "2.500000" — Zahlen für Settings-Werte kompakt formatieren.
    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    private static func compactJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: compact, encoding: .utf8)
        else { return raw.replacingOccurrences(of: "\n", with: " ") }
        return string
    }
}
