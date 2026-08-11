import Foundation

/// Flexible JSON value used to represent the `settings` object in the export envelope
/// so import can merge per-field instead of replacing the whole config.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

/// Encode/decode + merge for the `homan-settings` settings import/export envelope.
enum SettingsFileIO {
    static let formatName = "homan-settings"
    static let formatVersion = 1

    /// API-key JSON keys (snake_case) that can be redacted from an export.
    static let secretJSONKeys: Set<String> = [
        "homan_whisper_api_key",
        "openai_api_key",
        "openrouter_api_key",
        "ollama_api_key",
        "custom_llm_api_key",
    ]

    enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case unsupportedVersion(Int)
        case invalidFile(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let f): return "Unsupported settings file format: \(f)"
            case .unsupportedVersion(let v): return "Settings file version \(v) is newer than this app supports."
            case .invalidFile(let reason): return "Invalid settings file: \(reason)"
            }
        }
    }

    struct Envelope: Codable, Equatable {
        var format: String = SettingsFileIO.formatName
        var version: Int = SettingsFileIO.formatVersion
        var appVersion: String
        var exportedAt: Date
        var settings: [String: JSONValue]
    }

    struct ImportPreview: Equatable {
        let changedKeyCount: Int
        let includesSecrets: Bool
        let appVersion: String
        let exportedAt: Date
    }

    // MARK: - Export

    /// Encode the current config into the export file format. When `includeSecrets` is false,
    /// API-key fields are dropped (safe for sharing).
    static func exportData(config: AppConfig, includeSecrets: Bool) throws -> Data {
        let settings = try jsonDictionary(from: config)
        var filtered = settings
        if !includeSecrets {
            for key in secretJSONKeys { filtered.removeValue(forKey: key) }
        }
        let envelope = Envelope(
            appVersion: appVersionString(),
            exportedAt: Date(),
            settings: filtered
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    // MARK: - Import

    static func decodeEnvelope(_ data: Data) throws -> Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw ImportError.invalidFile(error.localizedDescription)
        }
        guard envelope.format == formatName else {
            throw ImportError.unsupportedFormat(envelope.format)
        }
        guard envelope.version <= formatVersion else {
            throw ImportError.unsupportedVersion(envelope.version)
        }
        return envelope
    }

    static func previewImport(current: AppConfig, envelope: Envelope) -> ImportPreview {
        let currentSettings = (try? jsonDictionary(from: current)) ?? [:]
        var changed = 0
        for (key, value) in envelope.settings {
            // Empty-string API keys keep the existing value — not a change.
            if secretJSONKeys.contains(key), isEmptyOrNull(value) { continue }
            if currentSettings[key] != value { changed += 1 }
        }
        let includesSecrets = secretJSONKeys.contains { key in
            if let value = envelope.settings[key], !isEmptyOrNull(value) { return true }
            return false
        }
        return ImportPreview(
            changedKeyCount: changed,
            includesSecrets: includesSecrets,
            appVersion: envelope.appVersion,
            exportedAt: envelope.exportedAt
        )
    }

    /// Merge the imported settings into the current config per-field: keys present in the file win,
    /// absent keys keep current values; empty-string API keys keep the existing value.
    static func mergedConfig(_ current: AppConfig, envelope: Envelope) -> AppConfig {
        var settings = (try? jsonDictionary(from: current)) ?? [:]
        for (key, value) in envelope.settings {
            if secretJSONKeys.contains(key), isEmptyOrNull(value) { continue }
            settings[key] = value
        }
        return (try? appConfig(from: settings)) ?? current
    }

    // MARK: - Helpers

    private static func jsonDictionary(from config: AppConfig) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(config)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private static func appConfig(from dictionary: [String: JSONValue]) throws -> AppConfig {
        let data = try JSONEncoder().encode(dictionary)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    private static func isEmptyOrNull(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let s): return s.isEmpty
        case .null: return true
        default: return false
        }
    }

    private static func appVersionString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
