import Foundation

/// Collects and restores the UserDefaults-backed configuration that lives
/// outside FileStorage and would otherwise be lost on reinstall: AutoPresets
/// (activity → override-preset mapping), AI-Hub settings, site-rotation
/// selections and the food-search/AI provider preferences.
///
/// Only keys from the canonical list below are touched — restore never
/// writes arbitrary keys from a bundle, so a foreign/tampered backup can't
/// plant unexpected UserDefaults. API keys are secrets and ride the same
/// opt-in as the Nightscout credentials.
enum UserDefaultsBackup {
    /// How a key's value is represented in UserDefaults. Explicit per key so
    /// the JSON roundtrip is unambiguous (a Data blob and a dictionary would
    /// otherwise be indistinguishable after decoding).
    enum Kind {
        case bool
        case string
        case stringArray
        /// Data containing JSON (e.g. a JSONEncoder-encoded config blob).
        /// Stored in the bundle as the decoded JSON structure, re-encoded
        /// to Data on restore.
        case jsonData
    }

    struct Key {
        let name: String
        let kind: Kind
    }

    /// Regular configuration — always included in a backup.
    static let canonicalKeys: [Key] = [
        // AutoPresets: master switch, activity → preset mapping, sustain times.
        // Preset IDs survive the presets-restore (PresetsBackup keeps them),
        // so the mapping stays valid. The migration flag comes along so the
        // one-time sustain migration doesn't rewrite restored values.
        Key(name: "iAPS.aiHubAutoPresets", kind: .jsonData),
        Key(name: "iAPS.aiHubAutoPresetsSustainMigratedV2", kind: .bool),
        // Hardware-Check: user-selected rotation sites (patch + sensor,
        // plus the legacy single-circle key from the first release).
        Key(name: "iAPS.aiHubSites.patch", kind: .stringArray),
        Key(name: "iAPS.aiHubSites.sensor", kind: .stringArray),
        Key(name: "iAPS.aiHubSites", kind: .stringArray),
        // AI-Hub settings.
        Key(name: "iAPS.aiHubChatProvider", kind: .string),
        Key(name: "iAPS.aiHubCarbsComplete", kind: .bool),
        Key(name: "iAPS.aiHubAllowApply", kind: .bool),
        Key(name: "iAPS.aiHubWeeklyCheckEnabled", kind: .bool),
        // Food-search / AI provider preferences (UserDefaults+AI.swift).
        Key(name: "com.loopkit.Loop.textSearchProvider", kind: .string),
        Key(name: "com.loopkit.Loop.barcodeSearchProvider", kind: .string),
        Key(name: "com.loopkit.Loop.aiImageProvider", kind: .string),
        Key(name: "com.loopkit.Loop.aiTextProvider", kind: .string),
        Key(name: "com.loopkit.Loop.AIPreferredLanguage", kind: .string),
        Key(name: "com.loopkit.Loop.AIPreferredRegion", kind: .string),
        Key(name: "com.loopkit.Loop.AINutritionAuthority", kind: .string),
        Key(name: "com.loopkit.Loop.AISendSmallerImages", kind: .bool),
        Key(name: "com.loopkit.Loop.AITextSearchByDefault", kind: .bool),
        Key(name: "com.loopkit.Loop.AIAddImageCommentByDefault", kind: .bool),
        Key(name: "com.loopkit.Loop.AISavePhotosToLibrary", kind: .bool),
        Key(name: "com.loopkit.Loop.AIProgressAnimation", kind: .bool)
    ]

    /// Secrets — only included when the user opted in (same toggle as the
    /// Nightscout credentials). The backup file lives outside the sandbox.
    static let secretKeys: [Key] = [
        Key(name: "com.loopkit.Loop.claudeAPIKey", kind: .string),
        Key(name: "com.loopkit.Loop.openAIAPIKey", kind: .string),
        Key(name: "com.loopkit.Loop.googleGeminiAPIKey", kind: .string),
        Key(name: "com.loopkit.Loop.usdaAPIKey", kind: .string)
    ]

    // MARK: - Collect

    /// Snapshot every canonical key that is actually set. Absent keys stay
    /// absent so their in-code defaults keep applying after a restore.
    static func collect(includeSecrets: Bool) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        let keys = includeSecrets ? canonicalKeys + secretKeys : canonicalKeys
        let defaults = UserDefaults.standard
        for key in keys {
            guard let value = read(key, from: defaults) else { continue }
            result[key.name] = value
        }
        return result
    }

    private static func read(_ key: Key, from defaults: UserDefaults) -> JSONValue? {
        guard defaults.object(forKey: key.name) != nil else { return nil }
        switch key.kind {
        case .bool:
            return .bool(defaults.bool(forKey: key.name))
        case .string:
            guard let value = defaults.string(forKey: key.name), !value.isEmpty else { return nil }
            return .string(value)
        case .stringArray:
            guard let value = defaults.stringArray(forKey: key.name) else { return nil }
            return .array(value.map { .string($0) })
        case .jsonData:
            guard let data = defaults.data(forKey: key.name),
                  let value = try? JSONCoding.decoder.decode(JSONValue.self, from: data)
            else { return nil }
            return value
        }
    }

    // MARK: - Restore

    /// Write the bundled values back. Only canonical keys are considered;
    /// anything else in the dictionary is ignored. Returns the number of
    /// keys restored.
    @discardableResult  static func restore(_ values: [String: JSONValue], includeSecrets: Bool) -> Int {
        var restored = 0
        let keys = includeSecrets ? canonicalKeys + secretKeys : canonicalKeys
        let defaults = UserDefaults.standard
        for key in keys {
            guard let value = values[key.name] else { continue }
            if write(value, for: key, to: defaults) {
                restored += 1
            } else {
                NSLog("[Backup] userDefaults SKIP \(key.name) — type mismatch")
            }
        }
        return restored
    }

    private static func write(_ value: JSONValue, for key: Key, to defaults: UserDefaults) -> Bool {
        switch key.kind {
        case .bool:
            guard case let .bool(flag) = value else { return false }
            defaults.set(flag, forKey: key.name)
        case .string:
            guard case let .string(string) = value else { return false }
            defaults.set(string, forKey: key.name)
        case .stringArray:
            guard case let .array(items) = value else { return false }
            let strings: [String] = items.compactMap {
                guard case let .string(string) = $0 else { return nil }
                return string
            }
            guard strings.count == items.count else { return false }
            defaults.set(strings, forKey: key.name)
        case .jsonData:
            guard let data = try? JSONCoding.encoder.encode(value) else { return false }
            defaults.set(data, forKey: key.name)
        }
        return true
    }
}
