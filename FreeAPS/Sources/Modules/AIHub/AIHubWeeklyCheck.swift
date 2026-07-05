import Foundation
import UserNotifications

/// Wöchentlicher Therapie-Check: rechnet die lokale Therapie-Analyse
/// (AIHubTherapyAnalysis) einmal pro Woche automatisch und meldet sich per
/// lokaler Notification, wenn es Vorschläge gibt.
///
/// Bewusst KEIN Auto-Apply: Basal-Übernahmen syncen zur Pumpe — Änderungen
/// passieren nur über den bestehenden 1-Tap-Flow im AI Hub (Bestätigung,
/// Undo-Stack, Cooldown in AIHubTherapyApply). Der Check ist rein lesend.
///
/// Trigger: `checkTrigger()` beim Aktivwerden der App (FreeAPSApp,
/// scenePhase == .active — gleiches Muster wie AutoBackupService), wenn der
/// letzte Lauf ≥ 7 Tage her ist. Läuft off-main; der Lauf-Zeitstempel wird
/// unabhängig vom Ergebnis gesetzt, damit die Kadenz wöchentlich bleibt.
enum AIHubWeeklyCheck {
    private static let lastRunKey = "iAPS.aiHubWeeklyCheckLastRun"
    private static let enabledKey = "iAPS.aiHubWeeklyCheckEnabled"
    private static let notificationId = "iAPS.aiHubWeeklyCheck"
    private static let intervalDays = 7.0
    /// 14 Tage Datenfenster: genug saubere Zell-Paare für die Clean-Drift-
    /// Engine, aber kurz genug, dass eine Profil-Änderung der Vorwoche das
    /// Ergebnis dominiert (iteratives Nachführen statt 90d-Trägheit).
    static let analysisDays = 14

    /// Opt-out: Standard ist an — die Analyse ist lokal und kostenlos, die
    /// Notification kommt nur, wenn es tatsächlich Vorschläge gibt.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var lastRun: Date? {
        UserDefaults.standard.object(forKey: lastRunKey) as? Date
    }

    /// Safe to call repeatedly — tut nichts, solange der letzte Lauf jünger
    /// als eine Woche ist.
    static func checkTrigger() {
        guard isEnabled else { return }
        if let last = lastRun, Date().timeIntervalSince(last) < intervalDays * 24 * 3600 { return }
        DispatchQueue.global(qos: .utility).async { run() }
    }

    /// Sofort-Lauf, am Wochen-Throttle vorbei (Debug/Settings-Button).
    static func runNow() {
        DispatchQueue.global(qos: .utility).async { run() }
    }

    private static func run() {
        let result = AIHubTherapyAnalysis.analyze(days: analysisDays)
        UserDefaults.standard.set(Date(), forKey: lastRunKey)
        guard !result.suggestions.isEmpty else {
            NSLog("[WeeklyCheck] ran, no suggestions (suppressed: \(result.suppressedCount))")
            return
        }
        NSLog("[WeeklyCheck] ran, \(result.suggestions.count) suggestions")
        notify(count: result.suggestions.count)
    }

    private static func notify(count: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = hubT("weekly.notif.title")
            content.body = hubT("weekly.notif.body", count)
            content.sound = .default
            center.add(UNNotificationRequest(identifier: notificationId, content: content, trigger: nil))
        }
    }
}
