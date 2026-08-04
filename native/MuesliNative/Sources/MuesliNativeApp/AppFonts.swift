import AppKit
import CoreText
import Foundation
import MuesliCore

enum AppFonts {
    private static var didRegister = false

    static func registerIfNeeded(runtime: RuntimePaths) {
        guard !didRegister else { return }
        register(fontURLs: bundledFontURLs(runtime: runtime))
    }

    static func registerForRenderingIfNeeded() {
        guard !didRegister else { return }
        let fileManager = FileManager.default
        let workingFonts = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("assets/fonts", isDirectory: true)
        let locations = [
            Bundle.main.resourceURL?.appendingPathComponent("fonts", isDirectory: true),
            workingFonts,
        ].compactMap { $0 }
        let urls = locations.flatMap { directory -> [URL] in
            guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return []
            }
            return entries.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        }
        register(fontURLs: urls)
    }

    private static func register(fontURLs: [URL]) {
        for url in fontURLs {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        didRegister = !fontURLs.isEmpty
    }

    static func regular(_ size: CGFloat) -> NSFont {
        font(size: size, candidates: ["IBMPlexSans", "IBM Plex Sans"])
            ?? NSFont.systemFont(ofSize: size, weight: .regular)
    }

    static func medium(_ size: CGFloat) -> NSFont {
        font(size: size, candidates: ["IBMPlexSans-Medm", "IBMPlexSans-Medium", "IBM Plex Sans Medium"])
            ?? NSFont.systemFont(ofSize: size, weight: .medium)
    }

    static func semibold(_ size: CGFloat) -> NSFont {
        font(size: size, candidates: ["IBMPlexSans-SmBld", "IBMPlexSans-SemiBold", "IBM Plex Sans SemiBold"])
            ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func bold(_ size: CGFloat) -> NSFont {
        font(size: size, candidates: ["IBMPlexSans-Bold", "IBM Plex Sans Bold"])
            ?? NSFont.systemFont(ofSize: size, weight: .bold)
    }

    static func monoRegular(_ size: CGFloat) -> NSFont {
        font(size: size, candidates: ["IBMPlexMono", "IBM Plex Mono"])
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func monoMedium(_ size: CGFloat) -> NSFont {
        font(size: size, candidates: ["IBMPlexMono-Medm", "IBMPlexMono-Medium", "IBM Plex Mono Medium"])
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }

    private static func font(size: CGFloat, candidates: [String]) -> NSFont? {
        for candidate in candidates {
            if let font = NSFont(name: candidate, size: size) {
                return font
            }
        }
        return nil
    }

    private static func bundledFontURLs(runtime: RuntimePaths) -> [URL] {
        let fileManager = FileManager.default
        let locations = [
            Bundle.main.resourceURL?.appendingPathComponent("fonts", isDirectory: true),
            runtime.repoRoot.appendingPathComponent("assets/fonts", isDirectory: true),
        ].compactMap { $0 }

        return locations.flatMap { directory in
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else {
                return [URL]()
            }
            return entries.filter { $0.pathExtension.lowercased() == "ttf" || $0.pathExtension.lowercased() == "otf" }
        }
    }
}
