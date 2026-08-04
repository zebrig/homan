import Foundation

enum MeetingAudioTestFixtures {
    static let sampleRate = 16_000

    struct SourcePair {
        let microphone: [Int16]
        let system: [Int16]
    }

    static func microphoneOnly(sampleCount: Int = 1_600) -> SourcePair {
        SourcePair(
            microphone: tone(sampleCount: sampleCount, amplitude: 4_000, period: 80),
            system: Array(repeating: 0, count: sampleCount)
        )
    }

    static func systemOnly(sampleCount: Int = 1_600) -> SourcePair {
        SourcePair(
            microphone: Array(repeating: 0, count: sampleCount),
            system: tone(sampleCount: sampleCount, amplitude: 5_000, period: 64)
        )
    }

    static func overlapping(sampleCount: Int = 1_600) -> SourcePair {
        SourcePair(
            microphone: tone(sampleCount: sampleCount, amplitude: 4_000, period: 80),
            system: tone(sampleCount: sampleCount, amplitude: 5_000, period: 64)
        )
    }

    static func unequalLengths() -> SourcePair {
        SourcePair(
            microphone: tone(sampleCount: 1_600, amplitude: 4_000, period: 80),
            system: tone(sampleCount: 800, amplitude: 5_000, period: 64)
        )
    }

    static func silence(sampleCount: Int = 1_600) -> [Int16] {
        Array(repeating: 0, count: sampleCount)
    }

    static func tone(
        sampleCount: Int,
        amplitude: Int16,
        period: Int
    ) -> [Int16] {
        precondition(sampleCount >= 0)
        precondition(period > 1)
        let halfPeriod = max(period / 2, 1)
        return (0..<sampleCount).map { index in
            (index / halfPeriod).isMultiple(of: 2) ? amplitude : -amplitude
        }
    }

    @discardableResult
    static func writeMonoPCM16WAV(
        samples: [Int16],
        to url: URL,
        sampleRate: Int = sampleRate
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32LE(UInt32(36 + samples.count * MemoryLayout<Int16>.size))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(sampleRate * MemoryLayout<Int16>.size))
        data.appendUInt16LE(UInt16(MemoryLayout<Int16>.size))
        data.appendUInt16LE(16)
        data.appendASCII("data")
        data.appendUInt32LE(UInt32(samples.count * MemoryLayout<Int16>.size))
        for sample in samples {
            data.appendUInt16LE(UInt16(bitPattern: sample))
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    static func writeCorruptWAV(to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-a-wave-file".utf8).write(to: url, options: .atomic)
        return url
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
