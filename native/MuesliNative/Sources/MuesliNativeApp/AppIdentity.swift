import Foundation
import MuesliCore

/// Single runtime source for the Homan product identity: display name and
/// Homan-owned public URLs.
///
/// Internal Swift module/type names intentionally keep their compatibility
/// names (Muesli*) so upstream merges stay low-conflict; only user-visible
/// identity and destinations are Homan-owned here.
enum AppIdentity {
    /// Product fallback name used when bundle metadata is absent.
    static let defaultName = "Homan"

    static let isRunningTests = MuesliPaths.isRunningTests

    static var bundleName: String {
        stringValue(for: "CFBundleName") ?? defaultName
    }

    static var displayName: String {
        stringValue(for: "CFBundleDisplayName") ?? bundleName
    }

    static var marketingVersion: String {
        stringValue(for: "CFBundleShortVersionString") ?? "0.0.0"
    }

    static var supportDirectoryName: String {
        stringValue(for: "MuesliSupportDirectoryName") ?? displayName
    }

    static var supportDirectoryURL: URL {
        MuesliPaths.defaultSupportDirectoryURL(appName: supportDirectoryName)
    }

    static var databaseURL: URL {
        MuesliPaths.defaultDatabaseURL(appName: supportDirectoryName)
    }

    // MARK: - Homan-owned public destinations

    /// Homan repository root.
    static let repositoryURL = URL(string: "https://github.com/zebrig/homan")!
    /// Homan issue tracker.
    static let issuesURL = URL(string: "https://github.com/zebrig/homan/issues")!
    /// Homan releases.
    static let releasesURL = URL(string: "https://github.com/zebrig/homan/releases")!
    /// Homan download page.
    static let downloadURL = URL(string: "https://zebrig.github.io/homan/download/")!
    /// Homan privacy policy.
    static let privacyURL = URL(string: "https://zebrig.github.io/homan/privacy.html")!
    /// Homan terms of use.
    static let termsURL = URL(string: "https://zebrig.github.io/homan/terms.html")!

    private static func stringValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
