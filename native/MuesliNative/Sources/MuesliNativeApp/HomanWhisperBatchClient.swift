@preconcurrency import AVFoundation
import Foundation

enum HomanWhisperError: Error, LocalizedError, Equatable {
    case missingCredential
    case invalidEndpoint
    case vadUnavailable
    case noSpeechItems
    case tooManyItems(Int)
    case invalidItem(String)
    case encodingFailed(String)
    case invalidResponse(String)
    case unauthorized
    case payloadTooLarge
    case rejectedRequest(Int)
    case serverUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "Configure the Homan Whisper API key in Meeting settings."
        case .invalidEndpoint:
            return "The Homan Whisper endpoint must be a valid HTTPS URL."
        case .vadUnavailable:
            return "Homan Whisper requires the meeting speech detector, but it is unavailable."
        case .noSpeechItems:
            return "No speech was detected in the recording."
        case .tooManyItems(let count):
            return "The meeting produced \(count) speech items; Homan Whisper accepts at most 2048."
        case .invalidItem(let id):
            return "The Homan Whisper speech item is invalid: \(id)."
        case .encodingFailed(let stage):
            return "A meeting speech item could not be encoded as AAC (\(stage))."
        case .invalidResponse(let reason):
            return "Homan Whisper returned an invalid transcription response: \(reason)."
        case .unauthorized:
            return "Homan Whisper rejected the API key. Update it in Meeting settings."
        case .payloadTooLarge:
            return "The Homan Whisper transcription batch is too large."
        case .rejectedRequest(let status):
            return "Homan Whisper rejected the transcription request (HTTP \(status))."
        case .serverUnavailable(let status):
            return "Homan Whisper is temporarily unavailable (HTTP \(status))."
        }
    }
}

struct HomanWhisperConfiguration: Equatable, Sendable {
    static let defaultBaseURL = "https://stt.dserver.pl"
    static let batchPath = "/v1/homan/audio/transcriptions"

    let endpoint: URL

    init(endpointString: String) throws {
        let trimmed = endpointString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw HomanWhisperError.invalidEndpoint
        }
        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.isEmpty {
            components.path = Self.batchPath
        } else if components.path != Self.batchPath {
            throw HomanWhisperError.invalidEndpoint
        }
        guard let endpoint = components.url else {
            throw HomanWhisperError.invalidEndpoint
        }
        self.endpoint = endpoint
    }
}

struct RemoteMeetingSpeechItem: Sendable {
    let id: String
    let source: MeetingAudioSourceRole
    let start: TimeInterval
    let end: TimeInterval
    let audioURL: URL
}

struct RemoteMeetingSpeechResult: Sendable, Equatable {
    let id: String
    let source: MeetingAudioSourceRole
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let segments: [RemoteMeetingSpeechSubsegment]?

    init(
        id: String,
        source: MeetingAudioSourceRole,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        segments: [RemoteMeetingSpeechSubsegment]? = nil
    ) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.text = text
        self.segments = segments
    }
}

struct RemoteMeetingSpeechSubsegment: Sendable, Equatable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

protocol MeetingBatchTranscriptionProviding: Sendable {
    func transcribeMeetingBatch(
        items: [RemoteMeetingSpeechItem],
        requestID: UUID
    ) async throws -> [RemoteMeetingSpeechResult]
}

actor HomanWhisperBatchClient {
    private static let jobQueue = InferenceGate()

    private struct Manifest: Encodable {
        struct Options: Encodable { let concurrency: Int }
        struct Item: Encodable {
            let id: String
            let source: String
            let start: Double
            let end: Double
            let file: String
        }

        let schemaVersion: Int
        let requestID: String
        let options: Options
        let items: [Item]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case requestID = "request_id"
            case options
            case items
        }
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            struct Segment: Decodable {
                let id: String
                let start: Double
                let end: Double
                let text: String
            }

            let id: String
            let source: String
            let start: Double
            let end: Double
            let text: String
            let segments: [Segment]?
        }

        let schemaVersion: Int
        let requestID: String
        let concurrencyUsed: Int
        let items: [Item]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case requestID = "request_id"
            case concurrencyUsed = "concurrency_used"
            case items
        }
    }

    private var configuration: HomanWhisperConfiguration
    private var apiKey: String
    private let session: URLSession

    init(
        endpointString: String = HomanWhisperConfiguration.defaultBaseURL,
        apiKey: String = "",
        session: URLSession? = nil
    ) {
        self.configuration = (try? HomanWhisperConfiguration(endpointString: endpointString))
            ?? (try! HomanWhisperConfiguration(endpointString: HomanWhisperConfiguration.defaultBaseURL))
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30 * 60
            config.timeoutIntervalForResource = 30 * 60
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    func configure(endpointString: String, apiKey: String) throws {
        configuration = try HomanWhisperConfiguration(endpointString: endpointString)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func validateCredential() throws {
        guard !apiKey.isEmpty else { throw HomanWhisperError.missingCredential }
    }

    func transcribe(
        items: [RemoteMeetingSpeechItem],
        requestID: UUID
    ) async throws -> [RemoteMeetingSpeechResult] {
        try await Self.jobQueue.acquire()
        do {
            try Task.checkCancellation()
            let result = try await transcribeExclusively(items: items, requestID: requestID)
            await Self.jobQueue.release()
            return result
        } catch {
            await Self.jobQueue.release()
            throw error
        }
    }

    private func transcribeExclusively(
        items: [RemoteMeetingSpeechItem],
        requestID: UUID
    ) async throws -> [RemoteMeetingSpeechResult] {
        try validate(items: items)
        try validateCredential()
        let token = apiKey
        let bodyURL = try writeMultipart(items: items, requestID: requestID)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var lastRetryableError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var request = URLRequest(url: configuration.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 30 * 60
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "multipart/form-data; boundary=\(boundary(for: requestID))",
                forHTTPHeaderField: "Content-Type"
            )
            do {
                let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
                guard let http = response as? HTTPURLResponse else {
                    throw HomanWhisperError.invalidResponse("missing HTTP response")
                }
                switch http.statusCode {
                case 200:
                    return try decode(data, requestID: requestID, requestItems: items)
                case 401:
                    throw HomanWhisperError.unauthorized
                case 413:
                    throw HomanWhisperError.payloadTooLarge
                case 429, 502, 503, 504:
                    lastRetryableError = HomanWhisperError.serverUnavailable(http.statusCode)
                case 400..<500:
                    throw HomanWhisperError.rejectedRequest(http.statusCode)
                default:
                    throw HomanWhisperError.serverUnavailable(http.statusCode)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HomanWhisperError {
                switch error {
                case .serverUnavailable(let status)
                    where [429, 502, 503, 504].contains(status):
                    lastRetryableError = error
                default:
                    throw error
                }
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                lastRetryableError = error
            }

            guard attempt < 2 else { break }
            let base = pow(2.0, Double(attempt))
            let jitter = Double.random(in: 0...0.25)
            try await Task.sleep(for: .seconds(base + jitter))
        }
        throw lastRetryableError ?? HomanWhisperError.serverUnavailable(0)
    }

    private func validate(items: [RemoteMeetingSpeechItem]) throws {
        guard !items.isEmpty else { throw HomanWhisperError.noSpeechItems }
        guard items.count <= 2048 else { throw HomanWhisperError.tooManyItems(items.count) }
        var ids = Set<String>()
        for item in items {
            guard !item.id.isEmpty,
                  ids.insert(item.id).inserted,
                  item.start.isFinite,
                  item.end.isFinite,
                  item.start >= 0,
                  item.end > item.start,
                  item.end - item.start <= 35.001,
                  item.audioURL.pathExtension.lowercased() == "m4a" else {
                throw HomanWhisperError.invalidItem(item.id)
            }
        }
    }

    func writeMultipart(
        items: [RemoteMeetingSpeechItem],
        requestID: UUID
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-whisper-stt", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let outputURL = directory.appendingPathComponent("\(requestID.uuidString).multipart")
        FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let boundary = boundary(for: requestID)
        let manifest = Manifest(
            schemaVersion: 1,
            requestID: requestID.uuidString,
            options: .init(concurrency: 2),
            items: items.enumerated().map { index, item in
                .init(
                    id: item.id,
                    source: item.source.rawValue,
                    start: item.start,
                    end: item.end,
                    file: String(format: "audio_%04d", index)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writePartHeader(
            name: "manifest",
            filename: "manifest.json",
            contentType: "application/json",
            boundary: boundary,
            handle: handle
        )
        try handle.write(contentsOf: encoder.encode(manifest))
        try handle.write(contentsOf: Data("\r\n".utf8))
        for (index, item) in items.enumerated() {
            try writePartHeader(
                name: String(format: "audio_%04d", index),
                filename: "\(item.id).m4a",
                contentType: "audio/mp4",
                boundary: boundary,
                handle: handle
            )
            let input = try FileHandle(forReadingFrom: item.audioURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try handle.write(contentsOf: Data("\r\n".utf8))
        }
        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        return outputURL
    }

    private func writePartHeader(
        name: String,
        filename: String,
        contentType: String,
        boundary: String,
        handle: FileHandle
    ) throws {
        let value = "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n" +
            "Content-Type: \(contentType)\r\n\r\n"
        try handle.write(contentsOf: Data(value.utf8))
    }

    func decode(
        _ data: Data,
        requestID: UUID,
        requestItems: [RemoteMeetingSpeechItem]
    ) throws -> [RemoteMeetingSpeechResult] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw HomanWhisperError.invalidResponse("malformed JSON")
        }
        guard response.schemaVersion == 1 else {
            throw HomanWhisperError.invalidResponse("unsupported schema")
        }
        guard response.requestID.lowercased() == requestID.uuidString.lowercased() else {
            throw HomanWhisperError.invalidResponse("request_id mismatch")
        }
        guard (1...2).contains(response.concurrencyUsed) else {
            throw HomanWhisperError.invalidResponse("invalid concurrency_used")
        }
        let requested = Dictionary(uniqueKeysWithValues: requestItems.map { ($0.id, $0) })
        guard response.items.count == requestItems.count else {
            throw HomanWhisperError.invalidResponse("item count mismatch")
        }
        var seen = Set<String>()
        return try response.items.map { item in
            guard seen.insert(item.id).inserted,
                  let original = requested[item.id],
                  item.source == original.source.rawValue,
                  abs(item.start - original.start) <= 0.001,
                  abs(item.end - original.end) <= 0.001 else {
                throw HomanWhisperError.invalidResponse("unknown, duplicate, or changed item")
            }
            let validatedSegments = try validateResponseSegments(
                item.segments,
                outerID: item.id,
                outerStart: original.start,
                outerEnd: original.end
            )
            let outerText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let textPreservingSegments = validatedSegments.flatMap { segments in
                let segmentedText = segments.map(\.text).joined(separator: " ")
                return Self.normalizedTranscriptText(segmentedText)
                    == Self.normalizedTranscriptText(outerText)
                    ? segments
                    : nil
            }
            return RemoteMeetingSpeechResult(
                id: item.id,
                source: original.source,
                start: original.start,
                end: original.end,
                text: outerText,
                // Fine timestamps are optional evidence. If they omit or add
                // text, retain the authoritative outer item as one coarse span
                // instead of silently changing the transcript.
                segments: textPreservingSegments
            )
        }
    }

    private static func normalizedTranscriptText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func validateResponseSegments(
        _ segments: [Response.Item.Segment]?,
        outerID: String,
        outerStart: TimeInterval,
        outerEnd: TimeInterval
    ) throws -> [RemoteMeetingSpeechSubsegment]? {
        guard let segments, !segments.isEmpty else { return nil }
        var ids = Set<String>()
        var previousEnd = outerStart
        var result: [RemoteMeetingSpeechSubsegment] = []
        result.reserveCapacity(segments.count)
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.id.isEmpty,
                  ids.insert(segment.id).inserted,
                  segment.start.isFinite,
                  segment.end.isFinite,
                  segment.start >= outerStart - 0.001,
                  segment.end <= outerEnd + 0.001,
                  segment.end > segment.start,
                  segment.start >= previousEnd - 0.001,
                  !text.isEmpty else {
                throw HomanWhisperError.invalidResponse(
                    "invalid inner segment in \(outerID)"
                )
            }
            result.append(RemoteMeetingSpeechSubsegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: text
            ))
            previousEnd = segment.end
        }
        return result
    }

    private func boundary(for requestID: UUID) -> String {
        "homan-native-\(requestID.uuidString.lowercased())"
    }
}

private final class HomanWhisperAssetWriterBox: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var finishStarted = false

    init(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }
}

enum HomanWhisperM4AEncoder {
    static func encode(wavURL: URL, destinationURL: URL) async throws {
        let asset = AVURLAsset(url: wavURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw HomanWhisperError.encodingFailed("missing audio track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw HomanWhisperError.encodingFailed("reader output")
        }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 32_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw HomanWhisperError.encodingFailed("writer input")
        }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? HomanWhisperError.encodingFailed("start")
        }
        writer.startSession(atSourceTime: .zero)

        let box = HomanWhisperAssetWriterBox(
            reader: reader,
            output: output,
            writer: writer,
            input: input
        )
        let queue = DispatchQueue(label: "homan-whisper-aac-encoder")
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            box.input.requestMediaDataWhenReady(on: queue) {
                while box.input.isReadyForMoreMediaData, !box.finishStarted {
                    if let sample = box.output.copyNextSampleBuffer() {
                        guard box.input.append(sample) else {
                            box.finishStarted = true
                            box.reader.cancelReading()
                            box.writer.cancelWriting()
                            continuation.resume(
                                throwing: box.writer.error ?? HomanWhisperError.encodingFailed("append")
                            )
                            return
                        }
                        continue
                    }
                    box.finishStarted = true
                    box.input.markAsFinished()
                    if box.reader.status == .failed || box.reader.status == .cancelled {
                        box.writer.cancelWriting()
                        continuation.resume(
                            throwing: box.reader.error ?? HomanWhisperError.encodingFailed("read")
                        )
                        return
                    }
                    box.writer.finishWriting {
                        if box.writer.status == .completed {
                            continuation.resume()
                        } else {
                            continuation.resume(
                                throwing: box.writer.error ?? HomanWhisperError.encodingFailed("finish")
                            )
                        }
                    }
                }
            }
        }
    }
}
