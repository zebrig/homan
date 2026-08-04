import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Diarizer runtime policy")
struct DiarizerRuntimePolicyTests {
    @Test("M1 family on macOS 15.1 avoids the Core ML GPU path")
    func m1OnMacOS151AvoidsGPU() {
        for brand in ["Apple M1", "Apple M1 Pro", "Apple M1 Max", "Apple M1 Ultra"] {
            let policy = DiarizerRuntimePolicy.resolve(for: environment(
                cpuBrand: brand,
                hardwareModel: nil,
                major: 15,
                minor: 1
            ))
            #expect(policy.computePolicy == .cpuAndNeuralEngine)
            #expect(policy.compatibilityRule == DiarizerRuntimePolicy.m1MacOS151CompatibilityRule)
        }
    }

    @Test("known M1 hardware is used when the CPU brand is unavailable")
    func m1HardwareFallbackAvoidsGPU() {
        let policy = DiarizerRuntimePolicy.resolve(for: environment(
            cpuBrand: nil,
            hardwareModel: "MacBookAir10,1",
            major: 15,
            minor: 1
        ))

        #expect(policy.computePolicy == .cpuAndNeuralEngine)
    }

    @Test("other chips and operating systems retain all compute units")
    func unaffectedSystemsUseAllComputeUnits() {
        let m2Policy = DiarizerRuntimePolicy.resolve(for: environment(
            cpuBrand: "Apple M2 Max",
            hardwareModel: nil,
            major: 15,
            minor: 1
        ))
        let newerOSPolicy = DiarizerRuntimePolicy.resolve(for: environment(
            cpuBrand: "Apple M1 Max",
            hardwareModel: nil,
            major: 15,
            minor: 2
        ))

        #expect(m2Policy.computePolicy == .all)
        #expect(newerOSPolicy.computePolicy == .all)
    }

    private func environment(
        cpuBrand: String?,
        hardwareModel: String?,
        major: Int,
        minor: Int
    ) -> DiarizerRuntimeEnvironment {
        DiarizerRuntimeEnvironment(
            cpuBrand: cpuBrand,
            hardwareModel: hardwareModel,
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: major,
                minorVersion: minor,
                patchVersion: 0
            )
        )
    }
}
