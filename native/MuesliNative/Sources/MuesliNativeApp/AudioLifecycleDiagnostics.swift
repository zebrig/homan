import CoreAudio
import Foundation
import os

enum AudioLifecycleLogLevel {
    case debug
    case info
    case notice
    case error
}

enum AudioLifecycleDiagnostics {
    private static let logger = Logger(
        subsystem: "com.muesli.native",
        category: "AudioLifecycle"
    )

    static func monotonicNowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since startedAt: UInt64) -> Double {
        let now = monotonicNowNanoseconds()
        guard now >= startedAt else { return 0 }
        return Double(now - startedAt) / 1_000_000
    }

    static func emit(
        _ level: AudioLifecycleLogLevel,
        operation: String,
        operationID: UUID? = nil,
        generation: UInt64? = nil,
        routeRole: String = "none",
        deviceID: AudioObjectID? = nil,
        durationMilliseconds: Double? = nil,
        status: String,
        osStatus: OSStatus? = nil
    ) {
        let operationIDValue = operationID?.uuidString.lowercased() ?? "none"
        let generationValue = generation.map(String.init) ?? "none"
        let deviceIDValue = deviceID.map(String.init) ?? "none"
        let durationValue = durationMilliseconds.map { String(format: "%.3f", $0) } ?? "none"
        let osStatusValue = osStatus.map(String.init) ?? "none"

        switch level {
        case .debug:
            logger.debug(
                "operation=\(operation, privacy: .public) operation_id=\(operationIDValue, privacy: .public) generation=\(generationValue, privacy: .public) route_role=\(routeRole, privacy: .public) device_object_id=\(deviceIDValue, privacy: .public) duration_ms=\(durationValue, privacy: .public) status=\(status, privacy: .public) os_status=\(osStatusValue, privacy: .public)"
            )
        case .info:
            logger.info(
                "operation=\(operation, privacy: .public) operation_id=\(operationIDValue, privacy: .public) generation=\(generationValue, privacy: .public) route_role=\(routeRole, privacy: .public) device_object_id=\(deviceIDValue, privacy: .public) duration_ms=\(durationValue, privacy: .public) status=\(status, privacy: .public) os_status=\(osStatusValue, privacy: .public)"
            )
        case .notice:
            logger.notice(
                "operation=\(operation, privacy: .public) operation_id=\(operationIDValue, privacy: .public) generation=\(generationValue, privacy: .public) route_role=\(routeRole, privacy: .public) device_object_id=\(deviceIDValue, privacy: .public) duration_ms=\(durationValue, privacy: .public) status=\(status, privacy: .public) os_status=\(osStatusValue, privacy: .public)"
            )
        case .error:
            logger.error(
                "operation=\(operation, privacy: .public) operation_id=\(operationIDValue, privacy: .public) generation=\(generationValue, privacy: .public) route_role=\(routeRole, privacy: .public) device_object_id=\(deviceIDValue, privacy: .public) duration_ms=\(durationValue, privacy: .public) status=\(status, privacy: .public) os_status=\(osStatusValue, privacy: .public)"
            )
        }
    }
}
