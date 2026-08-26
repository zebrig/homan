import CryptoKit
import Foundation
import SQLite3

private struct MeetingAecBenchmarkReport: Codable {
    let generatedAt: Date
    let model: String
    let supportDirectory: String
    let calls: [Call]

    struct Call: Codable {
        let meetingID: Int64
        let sessionID: UUID
        let bundlePath: String
        let sourceDurationSeconds: Double
        let runs: [Run]
        let outputComparison: OutputComparison
    }

    struct Run: Codable {
        let threads: Int
        let pureAECSeconds: Double
        let processedAudioSeconds: Double
        let realtimeFactor: Double
        let processingSpeed: Double
        let endToEndWallSeconds: Double
        let outputSHA256: String
    }

    struct OutputComparison: Codable {
        let baselineThreads: Int
        let candidateThreads: Int
        let sampleCount: Int
        let identical: Bool
        let rmsDifference: Double
        let maximumAbsoluteDifference: Double
        let signalToDifferenceDB: Double?
    }
}

enum MeetingAecBenchmarkRunner {
    private struct Options {
        let supportDirectory: URL
        let bundleURLs: [URL]
        let threads: [Int]
        let outputURL: URL?
    }

    private struct CompletedRun {
        let report: MeetingAecBenchmarkReport.Run
        let outputURL: URL
    }

    static func run(arguments: [String]) async -> Int32 {
        do {
            let options = try parse(arguments: arguments)
            let monitor = RecordingMonitor(
                databaseURL: options.supportDirectory.appendingPathComponent("muesli.db"),
                scheduler: .shared
            )
            let monitorTask = monitor.start()
            defer {
                monitorTask.cancel()
                monitor.stop()
            }

            var calls: [MeetingAecBenchmarkReport.Call] = []
            for (index, bundleURL) in options.bundleURLs.enumerated() {
                let bundle = try MeetingRecordingBundle.load(
                    directoryURL: bundleURL,
                    supportDirectory: options.supportDirectory
                )
                guard let rawAudio = bundle.rawAudio else {
                    throw BenchmarkError.bundleHasNoCanonicalRawAudio(bundleURL.path)
                }

                // Alternate the order across calls to reduce a systematic
                // first-run/thermal bias while still comparing identical data.
                let runOrder = index.isMultiple(of: 2)
                    ? options.threads
                    : options.threads.reversed()
                var completedRuns: [CompletedRun] = []
                defer {
                    completedRuns.forEach {
                        try? FileManager.default.removeItem(at: $0.outputURL)
                    }
                }

                for threadCount in runOrder {
                    fputs(
                        "[aec-benchmark] meeting=\(bundle.manifest.meetingID) "
                            + "threads=\(threadCount) starting\n",
                        stderr
                    )
                    let aec = MeetingNeuralAec(
                        selection: .localVQEStrict,
                        localVQEModel: .localVQEV12,
                        localVQEThreads: threadCount
                    )
                    let wallStartedAt = ProcessInfo.processInfo.systemUptime
                    let prepared = try await MeetingRawAudioPostProcessor.renderProcessingView(
                        rawAudio,
                        aec: aec,
                        inferenceScheduler: .shared
                    )
                    guard let microphoneURL = prepared.microphoneURL else {
                        prepared.removeTemporaryFiles()
                        throw BenchmarkError.missingMicrophoneOutput(bundleURL.path)
                    }
                    if let systemURL = prepared.systemURL {
                        try? FileManager.default.removeItem(at: systemURL)
                    }
                    let wallSeconds = ProcessInfo.processInfo.systemUptime - wallStartedAt
                    let performance = prepared.aecPerformance
                    guard performance.processor == MeetingAecModel.localVQEV12.processorName,
                          performance.inferenceThreads == threadCount,
                          performance.processedAudioSamples > 0 else {
                        try? FileManager.default.removeItem(at: microphoneURL)
                        throw BenchmarkError.unexpectedProcessor(
                            expectedThreads: threadCount,
                            actualProcessor: performance.processor,
                            actualThreads: performance.inferenceThreads
                        )
                    }
                    let report = MeetingAecBenchmarkReport.Run(
                        threads: threadCount,
                        pureAECSeconds: performance.pureInferenceSeconds,
                        processedAudioSeconds: performance.processedAudioSeconds,
                        realtimeFactor: performance.realtimeFactor,
                        processingSpeed: performance.processingSpeed,
                        endToEndWallSeconds: wallSeconds,
                        outputSHA256: try sha256Hex(of: microphoneURL)
                    )
                    completedRuns.append(CompletedRun(report: report, outputURL: microphoneURL))
                    fputs(
                        "[aec-benchmark] meeting=\(bundle.manifest.meetingID) "
                            + "threads=\(threadCount) pureAEC="
                            + "\(String(format: "%.3f", report.pureAECSeconds))s "
                            + "speed=\(String(format: "%.3f", report.processingSpeed))x\n",
                        stderr
                    )
                }

                let sortedRuns = completedRuns.sorted { $0.report.threads < $1.report.threads }
                guard sortedRuns.count == 2 else {
                    throw BenchmarkError.requiresExactlyTwoThreadCounts
                }
                let comparison = try comparePCM16WAV(
                    baseline: sortedRuns[0],
                    candidate: sortedRuns[1]
                )
                let duration = Double(rawAudio.manifest.timelineDurationNanoseconds)
                    / 1_000_000_000
                calls.append(MeetingAecBenchmarkReport.Call(
                    meetingID: bundle.manifest.meetingID,
                    sessionID: bundle.manifest.sessionID,
                    bundlePath: bundleURL.path,
                    sourceDurationSeconds: duration,
                    runs: sortedRuns.map(\.report),
                    outputComparison: comparison
                ))
            }

            let report = MeetingAecBenchmarkReport(
                generatedAt: Date(),
                model: MeetingAecModel.localVQEV12.rawValue,
                supportDirectory: options.supportDirectory.path,
                calls: calls
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var reportData = try encoder.encode(report)
            reportData.append(contentsOf: Data("\n".utf8))
            if let outputURL = options.outputURL {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try reportData.write(to: outputURL, options: .atomic)
                fputs("[aec-benchmark] report=\(outputURL.path)\n", stderr)
            } else {
                FileHandle.standardOutput.write(reportData)
            }
            return EXIT_SUCCESS
        } catch {
            fputs("AEC benchmark failed: \(error.localizedDescription)\n", stderr)
            return EXIT_FAILURE
        }
    }

    private static func parse(arguments: [String]) throws -> Options {
        guard let marker = arguments.firstIndex(of: "--aec-benchmark") else {
            throw BenchmarkError.invalidArguments
        }
        var supportDirectory: URL?
        var bundleURLs: [URL] = []
        var threads = [2, 4]
        var outputURL: URL?
        var index = marker + 1
        while index < arguments.count {
            switch arguments[index] {
            case "--support-directory":
                index += 1
                guard index < arguments.count else { throw BenchmarkError.invalidArguments }
                supportDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--bundle":
                index += 1
                guard index < arguments.count else { throw BenchmarkError.invalidArguments }
                bundleURLs.append(URL(fileURLWithPath: arguments[index], isDirectory: true))
            case "--threads":
                index += 1
                guard index < arguments.count else { throw BenchmarkError.invalidArguments }
                threads = try arguments[index].split(separator: ",").map {
                    guard let value = Int($0), value > 0 else {
                        throw BenchmarkError.invalidArguments
                    }
                    return value
                }
            case "--output":
                index += 1
                guard index < arguments.count else { throw BenchmarkError.invalidArguments }
                outputURL = URL(fileURLWithPath: arguments[index])
            default:
                throw BenchmarkError.invalidArguments
            }
            index += 1
        }
        guard let supportDirectory, !bundleURLs.isEmpty,
              threads.count == 2, Set(threads).count == 2 else {
            throw BenchmarkError.invalidArguments
        }
        return Options(
            supportDirectory: supportDirectory.standardizedFileURL,
            bundleURLs: bundleURLs.map(\.standardizedFileURL),
            threads: threads,
            outputURL: outputURL?.standardizedFileURL
        )
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func comparePCM16WAV(
        baseline: CompletedRun,
        candidate: CompletedRun
    ) throws -> MeetingAecBenchmarkReport.OutputComparison {
        let baselineHandle = try FileHandle(forReadingFrom: baseline.outputURL)
        defer { try? baselineHandle.close() }
        let candidateHandle = try FileHandle(forReadingFrom: candidate.outputURL)
        defer { try? candidateHandle.close() }
        try baselineHandle.seek(toOffset: 44)
        try candidateHandle.seek(toOffset: 44)

        var sampleCount = 0
        var signalSquareSum = 0.0
        var differenceSquareSum = 0.0
        var maximumDifference = 0.0
        while true {
            let baselineData = try baselineHandle.read(upToCount: 262_144) ?? Data()
            let candidateData = try candidateHandle.read(upToCount: 262_144) ?? Data()
            guard baselineData.count == candidateData.count,
                  baselineData.count.isMultiple(of: MemoryLayout<Int16>.size) else {
                throw BenchmarkError.outputLengthMismatch
            }
            if baselineData.isEmpty { break }

            baselineData.withUnsafeBytes { baselineBytes in
                candidateData.withUnsafeBytes { candidateBytes in
                    for offset in stride(from: 0, to: baselineData.count, by: 2) {
                        let baselineSample = Int16(littleEndian: baselineBytes.loadUnaligned(
                            fromByteOffset: offset,
                            as: Int16.self
                        ))
                        let candidateSample = Int16(littleEndian: candidateBytes.loadUnaligned(
                            fromByteOffset: offset,
                            as: Int16.self
                        ))
                        let signal = Double(baselineSample) / Double(Int16.max)
                        let difference = Double(Int(candidateSample) - Int(baselineSample))
                            / Double(Int16.max)
                        signalSquareSum += signal * signal
                        differenceSquareSum += difference * difference
                        maximumDifference = max(maximumDifference, abs(difference))
                        sampleCount += 1
                    }
                }
            }
        }

        let rmsDifference = sampleCount > 0
            ? sqrt(differenceSquareSum / Double(sampleCount))
            : 0
        let signalToDifferenceDB = differenceSquareSum > 0 && signalSquareSum > 0
            ? 10 * log10(signalSquareSum / differenceSquareSum)
            : nil
        return MeetingAecBenchmarkReport.OutputComparison(
            baselineThreads: baseline.report.threads,
            candidateThreads: candidate.report.threads,
            sampleCount: sampleCount,
            identical: differenceSquareSum == 0,
            rmsDifference: rmsDifference,
            maximumAbsoluteDifference: maximumDifference,
            signalToDifferenceDB: signalToDifferenceDB
        )
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case invalidArguments
    case bundleHasNoCanonicalRawAudio(String)
    case missingMicrophoneOutput(String)
    case unexpectedProcessor(expectedThreads: Int, actualProcessor: String, actualThreads: Int?)
    case requiresExactlyTwoThreadCounts
    case outputLengthMismatch

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: --aec-benchmark --support-directory PATH --bundle PATH [--bundle PATH ...] [--threads 2,4] [--output PATH]"
        case .bundleHasNoCanonicalRawAudio(let path):
            return "The bundle has no canonical raw audio: \(path)"
        case .missingMicrophoneOutput(let path):
            return "AEC produced no microphone output for: \(path)"
        case let .unexpectedProcessor(expected, processor, actual):
            let actualDescription = actual.map(String.init) ?? "unknown"
            return "Expected LocalVQE v1.2 with \(expected) threads, got \(processor) with \(actualDescription)"
        case .requiresExactlyTwoThreadCounts:
            return "The comparison requires exactly two distinct thread counts"
        case .outputLengthMismatch:
            return "AEC outputs have different or invalid PCM lengths"
        }
    }
}

/// Read-only bridge from the installed app's recording state into this
/// separate benchmark process. It pauses between the same bounded AEC blocks
/// if a real recording starts, so the experiment cannot knowingly compete
/// with capture. No user-profile table is written.
private final class RecordingMonitor: @unchecked Sendable {
    private let databaseURL: URL
    private let scheduler: MeetingInferenceScheduler
    private let ownerID = UUID()
    private let lock = NSLock()
    private var capturePublished = false

    init(databaseURL: URL, scheduler: MeetingInferenceScheduler) {
        self.databaseURL = databaseURL
        self.scheduler = scheduler
    }

    func start() -> Task<Void, Never> {
        refresh()
        return Task.detached(priority: .background) { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                refresh()
            }
        }
    }

    func stop() {
        let shouldEnd = lock.withLock {
            defer { capturePublished = false }
            return capturePublished
        }
        if shouldEnd {
            scheduler.endCapture(ownerID: ownerID)
        }
    }

    private func refresh() {
        guard let isRecording = queryRecordingState() else { return }
        let transition: Bool? = lock.withLock {
            guard isRecording != capturePublished else { return nil }
            capturePublished = isRecording
            return isRecording
        }
        guard let transition else { return }
        if transition {
            fputs("[aec-benchmark] paused while Homan is recording\n", stderr)
            scheduler.beginCapture(ownerID: ownerID)
        } else {
            fputs("[aec-benchmark] recording ended; resuming\n", stderr)
            scheduler.endCapture(ownerID: ownerID)
        }
    }

    private func queryRecordingState() -> Bool? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT EXISTS(SELECT 1 FROM meetings WHERE deleted_at IS NULL AND meeting_status = 'recording')"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0) != 0
    }
}
