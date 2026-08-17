@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Homan Whisper meeting batch client")
struct HomanWhisperBatchClientTests {
    @Test("endpoint accepts only the HTTPS Homan batch route")
    func endpointValidation() throws {
        let base = try HomanWhisperConfiguration(endpointString: "https://stt.dserver.pl")
        #expect(base.endpoint.absoluteString == "https://stt.dserver.pl/v1/homan/audio/transcriptions")

        let full = try HomanWhisperConfiguration(
            endpointString: "https://stt.dserver.pl/v1/homan/audio/transcriptions"
        )
        #expect(full == base)

        #expect(throws: HomanWhisperError.invalidEndpoint) {
            _ = try HomanWhisperConfiguration(endpointString: "http://stt.dserver.pl")
        }
        #expect(throws: HomanWhisperError.invalidEndpoint) {
            _ = try HomanWhisperConfiguration(endpointString: "https://stt.dserver.pl/v1/audio/transcriptions")
        }
        #expect(throws: HomanWhisperError.invalidEndpoint) {
            _ = try HomanWhisperConfiguration(endpointString: "https://stt.dserver.pl?token=secret")
        }
    }

    @Test("provider is cloud, final-only, and server-managed")
    func finalOnlyCatalogEntry() throws {
        #expect(!BackendOption.all.contains(.homanWhisper))
        #expect(BackendOption.finalOnly == [.homanWhisper])
        #expect(BackendOption.homanWhisper.label == "Homan Whisper")
        #expect(BackendOption.resolve(
            backend: BackendOption.homanWhisper.backend,
            model: BackendOption.homanWhisper.model
        ) == .homanWhisper)

        let descriptor = try #require(BackendOption.homanWhisper.meetingASRDescriptor)
        #expect(descriptor.capabilities.executionLocation == .cloud)
        #expect(descriptor.capabilities.supportsFullRecording)
        #expect(!descriptor.capabilities.liveMode.isAvailable)
        #expect(!descriptor.capabilities.requiresExplicitLanguage)
        #expect(MeetingASRModelCatalog.finalTranscription.contains(descriptor))
        #expect(!MeetingASRModelCatalog.live.contains(descriptor))
    }

    @Test("application configuration stores the Homan Whisper endpoint and key")
    func configPersistsCredentialLikeOtherProviderKeys() throws {
        var config = AppConfig()
        config.homanWhisperAPIKey = "stored-in-app-config"
        let data = try JSONEncoder().encode(AppConfig())
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("homan_whisper_endpoint"))
        let configuredData = try JSONEncoder().encode(config)
        let configuredJSON = String(decoding: configuredData, as: UTF8.self)
        #expect(configuredJSON.contains("homan_whisper_api_key"))
        #expect(configuredJSON.contains("stored-in-app-config"))
    }

    @Test("multipart keeps source roles, absolute times, and concurrency two")
    func multipartContract() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-whisper-batch-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let microphoneURL = directory.appendingPathComponent("microphone.m4a")
        let systemURL = directory.appendingPathComponent("system.m4a")
        try Data("microphone-audio".utf8).write(to: microphoneURL)
        try Data("system-audio".utf8).write(to: systemURL)
        let requestID = UUID()
        let client = HomanWhisperBatchClient()
        let bodyURL = try await client.writeMultipart(
            items: [
                RemoteMeetingSpeechItem(
                    id: "microphone-0000",
                    source: .microphone,
                    start: 4.22,
                    end: 12.81,
                    audioURL: microphoneURL
                ),
                RemoteMeetingSpeechItem(
                    id: "system-0000",
                    source: .system,
                    start: 13.10,
                    end: 25.40,
                    audioURL: systemURL
                ),
            ],
            requestID: requestID
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let body = try String(decoding: Data(contentsOf: bodyURL), as: UTF8.self)
        #expect(body.contains("name=\"manifest\""))
        #expect(body.contains("\"schema_version\":1"))
        #expect(body.contains("\"request_id\":\"\(requestID.uuidString)\""))
        #expect(body.contains("\"concurrency\":2"))
        #expect(body.contains("\"id\":\"microphone-0000\""))
        #expect(body.contains("\"source\":\"microphone\""))
        #expect(body.contains("\"start\":4.22"))
        #expect(body.contains("\"end\":12.81"))
        #expect(body.contains("name=\"audio_0000\""))
        #expect(body.contains("name=\"audio_0001\""))
        #expect(body.contains("Content-Type: audio/mp4"))
    }

    @Test("response cannot change item identity, source, or timeline")
    func responseValidation() async throws {
        let requestID = UUID()
        let audioURL = URL(fileURLWithPath: "/tmp/item.m4a")
        let requestItems = [
            RemoteMeetingSpeechItem(
                id: "microphone-0000",
                source: .microphone,
                start: 2.5,
                end: 6.25,
                audioURL: audioURL
            ),
        ]
        let client = HomanWhisperBatchClient()
        let valid = Data("""
        {
          "schema_version": 1,
          "request_id": "\(requestID.uuidString)",
          "concurrency_used": 1,
          "items": [
            {
              "id": "microphone-0000",
              "source": "microphone",
              "start": 2.5,
              "end": 6.25,
              "text": "  hello  ",
              "language": "en",
              "segments": []
            }
          ]
        }
        """.utf8)
        let result = try await client.decode(valid, requestID: requestID, requestItems: requestItems)
        #expect(result == [
            RemoteMeetingSpeechResult(
                id: "microphone-0000",
                source: .microphone,
                start: 2.5,
                end: 6.25,
                text: "hello"
            ),
        ])

        let changed = Data(String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(of: "\"source\": \"microphone\"", with: "\"source\": \"system\"")
            .utf8)
        await #expect(throws: HomanWhisperError.self) {
            _ = try await client.decode(changed, requestID: requestID, requestItems: requestItems)
        }

        // This mirrors the production Homan v1 shape: segment IDs are JSON
        // integers and segment timestamps are relative to their item.
        let withServerSegments = Data("""
        {
          "schema_version": 1,
          "request_id": "\(requestID.uuidString)",
          "concurrency_used": 1,
          "items": [
            {
              "id": "microphone-0000",
              "source": "microphone",
              "start": 2.5,
              "end": 6.25,
              "text": "hello there",
              "segments": [
                {"id": 0, "start": 0.1, "end": 0.6, "text": " hello "},
                {"id": 1, "start": 0.7, "end": 3.5, "text": "there"}
              ]
            }
          ]
        }
        """.utf8)
        let precise = try await client.decode(
            withServerSegments,
            requestID: requestID,
            requestItems: requestItems
        )
        #expect(precise.first?.segments == [
            RemoteMeetingSpeechSubsegment(
                id: "0",
                start: 2.6,
                end: 3.1,
                text: "hello"
            ),
            RemoteMeetingSpeechSubsegment(
                id: "1",
                start: 3.2,
                end: 6.0,
                text: "there"
            ),
        ])

        let withTimestampOnlySegments = Data(String(
            decoding: withServerSegments,
            as: UTF8.self
        )
            .replacingOccurrences(of: "\"id\": 0, ", with: "")
            .replacingOccurrences(of: "\"id\": 1, ", with: "")
            .replacingOccurrences(of: ", \"text\": \" hello \"", with: "")
            .replacingOccurrences(of: ", \"text\": \"there\"", with: "")
            .utf8)
        let timestampOnly = try await client.decode(
            withTimestampOnlySegments,
            requestID: requestID,
            requestItems: requestItems
        )
        #expect(timestampOnly.first?.text == "hello there")
        #expect(timestampOnly.first?.segments == nil)

        let mismatchedInnerText = Data(String(decoding: withServerSegments, as: UTF8.self)
            .replacingOccurrences(of: "\"text\": \"there\"", with: "\"text\": \"else\"")
            .utf8)
        let coarseFallback = try await client.decode(
            mismatchedInnerText,
            requestID: requestID,
            requestItems: requestItems
        )
        #expect(coarseFallback.first?.text == "hello there")
        #expect(coarseFallback.first?.segments == nil)

        let invalidInnerSegments = Data(String(decoding: withServerSegments, as: UTF8.self)
            .replacingOccurrences(of: "\"start\": 0.7", with: "\"start\": 0.4")
            .utf8)
        let invalidOptionalFallback = try await client.decode(
            invalidInnerSegments,
            requestID: requestID,
            requestItems: requestItems
        )
        #expect(invalidOptionalFallback.first?.text == "hello there")
        #expect(invalidOptionalFallback.first?.segments == nil)
    }

    @Test("native encoder produces mono 32 kHz AAC")
    func nativeAACProfile() async throws {
        let sampleRate = 16_000
        let samples = (0..<(sampleRate * 2)).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * 0.2)
        }
        let wavURL = try WavWriter.writeTemporaryWAV(
            samples: samples,
            directoryName: "homan-whisper-encoder-test"
        )
        let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: m4aURL)
        }

        try await HomanWhisperM4AEncoder.encode(wavURL: wavURL, destinationURL: m4aURL)
        let asset = AVURLAsset(url: m4aURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        let stream = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        #expect(stream.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(stream.pointee.mSampleRate == 32_000)
        #expect(stream.pointee.mChannelsPerFrame == 1)
    }

    @Test("retry decodes a saved response before requiring network credentials")
    func retryUsesSavedResponse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("homan-whisper-response-checkpoint-test", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("item.m4a")
        try Data("prepared-audio".utf8).write(to: audioURL)
        let responseURL = directory.appendingPathComponent("response.json")
        let requestID = UUID()
        try Data("""
        {
          "schema_version": 1,
          "request_id": "\(requestID.uuidString)",
          "concurrency_used": 1,
          "items": [
            {
              "id": "system-0000",
              "source": "system",
              "start": 1.0,
              "end": 2.0,
              "text": "saved response",
              "segments": [{"start": 0.0, "end": 1.0}]
            }
          ]
        }
        """.utf8).write(to: responseURL)
        let item = RemoteMeetingSpeechItem(
            id: "system-0000",
            source: .system,
            start: 1,
            end: 2,
            audioURL: audioURL
        )
        let client = HomanWhisperBatchClient(apiKey: "")

        let result = try await client.transcribe(
            items: [item],
            requestID: requestID,
            responseCacheURL: responseURL
        )

        #expect(result.map(\.text) == ["saved response"])
        #expect(result.first?.segments == nil)
    }
}
