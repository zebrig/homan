import CoreML
import Darwin
import Foundation

struct DiarizerRuntimeEnvironment: Sendable {
    let cpuBrand: String?
    let hardwareModel: String?
    let operatingSystemVersion: OperatingSystemVersion

    static func current(processInfo: ProcessInfo = .processInfo) -> DiarizerRuntimeEnvironment {
        DiarizerRuntimeEnvironment(
            cpuBrand: sysctlString("machdep.cpu.brand_string"),
            hardwareModel: sysctlString("hw.model"),
            operatingSystemVersion: processInfo.operatingSystemVersion
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(validatingCString: value)
    }
}

enum DiarizerComputePolicy: String, Sendable, Equatable {
    case all
    case cpuAndNeuralEngine = "cpu_and_neural_engine"

    var computeUnits: MLComputeUnits {
        switch self {
        case .all:
            return .all
        case .cpuAndNeuralEngine:
            return .cpuAndNeuralEngine
        }
    }
}

struct DiarizerRuntimePolicy: Sendable, Equatable {
    static let defaultCompatibilityRule = "default_v1"
    static let m1MacOS151CompatibilityRule = "m1_macos_15_1_gpu_avoidance_v1"

    private static let m1HardwareModels: Set<String> = [
        "MacBookAir10,1",
        "MacBookPro17,1",
        "MacBookPro18,1",
        "MacBookPro18,2",
        "MacBookPro18,3",
        "MacBookPro18,4",
        "Macmini9,1",
        "iMac21,1",
        "iMac21,2",
        "Mac13,1",
        "Mac13,2",
    ]

    let computePolicy: DiarizerComputePolicy
    let compatibilityRule: String

    static func resolve(for environment: DiarizerRuntimeEnvironment) -> DiarizerRuntimePolicy {
        let version = environment.operatingSystemVersion
        let isMacOS151 = version.majorVersion == 15 && version.minorVersion == 1
        let isM1Family = environment.cpuBrand.map(isM1CPUBrand)
            ?? environment.hardwareModel.map(m1HardwareModels.contains)
            ?? false

        if isMacOS151, isM1Family {
            return DiarizerRuntimePolicy(
                computePolicy: .cpuAndNeuralEngine,
                compatibilityRule: m1MacOS151CompatibilityRule
            )
        }

        return DiarizerRuntimePolicy(
            computePolicy: .all,
            compatibilityRule: defaultCompatibilityRule
        )
    }

    var modelConfiguration: MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computePolicy.computeUnits
        return configuration
    }

    private static func isM1CPUBrand(_ value: String) -> Bool {
        let brand = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return brand == "Apple M1" || brand.hasPrefix("Apple M1 ")
    }
}
