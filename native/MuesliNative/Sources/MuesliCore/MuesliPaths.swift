import Foundation

public enum MuesliPaths {
    /// Package test bundles have no product Info.plist and historically fell
    /// back to the installed app's real support directory. Keep every default
    /// path process-local while XCTest or Swift Testing is running.
    public static let isRunningTests: Bool = {
        let processInfo = ProcessInfo.processInfo
        let environment = processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil {
            return true
        }

        if Bundle.main.bundleURL.pathExtension == "xctest" {
            return true
        }

        if processInfo.processName == "swiftpm-testing-helper" {
            return true
        }

        return processInfo.arguments.first?.contains(".xctest/") == true
    }()

    private static let isolatedTestSupportRoot: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HomanTests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
    }()

    public static func defaultSupportDirectoryURL(appName: String = "Homan") -> URL {
        if isRunningTests {
            return isolatedTestSupportRoot.appendingPathComponent(appName, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static func defaultDatabaseURL(appName: String = "Homan") -> URL {
        defaultSupportDirectoryURL(appName: appName).appendingPathComponent("muesli.db")
    }
}

public enum MuesliNotifications {
    public static let dataDidChange = Notification.Name("com.muesli.dataChanged")

    public static func postDataDidChange() {
        DistributedNotificationCenter.default().post(name: dataDidChange, object: nil)
    }
}
