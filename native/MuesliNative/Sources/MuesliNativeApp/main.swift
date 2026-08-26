import AppKit
import Darwin
import MuesliCore

@main
@MainActor
enum MuesliMain {
    static func main() async {
        if CommandLine.arguments.contains("--packaged-resource-smoke-test") {
            exit(runPackagedResourceSmokeTest())
        }
        if CommandLine.arguments.contains("--aec-benchmark") {
            exit(await MeetingAecBenchmarkRunner.run(arguments: CommandLine.arguments))
        }

        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }

    /// Exercises the resource lookup path from the packaged GUI executable
    /// without starting AppKit services or touching the user's application data.
    private static func runPackagedResourceSmokeTest() -> Int32 {
        let expectedBundleNames = [
            "MuesliNative_MuesliNativeApp.bundle",
            "DTLNAecCoreML_DTLNAec512.bundle",
            "TelemetryDeck_TelemetryDeck.bundle",
        ]

        for bundleName in expectedBundleNames {
            guard let resourcesURL = Bundle.main.resourceURL else {
                fputs("Packaged app has no Contents/Resources URL.\n", stderr)
                return EXIT_FAILURE
            }
            let bundleURL = resourcesURL.appendingPathComponent(
                bundleName,
                isDirectory: true
            )
            guard Bundle(url: bundleURL) != nil else {
                fputs("Packaged resource bundle is unavailable: \(bundleURL.path)\n", stderr)
                return EXIT_FAILURE
            }
        }

        let catalog = MeetingDiarizationModelCatalog.loadBundled()
        guard !catalog.descriptors.isEmpty else {
            fputs("Packaged diarization model catalog is empty or unavailable.\n", stderr)
            return EXIT_FAILURE
        }

        do {
            _ = try MeetingAecModelBundle.resolve()
        } catch {
            fputs("Packaged AEC model bundle is unavailable: \(error)\n", stderr)
            return EXIT_FAILURE
        }

        print("Packaged resource smoke test passed.")
        return EXIT_SUCCESS
    }
}
