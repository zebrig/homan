import Foundation
import CoreText
import ImageIO
import Testing
@testable import MuesliNativeApp

@Suite("Homan brand identity")
struct HomanBrandIdentityTests {
    @Test("AppIdentity falls back to Homan when bundle keys are absent")
    func appIdentityFallbackIsHoman() {
        // Defaults are only reachable when the bundle keys are missing; the
        // value is the product name rather than the internal Muesli name.
        #expect(AppIdentity.defaultName == "Homan")
    }

    @Test("AppIdentity exposes Homan-owned public destinations")
    func appIdentityExposesHomanURLs() {
        #expect(AppIdentity.repositoryURL.absoluteString == "https://github.com/zebrig/homan")
        #expect(AppIdentity.issuesURL.absoluteString == "https://github.com/zebrig/homan/issues")
        #expect(AppIdentity.releasesURL.absoluteString == "https://github.com/zebrig/homan/releases")
        #expect(AppIdentity.downloadURL.absoluteString == "https://zebrig.github.io/homan/download/")
        #expect(AppIdentity.privacyURL.absoluteString == "https://zebrig.github.io/homan/privacy.html")
        #expect(AppIdentity.termsURL.absoluteString == "https://zebrig.github.io/homan/terms.html")
    }

    @Test("IBM Plex fonts register and resolve from bundled assets")
    func ibmPlexFontsResolve() throws {
        // Test file: native/MuesliNative/Tests/MuesliTests/ -> repo root is 5 up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fontsDir = repoRoot.appendingPathComponent("assets/fonts")
        let fontFiles = try FileManager.default.contentsOfDirectory(
            at: fontsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "ttf" }
        #expect(fontFiles.contains { $0.lastPathComponent.contains("IBMPlexSans") })
        #expect(fontFiles.contains { $0.lastPathComponent.contains("IBMPlexMono") })
        for url in fontFiles {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        #expect(AppFonts.regular(13).fontName.contains("Plex"))
        #expect(AppFonts.semibold(13).fontName.contains("Plex"))
        #expect(AppFonts.monoRegular(13).fontName.contains("Plex"))
    }

    @Test("HomanMark rounded geometry matches the brand contract")
    func homanMarkRoundedGeometry() {
        let bars = HomanMark.roundedBars
        #expect(bars.count == 5)
        #expect(bars[0].x == 4 && bars[0].y == 8 && bars[0].width == 4 && bars[0].height == 24 && bars[0].radius == 2)
        #expect(bars[1].x == 10 && bars[1].y == 4 && bars[1].width == 4 && bars[1].height == 32 && bars[1].radius == 2)
        #expect(bars[2].x == 16 && bars[2].y == 17 && bars[2].width == 8 && bars[2].height == 6 && bars[2].radius == 2)
        #expect(bars[3].x == 26 && bars[3].y == 4 && bars[3].width == 4 && bars[3].height == 32 && bars[3].radius == 2)
        #expect(bars[4].x == 32 && bars[4].y == 8 && bars[4].width == 4 && bars[4].height == 24 && bars[4].radius == 2)
        // Painted bounds on the 40-unit canvas: x 4...36, y 4...36.
        let path = HomanMark.path(size: 40)
        #expect(path.boundingBoxOfPath.minX == 4)
        #expect(path.boundingBoxOfPath.maxX == 36)
        #expect(path.boundingBoxOfPath.minY == 4)
        #expect(path.boundingBoxOfPath.maxY == 36)
    }

    @Test("HomanMark square-cap variant uses zero corner radius")
    func homanMarkSquareCapVariant() {
        #expect(HomanMark.squareCapBars.count == 5)
        #expect(HomanMark.squareCapBars.allSatisfy { $0.radius == 0 })
        // Same painted bounds as the rounded mark.
        let path = HomanMark.path(size: 40, squareCaps: true)
        #expect(path.boundingBoxOfPath.minX == 4)
        #expect(path.boundingBoxOfPath.maxX == 36)
    }

    @Test("Dock icon remains owned by bundle metadata")
    func dockIconRemainsOwnedByBundleMetadata() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegateURL = repoRoot
            .appendingPathComponent("native/MuesliNative/Sources/MuesliNativeApp/AppDelegate.swift")
        let buildScriptURL = repoRoot.appendingPathComponent("scripts/build_native_app.sh")
        let appDelegate = try String(contentsOf: appDelegateURL, encoding: .utf8)
        let buildScript = try String(contentsOf: buildScriptURL, encoding: .utf8)

        #expect(!appDelegate.contains("applicationIconImage ="))
        #expect(buildScript.contains("<key>CFBundleIconFile</key>"))
        #expect(buildScript.contains("<string>muesli.icns</string>"))
    }

    @Test("Insights share background is a complete build input")
    func insightsShareBackgroundIsCompleteBuildInput() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetURL = repoRoot.appendingPathComponent("assets/insights-share-background.png")
        let source = try #require(CGImageSourceCreateWithURL(assetURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 1_200)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 630)

        let buildScriptURL = repoRoot.appendingPathComponent("scripts/build_native_app.sh")
        let buildScript = try String(contentsOf: buildScriptURL, encoding: .utf8)
        #expect(
            buildScript.contains(
                #"cp "$ROOT/assets/insights-share-background.png" "$STAGED_APP_DIR/Contents/Resources/insights-share-background.png""#
            )
        )
        #expect(InsightsBrandAssets.shareWordmark == "homan")
        #expect(InsightsBrandAssets.appIconRepositoryPath == "assets/homan_app_icon.png")
        #expect(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(InsightsBrandAssets.appIconRepositoryPath).path
            )
        )
    }
}
