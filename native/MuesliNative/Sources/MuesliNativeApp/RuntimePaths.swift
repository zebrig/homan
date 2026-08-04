import Foundation
import MuesliCore

struct RuntimePaths {
    let repoRoot: URL
    let menuIcon: URL?
    let appIcon: URL?
    let bundlePath: URL?

    static func resolve() throws -> RuntimePaths {
        if let bundleResource = Bundle.main.resourceURL {
            return RuntimePaths(
                repoRoot: bundleResource,
                menuIcon: bundleResource.appendingPathComponent("menu_m_template.png"),
                appIcon: bundleResource.appendingPathComponent("muesli.icns"),
                bundlePath: Bundle.main.bundleURL
            )
        }

        // Dev fallback: search up for assets
        let fileManager = FileManager.default
        var searchURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = searchURL.appendingPathComponent("assets/muesli.icns")
            if fileManager.fileExists(atPath: candidate.path) {
                return RuntimePaths(
                    repoRoot: searchURL,
                    menuIcon: searchURL.appendingPathComponent("assets/menu_m_template.png"),
                    appIcon: candidate,
                    bundlePath: nil
                )
            }
            searchURL.deleteLastPathComponent()
        }

        throw NSError(domain: "MuesliRuntime", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate app bundle or repo root.",
        ])
    }
}
