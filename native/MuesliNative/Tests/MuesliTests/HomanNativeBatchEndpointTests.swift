@preconcurrency import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Homan-native batch transcription endpoint")
struct HomanNativeBatchEndpointTests {
    @Test("real retained meeting follows Homan VAD and round-trips every item")
    func realMeetingBatchRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOMAN_STT_INTEGRATION"] == "1" else {
            return
        }
        let endpoint = try #require(
            environment["HOMAN_STT_ENDPOINT"].flatMap(URL.init(string:))
        )
        let token: String
        if let keyFile = environment["HOMAN_STT_API_KEY_FILE"] {
            token = try String(contentsOfFile: keyFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = try #require(environment["HOMAN_STT_API_KEY"])
        }
        guard !token.isEmpty else {
            throw HomanNativeBatchProbeError.missingAPIKey
        }
        let recordingPath = try #require(environment["HOMAN_STT_RECORDING"])
        let recordingURL = URL(fileURLWithPath: recordingPath)
        let requestedConcurrency = Int(environment["HOMAN_STT_CONCURRENCY"] ?? "1") ?? 1
        let localBaselineSeconds = Double(
            environment["HOMAN_LOCAL_TRANSCRIPTION_SECONDS"] ?? ""
        )

        let runStarted = ContinuousClock.now
        let prepared = try await HomanNativeMeetingFixture.prepare(
            recordingURL: recordingURL
        )
        defer { prepared.removeTemporaryFiles() }
        let preparationSeconds = runStarted.duration(to: .now).seconds

        let request = try HomanNativeBatchRequestBuilder.makeRequest(
            endpoint: endpoint,
            token: token,
            concurrency: requestedConcurrency,
            items: prepared.items
        )
        let uploadBytes = request.httpBody?.count ?? 0
        if let dumpPath = environment["HOMAN_STT_REQUEST_DUMP"] {
            let dumpURL = URL(fileURLWithPath: dumpPath)
            try #require(request.httpBody).write(to: dumpURL, options: .atomic)
            let dumpReport = HomanNativeBatchRequestDumpReport(
                contentType: try #require(
                    request.value(forHTTPHeaderField: "Content-Type")
                ),
                recordingSeconds: prepared.recordingDuration,
                speechSeconds: prepared.items.reduce(0.0) {
                    $0 + ($1.end - $1.start)
                },
                itemCount: prepared.items.count,
                multipartBytes: uploadBytes,
                requestedConcurrency: requestedConcurrency
            )
            let reportURL = dumpURL.appendingPathExtension("json")
            try JSONEncoder.sorted.encode(dumpReport).write(
                to: reportURL,
                options: .atomic
            )
            print(String(
                decoding: try JSONEncoder.sorted.encode(dumpReport),
                as: UTF8.self
            ))
            return
        }
        let requestStarted = ContinuousClock.now
        let (responseData, urlResponse) = try await URLSession.homanIntegration.data(
            for: request
        )
        let requestSeconds = requestStarted.duration(to: .now).seconds
        let totalSeconds = runStarted.duration(to: .now).seconds

        let http = try #require(urlResponse as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        guard http.statusCode == 200 else {
            throw HomanNativeBatchProbeError.httpStatus(http.statusCode)
        }

        let response = try JSONDecoder().decode(
            HomanNativeBatchResponse.self,
            from: responseData
        )
        #expect(response.schemaVersion == 1)
        #expect(response.model == "large-v3-turbo")
        #expect(response.items.count == prepared.items.count)
        #expect(Set(response.items.map(\.id)) == Set(prepared.items.map(\.id)))
        #expect(response.concurrencyUsed >= 1)
        #expect(response.concurrencyUsed <= requestedConcurrency)

        let requestItems = Dictionary(
            uniqueKeysWithValues: prepared.items.map { ($0.id, $0) }
        )
        var nonEmptySources = Set<MeetingAudioSourceRole>()
        for result in response.items {
            let original = try #require(requestItems[result.id])
            #expect(result.source == original.source.apiValue)
            #expect(abs(result.start - original.start) < 0.001)
            #expect(abs(result.end - original.end) < 0.001)
            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nonEmptySources.insert(original.source)
            }
        }
        #expect(!nonEmptySources.isEmpty)

        let microphoneSegments = response.items.compactMap { item in
            item.source == MeetingAudioSourceRole.microphone.apiValue &&
                !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? SpeechSegment(
                    start: item.start,
                    end: item.end,
                    text: item.text
                )
                : nil
        }
        let systemSegments = response.items.compactMap { item in
            item.source == MeetingAudioSourceRole.system.apiValue &&
                !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? SpeechSegment(
                    start: item.start,
                    end: item.end,
                    text: item.text
                )
                : nil
        }
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: microphoneSegments,
            systemSegments: systemSegments,
            diarizationSegments: nil
        )
        let attributedTurns = TranscriptFormatter.attributedTurns(
            micSegments: reconciled.micSegments,
            systemSegments: reconciled.systemSegments,
            diarizationSegments: reconciled.diarizationSegments,
            recordingSessionID: nil,
            isProvisional: false
        )
        let formattedTranscript = TranscriptFormatter.format(
            attributedTurns: attributedTurns,
            meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(!attributedTurns.isEmpty)
        #expect(!formattedTranscript.isEmpty)

        let sourceTimelineSeconds = prepared.recordingDuration *
            Double(prepared.sourceCount)
        let speechSeconds = prepared.items.reduce(0.0) {
            $0 + ($1.end - $1.start)
        }
        let localRatio = localBaselineSeconds.map {
            totalSeconds > 0 ? $0 / totalSeconds : 0
        }
        let responseDigest = SHA256.hash(data: Data(
            response.items
                .map { "\($0.id)\u{0}\($0.text)" }
                .joined(separator: "\u{1e}")
                .utf8
        )).map { String(format: "%02x", $0) }.joined()
        let formattedTranscriptDigest = SHA256.hash(
            data: Data(formattedTranscript.utf8)
        ).map { String(format: "%02x", $0) }.joined()
        let report = HomanNativeBatchProbeReport(
            recordingSeconds: prepared.recordingDuration,
            sourceTimelineSeconds: sourceTimelineSeconds,
            speechSeconds: speechSeconds,
            itemCount: prepared.items.count,
            encodedBytes: prepared.items.reduce(0) { $0 + $1.byteCount },
            multipartBytes: uploadBytes,
            requestedConcurrency: requestedConcurrency,
            usedConcurrency: response.concurrencyUsed,
            preparationSeconds: preparationSeconds,
            requestSeconds: requestSeconds,
            serverSeconds: response.serverWallMilliseconds / 1_000,
            totalSeconds: totalSeconds,
            packingReelCount: response.packing.reelCount,
            packedAudioSeconds: response.packing.packedAudioDuration,
            crossItemSegmentCount: response.packing.crossItemSegments,
            fallbackItemCount: response.packing.fallbackItemCount,
            fallbackSeconds: response.packing.fallbackProcessingMilliseconds / 1_000,
            localBaselineSeconds: localBaselineSeconds,
            remoteSpeedupVersusLocal: localRatio,
            responseDigest: responseDigest,
            formattedTurnCount: attributedTurns.count,
            formattedTranscriptCharacters: formattedTranscript.count,
            formattedTranscriptDigest: formattedTranscriptDigest
        )
        print(try report.jsonLine())
    }

    @Test("warm local WhisperKit and remote batch transcribe the same retained meeting")
    func warmLocalRemoteComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOMAN_STT_COMPARE"] == "1" else {
            return
        }
        let endpoint = try #require(
            environment["HOMAN_STT_ENDPOINT"].flatMap(URL.init(string:))
        )
        let token = try HomanComparisonConfiguration.apiKey(environment)
        let recordingPath = try #require(environment["HOMAN_STT_RECORDING"])
        let recordingURL = URL(fileURLWithPath: recordingPath)
        let requestedConcurrency = Int(
            environment["HOMAN_STT_CONCURRENCY"] ?? "2"
        ) ?? 2
        print("HOMAN_COMPARE_PHASE remote_preparation_start")
        let remotePreparationStarted = ContinuousClock.now
        let prepared = try await HomanNativeMeetingFixture.prepare(
            recordingURL: recordingURL
        )
        defer { prepared.removeTemporaryFiles() }
        let remotePreparationSeconds = remotePreparationStarted
            .duration(to: .now)
            .seconds
        print("HOMAN_COMPARE_PHASE remote_preparation_complete")

        let coordinator = TranscriptionCoordinator()
        print("HOMAN_COMPARE_PHASE local_warmup_start")
        let localWarmupStarted = ContinuousClock.now
        try await coordinator.preloadRequired(
            backend: .whisperLargeTurbo,
            enablePostProcessor: false,
            includeMeetingHelpers: true
        )
        if let warmupItem = prepared.items.first {
            _ = try await coordinator.transcribeMeeting(
                at: warmupItem.wavURL,
                backend: .whisperLargeTurbo
            )
        }
        let localWarmupSeconds = localWarmupStarted.duration(to: .now).seconds
        print("HOMAN_COMPARE_PHASE local_warmup_complete")

        let recording = MeetingRecordingRecord(
            id: 128,
            meetingID: 25,
            path: recordingURL.path,
            createdAt: Date(timeIntervalSince1970: 0),
            deleteAfter: nil,
            sourceLayout: .separateStereoMicrophoneAndSystem
        )
        print("HOMAN_COMPARE_PHASE local_timed_start")
        let localStarted = ContinuousClock.now
        let localResult = try await MeetingTranscriptionPipeline(
            coordinator: coordinator
        ).process(MeetingTranscriptionRequest(
            units: [.separatedChannels(.init(
                recording: recording,
                recordingURL: recordingURL,
                sourceLayout: .separateStereoMicrophoneAndSystem
            ))],
            backend: .whisperLargeTurbo,
            languages: .init(),
            purpose: .retranscribe,
            systemDiarization: .disabled
        ))
        let localSeconds = localStarted.duration(to: .now).seconds
        print("HOMAN_COMPARE_PHASE local_timed_complete")
        await coordinator.shutdown()

        print("HOMAN_COMPARE_PHASE remote_warmup_start")
        let warmupRequest = try HomanNativeBatchRequestBuilder.makeRequest(
            endpoint: endpoint,
            token: token,
            concurrency: 1,
            items: Array(prepared.items.prefix(1))
        )
        let remoteWarmupStarted = ContinuousClock.now
        let (warmupData, warmupURLResponse) = try await URLSession
            .homanIntegration
            .data(for: warmupRequest)
        let remoteWarmupSeconds = remoteWarmupStarted.duration(to: .now).seconds
        let warmupHTTP = try #require(warmupURLResponse as? HTTPURLResponse)
        guard warmupHTTP.statusCode == 200 else {
            throw HomanNativeBatchProbeError.httpStatus(warmupHTTP.statusCode)
        }
        _ = try JSONDecoder().decode(
            HomanNativeBatchResponse.self,
            from: warmupData
        )
        print("HOMAN_COMPARE_PHASE remote_warmup_complete")

        // Let automatic DPM return to idle while keeping the model resident.
        print("HOMAN_COMPARE_PHASE remote_idle_wait_start")
        try await Task.sleep(nanoseconds: 15_000_000_000)
        print("HOMAN_COMPARE_PHASE remote_idle_wait_complete")

        print("HOMAN_COMPARE_PHASE remote_timed_start")
        let remoteRequest = try HomanNativeBatchRequestBuilder.makeRequest(
            endpoint: endpoint,
            token: token,
            concurrency: requestedConcurrency,
            items: prepared.items
        )
        let remoteRequestStarted = ContinuousClock.now
        let (responseData, urlResponse) = try await URLSession
            .homanIntegration
            .data(for: remoteRequest)
        let remoteRequestSeconds = remoteRequestStarted.duration(to: .now).seconds
        let http = try #require(urlResponse as? HTTPURLResponse)
        guard http.statusCode == 200 else {
            throw HomanNativeBatchProbeError.httpStatus(http.statusCode)
        }
        let response = try JSONDecoder().decode(
            HomanNativeBatchResponse.self,
            from: responseData
        )
        #expect(response.items.count == prepared.items.count)
        #expect(Set(response.items.map(\.id)) == Set(prepared.items.map(\.id)))
        print("HOMAN_COMPARE_PHASE remote_timed_complete")

        let localUnit = try #require(localResult.units.first)
        let remoteSegments = HomanComparableTranscript.remoteSegments(
            response.items
        )
        let remoteReconciled = TranscriptReconciler.reconcile(
            micTurns: remoteSegments.microphone,
            systemSegments: remoteSegments.system,
            diarizationSegments: nil
        )
        let localComparable = HomanComparableTranscript(
            microphone: localUnit.microphoneSegments,
            system: localUnit.systemSegments
        )
        let remoteComparable = HomanComparableTranscript(
            microphone: remoteReconciled.micSegments,
            system: remoteReconciled.systemSegments
        )
        let overallDifference = localComparable.difference(from: remoteComparable)
        let microphoneDifference = HomanComparableTranscript.wordDifference(
            localComparable.microphoneText,
            remoteComparable.microphoneText
        )
        let systemDifference = HomanComparableTranscript.wordDifference(
            localComparable.systemText,
            remoteComparable.systemText
        )

        let report = HomanLocalRemoteComparisonReport(
            recordingSeconds: prepared.recordingDuration,
            speechSeconds: prepared.items.reduce(0.0) {
                $0 + ($1.end - $1.start)
            },
            itemCount: prepared.items.count,
            localWarmupSeconds: localWarmupSeconds,
            localEndToEndSeconds: localSeconds,
            remoteWarmupSeconds: remoteWarmupSeconds,
            remotePreparationSeconds: remotePreparationSeconds,
            remoteRequestSeconds: remoteRequestSeconds,
            remoteServerSeconds: response.serverWallMilliseconds / 1_000,
            remoteEndToEndSeconds: remotePreparationSeconds + remoteRequestSeconds,
            localWordCount: overallDifference.leftWordCount,
            remoteWordCount: overallDifference.rightWordCount,
            wordEditDistance: overallDifference.editDistance,
            wordDifferenceRatio: overallDifference.ratio,
            microphoneDifferenceRatio: microphoneDifference.ratio,
            systemDifferenceRatio: systemDifference.ratio,
            withinFivePercent: overallDifference.ratio <= 0.05,
            localDigest: localComparable.digest,
            remoteDigest: remoteComparable.digest
        )
        print("HOMAN_COMPARE_REPORT \(try report.jsonLine())")
        #expect(overallDifference.ratio <= 0.05)
    }

    @Test("warm local WhisperKit and remote batch transcribe identical prepared items")
    func warmExactPreparedItemComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOMAN_STT_COMPARE_ITEMS"] == "1" else {
            return
        }
        let endpoint = try #require(
            environment["HOMAN_STT_ENDPOINT"].flatMap(URL.init(string:))
        )
        let token = try HomanComparisonConfiguration.apiKey(environment)
        let recordingPath = try #require(environment["HOMAN_STT_RECORDING"])
        let recordingURL = URL(fileURLWithPath: recordingPath)
        let requestedConcurrency = Int(
            environment["HOMAN_STT_CONCURRENCY"] ?? "2"
        ) ?? 2
        let remoteAudioFormat = HomanProbeAudioFormat(
            environmentValue: environment["HOMAN_STT_REMOTE_AUDIO_FORMAT"]
        )

        print("HOMAN_ITEM_COMPARE_PHASE preparation_start")
        let preparationStarted = ContinuousClock.now
        let prepared = try await HomanNativeMeetingFixture.prepare(
            recordingURL: recordingURL
        )
        defer { prepared.removeTemporaryFiles() }
        let preparationSeconds = preparationStarted.duration(to: .now).seconds
        let itemStride = max(
            1,
            Int(environment["HOMAN_STT_ITEM_STRIDE"] ?? "1") ?? 1
        )
        let comparisonItems = prepared.items.enumerated().compactMap {
            index, item in
            index.isMultiple(of: itemStride) ? item : nil
        }
        guard !comparisonItems.isEmpty else {
            throw HomanNativeBatchProbeError.invalidItemSelection
        }
        print("HOMAN_ITEM_COMPARE_PHASE preparation_complete")

        let coordinator = TranscriptionCoordinator()
        let localItems: [HomanExactTranscriptionItem]
        let localWarmupSeconds: Double
        let localTranscriptionSeconds: Double
        do {
            print("HOMAN_ITEM_COMPARE_PHASE local_warmup_start")
            let warmupStarted = ContinuousClock.now
            try await coordinator.preloadRequired(
                backend: .whisperLargeTurbo,
                enablePostProcessor: false,
                includeMeetingHelpers: true
            )
            if let warmupItem = comparisonItems.first {
                _ = try await coordinator.transcribeMeeting(
                    at: warmupItem.wavURL,
                    backend: .whisperLargeTurbo
                )
            }
            localWarmupSeconds = warmupStarted.duration(to: .now).seconds
            print("HOMAN_ITEM_COMPARE_PHASE local_warmup_complete")

            print("HOMAN_ITEM_COMPARE_PHASE local_items_start")
            let localStarted = ContinuousClock.now
            localItems = try await HomanExactItemComparator.transcribeLocally(
                comparisonItems,
                coordinator: coordinator
            )
            localTranscriptionSeconds = localStarted.duration(to: .now).seconds
            print("HOMAN_ITEM_COMPARE_PHASE local_items_complete")
        } catch {
            await coordinator.shutdown()
            throw error
        }
        await coordinator.shutdown()

        print("HOMAN_ITEM_COMPARE_PHASE remote_warmup_start")
        let warmupRequest = try HomanNativeBatchRequestBuilder.makeRequest(
            endpoint: endpoint,
            token: token,
            concurrency: 1,
            items: Array(comparisonItems.prefix(1)),
            audioFormat: remoteAudioFormat
        )
        let remoteWarmupStarted = ContinuousClock.now
        let (warmupData, warmupURLResponse) = try await URLSession
            .homanIntegration
            .data(for: warmupRequest)
        let remoteWarmupSeconds = remoteWarmupStarted.duration(to: .now).seconds
        let warmupHTTP = try #require(warmupURLResponse as? HTTPURLResponse)
        guard warmupHTTP.statusCode == 200 else {
            throw HomanNativeBatchProbeError.httpStatus(warmupHTTP.statusCode)
        }
        _ = try JSONDecoder().decode(
            HomanNativeBatchResponse.self,
            from: warmupData
        )
        print("HOMAN_ITEM_COMPARE_PHASE remote_warmup_complete")

        print("HOMAN_ITEM_COMPARE_PHASE remote_items_start")
        let remoteRequest = try HomanNativeBatchRequestBuilder.makeRequest(
            endpoint: endpoint,
            token: token,
            concurrency: requestedConcurrency,
            items: comparisonItems,
            audioFormat: remoteAudioFormat
        )
        let remoteStarted = ContinuousClock.now
        let (responseData, urlResponse) = try await URLSession
            .homanIntegration
            .data(for: remoteRequest)
        let remoteRequestSeconds = remoteStarted.duration(to: .now).seconds
        let http = try #require(urlResponse as? HTTPURLResponse)
        guard http.statusCode == 200 else {
            throw HomanNativeBatchProbeError.httpStatus(http.statusCode)
        }
        let response = try JSONDecoder().decode(
            HomanNativeBatchResponse.self,
            from: responseData
        )
        #expect(response.items.count == comparisonItems.count)
        #expect(Set(response.items.map(\.id)) == Set(comparisonItems.map(\.id)))
        print("HOMAN_ITEM_COMPARE_PHASE remote_items_complete")
        let shouldCleanRemote = environment["HOMAN_STT_CLEAN_REMOTE"] == "1"
        let comparisonResponseItems = shouldCleanRemote
            ? HomanExactItemComparator.cleanedRemoteItems(response.items)
            : response.items

        var isolatedRemoteItems: [HomanExactTranscriptionItem]?
        var isolatedRemoteSeconds: Double?
        if environment["HOMAN_STT_COMPARE_ISOLATED"] == "1" {
            let isolatedEndpoint = try #require(
                environment["HOMAN_STT_OPENAI_ENDPOINT"].flatMap(URL.init(string:))
            )
            print("HOMAN_ITEM_COMPARE_PHASE isolated_remote_start")
            let isolatedStarted = ContinuousClock.now
            let isolatedRequestedLanguages = environment[
                "HOMAN_STT_REMOTE_USE_LOCAL_LANGUAGE"
            ] == "1"
                ? Dictionary(uniqueKeysWithValues: localItems.compactMap {
                    item in
                    item.language.map { (item.id, $0) }
                })
                : [:]
            let transcribedRemoteItems = try await HomanExactItemComparator
                .transcribeRemotelyIndividually(
                    comparisonItems,
                    endpoint: isolatedEndpoint,
                    token: token,
                    audioFormat: remoteAudioFormat,
                    requestedLanguages: isolatedRequestedLanguages
                )
            isolatedRemoteItems = shouldCleanRemote
                ? HomanExactItemComparator.cleanedRemoteItems(
                    transcribedRemoteItems
                )
                : transcribedRemoteItems
            isolatedRemoteSeconds = isolatedStarted.duration(to: .now).seconds
            print("HOMAN_ITEM_COMPARE_PHASE isolated_remote_complete")
        }

        var localWhisperCppItems: [HomanExactTranscriptionItem]?
        var localWhisperCppSeconds: Double?
        if let binaryPath = environment["HOMAN_STT_LOCAL_WHISPER_CPP_BINARY"],
           let modelPath = environment["HOMAN_STT_LOCAL_WHISPER_CPP_MODEL"] {
            print("HOMAN_ITEM_COMPARE_PHASE local_whisper_cpp_start")
            let localWhisperCppStarted = ContinuousClock.now
            localWhisperCppItems = try HomanExactItemComparator
                .transcribeLocallyWithWhisperCpp(
                    comparisonItems,
                    binaryURL: URL(fileURLWithPath: binaryPath),
                    modelURL: URL(fileURLWithPath: modelPath),
                    threads: max(
                        1,
                        Int(environment["HOMAN_STT_LOCAL_WHISPER_CPP_THREADS"] ?? "4") ?? 4
                    )
                )
            localWhisperCppSeconds = localWhisperCppStarted.duration(to: .now)
                .seconds
            print("HOMAN_ITEM_COMPARE_PHASE local_whisper_cpp_complete")
        }

        let report = HomanExactItemComparator.makeReport(
            prepared: comparisonItems,
            local: localItems,
            remote: comparisonResponseItems,
            isolatedRemote: isolatedRemoteItems,
            isolatedRemoteSeconds: isolatedRemoteSeconds,
            preparationSeconds: preparationSeconds,
            localWarmupSeconds: localWarmupSeconds,
            localTranscriptionSeconds: localTranscriptionSeconds,
            remoteWarmupSeconds: remoteWarmupSeconds,
            remoteRequestSeconds: remoteRequestSeconds,
            response: response
        )
        print("HOMAN_ITEM_COMPARE_REPORT \(try report.jsonLine())")
        if let localWhisperCppItems,
           let localWhisperCppSeconds {
            let localWhisperCppReport = HomanExactItemComparator
                .makeWhisperCppPlatformReport(
                    items: comparisonItems,
                    localWhisperKit: localItems,
                    localWhisperCpp: localWhisperCppItems,
                    packedRemote: comparisonResponseItems,
                    isolatedRemote: isolatedRemoteItems,
                    localWhisperCppSeconds: localWhisperCppSeconds
                )
            print(
                "HOMAN_WHISPER_CPP_PLATFORM_REPORT " +
                    (try localWhisperCppReport.jsonLine())
            )
        }
        #expect(report.missingLocalItemCount == 0)
        #expect(report.missingRemoteItemCount == 0)
        #expect(report.concatenatedDifferenceRatio <= 0.05)
    }

    @Test("two warm local WhisperKit passes transcribe identical prepared items")
    func warmLocalRepeatabilityComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOMAN_STT_COMPARE_LOCAL_REPEAT"] == "1" else {
            return
        }
        let recordingPath = try #require(environment["HOMAN_STT_RECORDING"])
        let recordingURL = URL(fileURLWithPath: recordingPath)

        print("HOMAN_LOCAL_REPEAT_PHASE preparation_start")
        let preparationStarted = ContinuousClock.now
        let prepared = try await HomanNativeMeetingFixture.prepare(
            recordingURL: recordingURL
        )
        defer { prepared.removeTemporaryFiles() }
        let preparationSeconds = preparationStarted.duration(to: .now).seconds
        print("HOMAN_LOCAL_REPEAT_PHASE preparation_complete")

        let coordinator = TranscriptionCoordinator()
        let warmupSeconds: Double
        let first: [HomanExactTranscriptionItem]
        let firstSeconds: Double
        let second: [HomanExactTranscriptionItem]
        let secondSeconds: Double
        do {
            print("HOMAN_LOCAL_REPEAT_PHASE warmup_start")
            let warmupStarted = ContinuousClock.now
            try await coordinator.preloadRequired(
                backend: .whisperLargeTurbo,
                enablePostProcessor: false,
                includeMeetingHelpers: true
            )
            if let warmupItem = prepared.items.first {
                _ = try await coordinator.transcribeMeeting(
                    at: warmupItem.wavURL,
                    backend: .whisperLargeTurbo
                )
            }
            warmupSeconds = warmupStarted.duration(to: .now).seconds
            print("HOMAN_LOCAL_REPEAT_PHASE warmup_complete")

            print("HOMAN_LOCAL_REPEAT_PHASE first_start")
            let firstStarted = ContinuousClock.now
            first = try await HomanExactItemComparator.transcribeLocally(
                prepared.items,
                coordinator: coordinator
            )
            firstSeconds = firstStarted.duration(to: .now).seconds
            print("HOMAN_LOCAL_REPEAT_PHASE first_complete")

            print("HOMAN_LOCAL_REPEAT_PHASE second_start")
            let secondStarted = ContinuousClock.now
            second = try await HomanExactItemComparator.transcribeLocally(
                prepared.items,
                coordinator: coordinator
            )
            secondSeconds = secondStarted.duration(to: .now).seconds
            print("HOMAN_LOCAL_REPEAT_PHASE second_complete")
        } catch {
            await coordinator.shutdown()
            throw error
        }
        await coordinator.shutdown()

        let firstTexts = Dictionary(uniqueKeysWithValues: first.map {
            ($0.id, $0.text)
        })
        let secondTexts = Dictionary(uniqueKeysWithValues: second.map {
            ($0.id, $0.text)
        })
        let comparison = HomanExactItemComparator.pairMetrics(
            items: prepared.items,
            left: firstTexts,
            right: secondTexts
        )
        let report = HomanLocalRepeatabilityReport(
            itemCount: prepared.items.count,
            preparationSeconds: preparationSeconds,
            warmupSeconds: warmupSeconds,
            firstSeconds: firstSeconds,
            secondSeconds: secondSeconds,
            comparison: comparison
        )
        print("HOMAN_LOCAL_REPEAT_REPORT \(try report.jsonLine())")
        #expect(comparison.concatenatedDifferenceRatio <= 0.05)
    }

    @Test("remote Homan batch matches isolated whisper.cpp items")
    func remoteBatchVersusIsolatedComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOMAN_STT_COMPARE_REMOTE_MODES"] == "1" else {
            return
        }
        let endpoint = try #require(
            environment["HOMAN_STT_ENDPOINT"].flatMap(URL.init(string:))
        )
        let isolatedEndpoint = try #require(
            environment["HOMAN_STT_OPENAI_ENDPOINT"].flatMap(URL.init(string:))
        )
        let token = try HomanComparisonConfiguration.apiKey(environment)
        let recordingPath = try #require(environment["HOMAN_STT_RECORDING"])
        let recordingURL = URL(fileURLWithPath: recordingPath)
        let requestedConcurrency = Int(
            environment["HOMAN_STT_CONCURRENCY"] ?? "2"
        ) ?? 2
        let remoteAudioFormat = HomanProbeAudioFormat(
            environmentValue: environment["HOMAN_STT_REMOTE_AUDIO_FORMAT"]
        )
        let itemStride = max(
            1,
            Int(environment["HOMAN_STT_ITEM_STRIDE"] ?? "1") ?? 1
        )

        print("HOMAN_REMOTE_MODES_PHASE preparation_start")
        let preparationStarted = ContinuousClock.now
        let prepared = try await HomanNativeMeetingFixture.prepare(
            recordingURL: recordingURL
        )
        defer { prepared.removeTemporaryFiles() }
        let items = prepared.items.enumerated().compactMap { index, item in
            index.isMultiple(of: itemStride) ? item : nil
        }
        guard !items.isEmpty else {
            throw HomanNativeBatchProbeError.invalidItemSelection
        }
        let preparationSeconds = preparationStarted.duration(to: .now).seconds
        print("HOMAN_REMOTE_MODES_PHASE preparation_complete")

        print("HOMAN_REMOTE_MODES_PHASE warmup_start")
        let warmupRequest = try HomanNativeBatchRequestBuilder.makeRequest(
            endpoint: endpoint,
            token: token,
            concurrency: 1,
            items: Array(items.prefix(1)),
            audioFormat: remoteAudioFormat
        )
        let warmupStarted = ContinuousClock.now
        let (warmupData, warmupURLResponse) = try await URLSession
            .homanIntegration
            .data(for: warmupRequest)
        let warmupSeconds = warmupStarted.duration(to: .now).seconds
        let warmupHTTP = try #require(warmupURLResponse as? HTTPURLResponse)
        guard warmupHTTP.statusCode == 200 else {
            throw HomanNativeBatchProbeError.httpStatus(warmupHTTP.statusCode)
        }
        _ = try JSONDecoder().decode(
            HomanNativeBatchResponse.self,
            from: warmupData
        )
        print("HOMAN_REMOTE_MODES_PHASE warmup_complete")

        print("HOMAN_REMOTE_MODES_PHASE batch_start")
        let batchRequest = try HomanNativeBatchRequestBuilder.makeRequest(
            endpoint: endpoint,
            token: token,
            concurrency: requestedConcurrency,
            items: items,
            audioFormat: remoteAudioFormat
        )
        let batchStarted = ContinuousClock.now
        let (batchData, batchURLResponse) = try await URLSession
            .homanIntegration
            .data(for: batchRequest)
        let batchSeconds = batchStarted.duration(to: .now).seconds
        let batchHTTP = try #require(batchURLResponse as? HTTPURLResponse)
        guard batchHTTP.statusCode == 200 else {
            throw HomanNativeBatchProbeError.httpStatus(batchHTTP.statusCode)
        }
        let batchResponse = try JSONDecoder().decode(
            HomanNativeBatchResponse.self,
            from: batchData
        )
        print("HOMAN_REMOTE_MODES_PHASE batch_complete")

        print("HOMAN_REMOTE_MODES_PHASE isolated_start")
        let isolatedStarted = ContinuousClock.now
        let isolatedItems = try await HomanExactItemComparator
            .transcribeRemotelyIndividually(
                items,
                endpoint: isolatedEndpoint,
                token: token,
                audioFormat: remoteAudioFormat
            )
        let isolatedSeconds = isolatedStarted.duration(to: .now).seconds
        print("HOMAN_REMOTE_MODES_PHASE isolated_complete")

        let batchTexts = Dictionary(uniqueKeysWithValues:
            batchResponse.items.map { ($0.id, $0.text) }
        )
        let isolatedTexts = Dictionary(uniqueKeysWithValues:
            isolatedItems.map { ($0.id, $0.text) }
        )
        let comparison = HomanExactItemComparator.pairMetrics(
            items: items,
            left: batchTexts,
            right: isolatedTexts
        )
        let diagnostics = HomanExactItemComparator.remoteModeDiagnostics(
            items: items,
            batch: batchResponse.items,
            isolated: isolatedItems
        )
        let report = HomanRemoteModesReport(
            itemCount: items.count,
            preparationSeconds: preparationSeconds,
            warmupSeconds: warmupSeconds,
            batchRequestSeconds: batchSeconds,
            batchServerSeconds: batchResponse.serverWallMilliseconds / 1_000,
            isolatedSeconds: isolatedSeconds,
            concurrencyUsed: batchResponse.concurrencyUsed,
            packingEnabled: batchResponse.packing.enabled,
            reelCount: batchResponse.packing.reelCount,
            fallbackItemCount: batchResponse.packing.fallbackItemCount,
            comparison: comparison,
            diagnostics: diagnostics
        )
        print("HOMAN_REMOTE_MODES_REPORT \(try report.jsonLine())")
        #expect(comparison.concatenatedDifferenceRatio <= 0.05)
    }
}

private struct HomanNativePreparedFixture {
    let items: [HomanNativeBatchAudioItem]
    let recordingDuration: Double
    let sourceCount: Int

    func removeTemporaryFiles(fileManager: FileManager = .default) {
        for item in items {
            try? fileManager.removeItem(at: item.fileURL)
            try? fileManager.removeItem(at: item.wavURL)
        }
    }
}

private enum HomanNativeMeetingFixture {
    static func prepare(recordingURL: URL) async throws -> HomanNativePreparedFixture {
        let separated = try MeetingRecordingWriter.extractSeparatedChannels(
            from: recordingURL,
            sourceLayout: .separateStereoMicrophoneAndSystem
        )
        defer { separated.removeTemporaryFiles() }

        let sources: [(MeetingAudioSourceRole, URL)] = [
            separated.microphoneURL.map { (.microphone, $0) },
            separated.systemURL.map { (.system, $0) },
        ].compactMap { $0 }
        let recordingDuration = try audioDuration(recordingURL)
        let vadManager = try await VadManager()
        var result: [HomanNativeBatchAudioItem] = []

        for (source, sourceURL) in sources {
            let samples = try AudioConverter().resampleAudioFile(sourceURL)
            let segments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(
                    minSpeechDuration: 0.15,
                    minSilenceDuration: 0.55,
                    maxSpeechDuration: 30,
                    speechPadding: 0.15
                )
            )
            for (index, segment) in segments
                .sorted(by: { $0.startTime < $1.startTime })
                .enumerated() {
                let startSample = max(
                    0,
                    min(samples.count, segment.startSample(sampleRate: VadManager.sampleRate))
                )
                let endSample = max(
                    startSample,
                    min(samples.count, segment.endSample(sampleRate: VadManager.sampleRate))
                )
                guard endSample > startSample else { continue }

                let wavURL = try WavWriter.writeTemporaryWAV(
                    samples: Array(samples[startSample..<endSample]),
                    directoryName: "muesli-homan-native-batch-probe"
                )
                let m4aURL = wavURL
                    .deletingPathExtension()
                    .appendingPathExtension("m4a")
                do {
                    try await HomanNativeM4AEncoder.encode(
                        wavURL: wavURL,
                        destinationURL: m4aURL
                    )
                } catch {
                    try? FileManager.default.removeItem(at: wavURL)
                    try? FileManager.default.removeItem(at: m4aURL)
                    throw error
                }

                let start = Double(startSample) / Double(VadManager.sampleRate)
                let end = Double(endSample) / Double(VadManager.sampleRate)
                let id = String(
                    format: "%@-%04d",
                    source.apiValue,
                    index
                )
                result.append(HomanNativeBatchAudioItem(
                    id: id,
                    source: source,
                    start: start,
                    end: end,
                    wavURL: wavURL,
                    fileURL: m4aURL,
                    byteCount: try fileSize(m4aURL)
                ))
            }
        }

        return HomanNativePreparedFixture(
            items: result,
            recordingDuration: recordingDuration,
            sourceCount: sources.count
        )
    }

    private static func audioDuration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else {
            throw HomanNativeBatchProbeError.invalidAudio
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try #require(values.fileSize)
    }
}

private struct HomanNativeBatchAudioItem: Sendable {
    let id: String
    let source: MeetingAudioSourceRole
    let start: Double
    let end: Double
    let wavURL: URL
    let fileURL: URL
    let byteCount: Int
}

private enum HomanProbeAudioFormat: Sendable {
    case m4a
    case wav

    init(environmentValue: String?) {
        self = environmentValue?.lowercased() == "wav" ? .wav : .m4a
    }

    func fileURL(for item: HomanNativeBatchAudioItem) -> URL {
        switch self {
        case .m4a: item.fileURL
        case .wav: item.wavURL
        }
    }

    var fileExtension: String {
        switch self {
        case .m4a: "m4a"
        case .wav: "wav"
        }
    }

    var contentType: String {
        switch self {
        case .m4a: "audio/mp4"
        case .wav: "audio/wav"
        }
    }
}

private extension MeetingAudioSourceRole {
    var apiValue: String {
        switch self {
        case .microphone: "microphone"
        case .system: "system"
        case .legacyMixed: "legacy_mixed"
        }
    }
}

private final class HomanNativeAssetWriterBox: @unchecked Sendable {
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

private enum HomanNativeM4AEncoder {
    static func encode(wavURL: URL, destinationURL: URL) async throws {
        let asset = AVURLAsset(url: wavURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw HomanNativeBatchProbeError.invalidAudio
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw HomanNativeBatchProbeError.couldNotCreateEncoder
        }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                // Apple AAC rejects 64 kbit/s at a 16 kHz container rate.
                // Encode at 32 kHz; the server normalizes to 16 kHz PCM.
                AVSampleRateKey: 32_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw HomanNativeBatchProbeError.couldNotCreateEncoder
        }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ??
                HomanNativeBatchProbeError.encodingFailed
        }
        writer.startSession(atSourceTime: .zero)

        let box = HomanNativeAssetWriterBox(
            reader: reader,
            output: output,
            writer: writer,
            input: input
        )
        let queue = DispatchQueue(label: "homan-native-aac-encoder")
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            box.input.requestMediaDataWhenReady(on: queue) {
                while box.input.isReadyForMoreMediaData,
                      !box.finishStarted {
                    if let sample = box.output.copyNextSampleBuffer() {
                        guard box.input.append(sample) else {
                            box.finishStarted = true
                            box.reader.cancelReading()
                            box.writer.cancelWriting()
                            continuation.resume(throwing: box.writer.error ??
                                HomanNativeBatchProbeError.encodingFailed)
                            return
                        }
                        continue
                    }

                    box.finishStarted = true
                    box.input.markAsFinished()
                    if box.reader.status == .failed ||
                        box.reader.status == .cancelled {
                        box.writer.cancelWriting()
                        continuation.resume(throwing: box.reader.error ??
                            HomanNativeBatchProbeError.encodingFailed)
                        return
                    }
                    box.writer.finishWriting {
                        if box.writer.status == .completed {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: box.writer.error ??
                                HomanNativeBatchProbeError.encodingFailed)
                        }
                    }
                }
            }
        }
    }
}

private enum HomanNativeBatchRequestBuilder {
    static func makeRequest(
        endpoint: URL,
        token: String,
        concurrency: Int,
        items: [HomanNativeBatchAudioItem],
        audioFormat: HomanProbeAudioFormat = .m4a
    ) throws -> URLRequest {
        let boundary = "homan-native-\(UUID().uuidString)"
        let requestID = UUID().uuidString
        let manifest = HomanNativeBatchManifest(
            schemaVersion: 1,
            requestID: requestID,
            options: .init(concurrency: concurrency),
            items: items.enumerated().map { index, item in
                .init(
                    id: item.id,
                    source: item.source.apiValue,
                    start: item.start,
                    end: item.end,
                    file: String(format: "audio_%04d", index)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)

        var body = Data()
        appendPart(
            name: "manifest",
            filename: "manifest.json",
            contentType: "application/json",
            data: manifestData,
            boundary: boundary,
            to: &body
        )
        for (index, item) in items.enumerated() {
            appendPart(
                name: String(format: "audio_%04d", index),
                filename: "\(item.id).\(audioFormat.fileExtension)",
                contentType: audioFormat.contentType,
                data: try Data(contentsOf: audioFormat.fileURL(for: item)),
                boundary: boundary,
                to: &body
            )
        }
        body.appendString("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30 * 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body
        return request
    }

    private static func appendPart(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String,
        to body: inout Data
    ) {
        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        )
        body.appendString("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n")
    }
}

private enum HomanOpenAITranscriptionRequestBuilder {
    static func makeRequest(
        endpoint: URL,
        token: String,
        item: HomanNativeBatchAudioItem,
        audioFormat: HomanProbeAudioFormat = .m4a,
        language: String = "auto"
    ) throws -> URLRequest {
        let boundary = "homan-openai-\(UUID().uuidString)"
        var body = Data()
        appendTextPart(
            name: "model",
            value: "large-v3-turbo",
            boundary: boundary,
            to: &body
        )
        appendTextPart(
            name: "language",
            value: language,
            boundary: boundary,
            to: &body
        )
        appendTextPart(
            name: "response_format",
            value: "verbose_json",
            boundary: boundary,
            to: &body
        )
        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(item.id).\(audioFormat.fileExtension)\"\r\n"
        )
        body.appendString("Content-Type: \(audioFormat.contentType)\r\n\r\n")
        body.append(try Data(contentsOf: audioFormat.fileURL(for: item)))
        body.appendString("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30 * 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body
        return request
    }

    private static func appendTextPart(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        )
        body.appendString("\(value)\r\n")
    }
}

private struct HomanNativeBatchManifest: Encodable {
    struct Options: Encodable {
        let concurrency: Int
    }

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

private struct HomanNativeBatchResponse: Decodable {
    struct Packing: Decodable {
        let enabled: Bool
        let reelCount: Int
        let maxReelSeconds: Double
        let separatorSeconds: Double
        let packedAudioDuration: Double
        let crossItemSegments: Int
        let fallbackItemCount: Int
        let fallbackProcessingMilliseconds: Double

        enum CodingKeys: String, CodingKey {
            case enabled
            case reelCount = "reel_count"
            case maxReelSeconds = "max_reel_seconds"
            case separatorSeconds = "separator_seconds"
            case packedAudioDuration = "packed_audio_duration"
            case crossItemSegments = "cross_item_segments"
            case fallbackItemCount = "fallback_item_count"
            case fallbackProcessingMilliseconds = "fallback_processing_ms"
        }
    }

    struct Item: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
        }

        let id: String
        let source: String
        let start: Double
        let end: Double
        let text: String
        let language: String
        let audioDuration: Double?
        let processingMilliseconds: Double?
        let segments: [Segment]?

        enum CodingKeys: String, CodingKey {
            case id
            case source
            case start
            case end
            case text
            case language
            case audioDuration = "audio_duration"
            case processingMilliseconds = "processing_ms"
            case segments
        }
    }

    let schemaVersion: Int
    let model: String
    let concurrencyUsed: Int
    let serverWallMilliseconds: Double
    let packing: Packing
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case model
        case concurrencyUsed = "concurrency_used"
        case serverWallMilliseconds = "server_wall_ms"
        case packing
        case items
    }
}

private struct HomanOpenAITranscriptionResponse: Decodable {
    let text: String
    let language: String?
}

private struct HomanNativeBatchProbeReport: Encodable {
    let recordingSeconds: Double
    let sourceTimelineSeconds: Double
    let speechSeconds: Double
    let itemCount: Int
    let encodedBytes: Int
    let multipartBytes: Int
    let requestedConcurrency: Int
    let usedConcurrency: Int
    let preparationSeconds: Double
    let requestSeconds: Double
    let serverSeconds: Double
    let totalSeconds: Double
    let packingReelCount: Int
    let packedAudioSeconds: Double
    let crossItemSegmentCount: Int
    let fallbackItemCount: Int
    let fallbackSeconds: Double
    let localBaselineSeconds: Double?
    let remoteSpeedupVersusLocal: Double?
    let responseDigest: String
    let formattedTurnCount: Int
    let formattedTranscriptCharacters: Int
    let formattedTranscriptDigest: String

    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

private struct HomanNativeBatchRequestDumpReport: Codable {
    let contentType: String
    let recordingSeconds: Double
    let speechSeconds: Double
    let itemCount: Int
    let multipartBytes: Int
    let requestedConcurrency: Int
}

private enum HomanComparisonConfiguration {
    static func apiKey(_ environment: [String: String]) throws -> String {
        let token: String
        if let keyFile = environment["HOMAN_STT_API_KEY_FILE"] {
            token = try String(contentsOfFile: keyFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = environment["HOMAN_STT_API_KEY"] ?? ""
        }
        guard !token.isEmpty else {
            throw HomanNativeBatchProbeError.missingAPIKey
        }
        return token
    }
}

private struct HomanWordDifference {
    let leftWordCount: Int
    let rightWordCount: Int
    let editDistance: Int
    let ratio: Double
}

private struct HomanComparableTranscript {
    let microphoneText: String
    let systemText: String
    let combinedText: String

    init(microphone: [SpeechSegment], system: [SpeechSegment]) {
        microphoneText = Self.orderedText(microphone)
        systemText = Self.orderedText(system)
        combinedText = (
            microphone.map { (sourceOrder: 0, segment: $0) } +
            system.map { (sourceOrder: 1, segment: $0) }
        )
        .sorted { lhs, rhs in
            if lhs.segment.start != rhs.segment.start {
                return lhs.segment.start < rhs.segment.start
            }
            if lhs.sourceOrder != rhs.sourceOrder {
                return lhs.sourceOrder < rhs.sourceOrder
            }
            if lhs.segment.end != rhs.segment.end {
                return lhs.segment.end < rhs.segment.end
            }
            return lhs.segment.text < rhs.segment.text
        }
        .map(\.segment.text)
        .joined(separator: " ")
    }

    var digest: String {
        SHA256.hash(data: Data(combinedText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func difference(from other: Self) -> HomanWordDifference {
        Self.wordDifference(combinedText, other.combinedText)
    }

    static func remoteSegments(
        _ items: [HomanNativeBatchResponse.Item]
    ) -> (microphone: [SpeechSegment], system: [SpeechSegment]) {
        let microphone = items.compactMap { item in
            item.source == MeetingAudioSourceRole.microphone.apiValue &&
                !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? SpeechSegment(start: item.start, end: item.end, text: item.text)
                : nil
        }
        let system = items.compactMap { item in
            item.source == MeetingAudioSourceRole.system.apiValue &&
                !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? SpeechSegment(start: item.start, end: item.end, text: item.text)
                : nil
        }
        return (microphone, system)
    }

    static func wordDifference(_ lhs: String, _ rhs: String) -> HomanWordDifference {
        let left = normalizedWords(lhs)
        let right = normalizedWords(rhs)
        let distance = levenshtein(left, right)
        return HomanWordDifference(
            leftWordCount: left.count,
            rightWordCount: right.count,
            editDistance: distance,
            ratio: Double(distance) / Double(max(left.count, right.count, 1))
        )
    }

    private static func orderedText(_ segments: [SpeechSegment]) -> String {
        segments.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.text < rhs.text
        }
        .map(\.text)
        .joined(separator: " ")
    }

    private static func normalizedWords(_ text: String) -> [String] {
        let allowed = CharacterSet.alphanumerics
        var normalized = ""
        for scalar in text
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .unicodeScalars {
            if allowed.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
            } else {
                normalized.append(" ")
            }
        }
        return normalized.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func levenshtein(_ lhs: [String], _ rhs: [String]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }

        var previous = Array(0 ... rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for (leftIndex, leftWord) in lhs.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightWord) in rhs.enumerated() {
                let substitution = previous[rightIndex] +
                    (leftWord == rightWord ? 0 : 1)
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}

private struct HomanLocalRemoteComparisonReport: Encodable {
    let recordingSeconds: Double
    let speechSeconds: Double
    let itemCount: Int
    let localWarmupSeconds: Double
    let localEndToEndSeconds: Double
    let remoteWarmupSeconds: Double
    let remotePreparationSeconds: Double
    let remoteRequestSeconds: Double
    let remoteServerSeconds: Double
    let remoteEndToEndSeconds: Double
    let localWordCount: Int
    let remoteWordCount: Int
    let wordEditDistance: Int
    let wordDifferenceRatio: Double
    let microphoneDifferenceRatio: Double
    let systemDifferenceRatio: Double
    let withinFivePercent: Bool
    let localDigest: String
    let remoteDigest: String

    func jsonLine() throws -> String {
        String(decoding: try JSONEncoder.sorted.encode(self), as: UTF8.self)
    }
}

private struct HomanExactTranscriptionItem: Sendable {
    let id: String
    let source: String
    let text: String
    let language: String?
}

private struct HomanExactItemDifference: Encodable {
    let id: String
    let source: String
    let audioSeconds: Double
    let localWordCount: Int
    let remoteWordCount: Int
    let editDistance: Int
    let differenceRatio: Double
}

private struct HomanExactPairMetrics: Encodable {
    let leftWordCount: Int
    let rightWordCount: Int
    let alignedEditDistance: Int
    let alignedDifferenceRatio: Double
    let concatenatedEditDistance: Int
    let concatenatedDifferenceRatio: Double
    let microphoneDifferenceRatio: Double
    let systemDifferenceRatio: Double
    let exactItemCount: Int
    let itemCountOverFivePercent: Int
    let emptyMismatchCount: Int
    let leftDigest: String
    let rightDigest: String
}

private struct HomanExactItemComparisonReport: Encodable {
    let itemCount: Int
    let preparationSeconds: Double
    let localWarmupSeconds: Double
    let localTranscriptionSeconds: Double
    let remoteWarmupSeconds: Double
    let remoteRequestSeconds: Double
    let remoteServerSeconds: Double
    let remoteConcurrencyUsed: Int
    let packedReelCount: Int
    let packedAudioSeconds: Double
    let crossItemSegmentCount: Int
    let fallbackItemCount: Int
    let missingLocalItemCount: Int
    let missingRemoteItemCount: Int
    let exactItemCount: Int
    let itemCountOverFivePercent: Int
    let emptyMismatchCount: Int
    let localWordCount: Int
    let remoteWordCount: Int
    let alignedEditDistance: Int
    let alignedDifferenceRatio: Double
    let concatenatedEditDistance: Int
    let concatenatedDifferenceRatio: Double
    let microphoneDifferenceRatio: Double
    let systemDifferenceRatio: Double
    let localDigest: String
    let remoteDigest: String
    let localLanguageCounts: [String: Int]
    let packedLanguageCounts: [String: Int]
    let isolatedLanguageCounts: [String: Int]?
    let localPackedLanguageAgreementCount: Int
    let localPackedLanguageComparableCount: Int
    let localIsolatedLanguageAgreementCount: Int?
    let localIsolatedLanguageComparableCount: Int?
    let packedIsolatedLanguageAgreementCount: Int?
    let packedIsolatedLanguageComparableCount: Int?
    let worstItems: [HomanExactItemDifference]
    let isolatedRemoteSeconds: Double?
    let localVersusIsolated: HomanExactPairMetrics?
    let packedVersusIsolated: HomanExactPairMetrics?

    func jsonLine() throws -> String {
        String(decoding: try JSONEncoder.sorted.encode(self), as: UTF8.self)
    }
}

private struct HomanLocalRepeatabilityReport: Encodable {
    let itemCount: Int
    let preparationSeconds: Double
    let warmupSeconds: Double
    let firstSeconds: Double
    let secondSeconds: Double
    let comparison: HomanExactPairMetrics

    func jsonLine() throws -> String {
        String(decoding: try JSONEncoder.sorted.encode(self), as: UTF8.self)
    }
}

private struct HomanWhisperCppPlatformReport: Encodable {
    let itemCount: Int
    let localWhisperCppSeconds: Double
    let localWhisperKitVersusLocalWhisperCpp: HomanExactPairMetrics
    let localWhisperCppVersusPackedRemote: HomanExactPairMetrics
    let localWhisperCppVersusIsolatedRemote: HomanExactPairMetrics?

    func jsonLine() throws -> String {
        String(decoding: try JSONEncoder.sorted.encode(self), as: UTF8.self)
    }
}

private struct HomanRemoteModesReport: Encodable {
    let itemCount: Int
    let preparationSeconds: Double
    let warmupSeconds: Double
    let batchRequestSeconds: Double
    let batchServerSeconds: Double
    let isolatedSeconds: Double
    let concurrencyUsed: Int
    let packingEnabled: Bool
    let reelCount: Int
    let fallbackItemCount: Int
    let comparison: HomanExactPairMetrics
    let diagnostics: HomanRemoteModeDiagnostics

    func jsonLine() throws -> String {
        String(decoding: try JSONEncoder.sorted.encode(self), as: UTF8.self)
    }
}

private struct HomanRemoteModeDiagnostics: Encodable {
    struct Selection: Encodable {
        let policy: String
        let selectedItemCount: Int
        let selectedAudioSeconds: Double
        let capturedEditDistance: Int
        let projectedDifferenceRatio: Double
    }

    struct Item: Encodable {
        let id: String
        let source: String
        let audioSeconds: Double
        let editDistance: Int
        let differenceRatio: Double
        let batchWordCount: Int
        let isolatedWordCount: Int
        let processingMilliseconds: Double?
        let segmentCount: Int
        let touchesBoundary: Bool
    }

    let alignedDenominator: Int
    let oracleMinimum: Selection
    let policies: [Selection]
    let worstItems: [Item]
}

private struct HomanWhisperCppJSONResponse: Decodable {
    struct Result: Decodable {
        let language: String?
    }

    struct Segment: Decodable {
        let text: String
    }

    let result: Result
    let transcription: [Segment]
}

private enum HomanExactItemComparator {
    static func cleanedRemoteItems(
        _ items: [HomanNativeBatchResponse.Item]
    ) -> [HomanNativeBatchResponse.Item] {
        items.map { item in
            HomanNativeBatchResponse.Item(
                id: item.id,
                source: item.source,
                start: item.start,
                end: item.end,
                text: cleanedText(item.text),
                language: item.language,
                audioDuration: item.audioDuration,
                processingMilliseconds: item.processingMilliseconds,
                segments: item.segments
            )
        }
    }

    static func cleanedRemoteItems(
        _ items: [HomanExactTranscriptionItem]
    ) -> [HomanExactTranscriptionItem] {
        items.map { item in
            HomanExactTranscriptionItem(
                id: item.id,
                source: item.source,
                text: cleanedText(item.text),
                language: item.language
            )
        }
    }

    static func transcribeLocally(
        _ items: [HomanNativeBatchAudioItem],
        coordinator: TranscriptionCoordinator
    ) async throws -> [HomanExactTranscriptionItem] {
        let microphoneItems = ordered(items.filter {
            $0.source == .microphone
        })
        let systemItems = ordered(items.filter {
            $0.source == .system
        })
        let legacyItems = ordered(items.filter {
            $0.source == .legacyMixed
        })

        async let microphone = transcribeSource(
            microphoneItems,
            coordinator: coordinator
        )
        async let system = transcribeSource(
            systemItems,
            coordinator: coordinator
        )
        async let legacy = transcribeSource(
            legacyItems,
            coordinator: coordinator
        )
        let (microphoneResult, systemResult, legacyResult) = try await (
            microphone,
            system,
            legacy
        )
        return microphoneResult + systemResult + legacyResult
    }

    static func transcribeLocallyWithWhisperCpp(
        _ items: [HomanNativeBatchAudioItem],
        binaryURL: URL,
        modelURL: URL,
        threads: Int
    ) throws -> [HomanExactTranscriptionItem] {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: binaryURL.path),
              fileManager.fileExists(atPath: modelURL.path) else {
            throw HomanNativeBatchProbeError.invalidWhisperCppConfiguration
        }

        let orderedItems = ordered(items)
        let outputURLs = orderedItems.map {
            URL(fileURLWithPath: $0.wavURL.path + ".json")
        }
        for outputURL in outputURLs {
            try? fileManager.removeItem(at: outputURL)
        }
        defer {
            for outputURL in outputURLs {
                try? fileManager.removeItem(at: outputURL)
            }
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "--model", modelURL.path,
            "--language", "auto",
            "--threads", String(threads),
            "--best-of", "5",
            "--beam-size", "1",
            "--output-json",
            "--no-prints",
        ] + orderedItems.map(\.wavURL.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw HomanNativeBatchProbeError.whisperCppFailed(
                process.terminationStatus
            )
        }

        return try zip(orderedItems, outputURLs).map { item, outputURL in
            let response = try JSONDecoder().decode(
                HomanWhisperCppJSONResponse.self,
                from: Data(contentsOf: outputURL)
            )
            return HomanExactTranscriptionItem(
                id: item.id,
                source: item.source.apiValue,
                text: response.transcription.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                language: response.result.language
            )
        }
    }

    static func makeWhisperCppPlatformReport(
        items: [HomanNativeBatchAudioItem],
        localWhisperKit: [HomanExactTranscriptionItem],
        localWhisperCpp: [HomanExactTranscriptionItem],
        packedRemote: [HomanNativeBatchResponse.Item],
        isolatedRemote: [HomanExactTranscriptionItem]?,
        localWhisperCppSeconds: Double
    ) -> HomanWhisperCppPlatformReport {
        let whisperKitTexts = Dictionary(uniqueKeysWithValues:
            localWhisperKit.map { ($0.id, $0.text) }
        )
        let localWhisperCppTexts = Dictionary(uniqueKeysWithValues:
            localWhisperCpp.map { ($0.id, $0.text) }
        )
        let packedRemoteTexts = Dictionary(uniqueKeysWithValues:
            packedRemote.map { ($0.id, $0.text) }
        )
        let isolatedRemoteTexts = isolatedRemote.map {
            Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0.text) })
        }
        return HomanWhisperCppPlatformReport(
            itemCount: items.count,
            localWhisperCppSeconds: localWhisperCppSeconds,
            localWhisperKitVersusLocalWhisperCpp: pairMetrics(
                items: items,
                left: whisperKitTexts,
                right: localWhisperCppTexts
            ),
            localWhisperCppVersusPackedRemote: pairMetrics(
                items: items,
                left: localWhisperCppTexts,
                right: packedRemoteTexts
            ),
            localWhisperCppVersusIsolatedRemote: isolatedRemoteTexts.map {
                pairMetrics(
                    items: items,
                    left: localWhisperCppTexts,
                    right: $0
                )
            }
        )
    }

    static func remoteModeDiagnostics(
        items: [HomanNativeBatchAudioItem],
        batch: [HomanNativeBatchResponse.Item],
        isolated: [HomanExactTranscriptionItem]
    ) -> HomanRemoteModeDiagnostics {
        let batchByID = Dictionary(uniqueKeysWithValues: batch.map {
            ($0.id, $0)
        })
        let isolatedByID = Dictionary(uniqueKeysWithValues: isolated.map {
            ($0.id, $0)
        })
        var denominator = 0
        var diagnosticItems: [HomanRemoteModeDiagnostics.Item] = []
        for item in ordered(items) {
            guard let batchItem = batchByID[item.id],
                  let isolatedItem = isolatedByID[item.id] else { continue }
            let difference = HomanComparableTranscript.wordDifference(
                batchItem.text,
                isolatedItem.text
            )
            denominator += max(
                difference.leftWordCount,
                difference.rightWordCount
            )
            let audioSeconds = item.end - item.start
            let segments = batchItem.segments ?? []
            let boundaryMargin = min(0.25, audioSeconds / 4)
            let touchesBoundary = segments.contains { segment in
                segment.start <= boundaryMargin ||
                    segment.end >= audioSeconds - boundaryMargin
            }
            diagnosticItems.append(HomanRemoteModeDiagnostics.Item(
                id: item.id,
                source: item.source.apiValue,
                audioSeconds: audioSeconds,
                editDistance: difference.editDistance,
                differenceRatio: difference.ratio,
                batchWordCount: difference.leftWordCount,
                isolatedWordCount: difference.rightWordCount,
                processingMilliseconds: batchItem.processingMilliseconds,
                segmentCount: segments.count,
                touchesBoundary: touchesBoundary
            ))
        }

        let totalEditDistance = diagnosticItems.reduce(0) {
            $0 + $1.editDistance
        }
        func selection(
            _ policy: String,
            where predicate: (HomanRemoteModeDiagnostics.Item) -> Bool
        ) -> HomanRemoteModeDiagnostics.Selection {
            let selected = diagnosticItems.filter(predicate)
            let captured = selected.reduce(0) { $0 + $1.editDistance }
            return HomanRemoteModeDiagnostics.Selection(
                policy: policy,
                selectedItemCount: selected.count,
                selectedAudioSeconds: selected.reduce(0.0) {
                    $0 + $1.audioSeconds
                },
                capturedEditDistance: captured,
                projectedDifferenceRatio: Double(
                    max(0, totalEditDistance - captured)
                ) / Double(max(denominator, 1))
            )
        }

        var policies: [HomanRemoteModeDiagnostics.Selection] = []
        for threshold in [0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0] {
            policies.append(selection("duration<=\(threshold)") {
                $0.audioSeconds <= threshold
            })
        }
        policies.append(selection("source=microphone") {
            $0.source == MeetingAudioSourceRole.microphone.apiValue
        })
        policies.append(selection("source=system") {
            $0.source == MeetingAudioSourceRole.system.apiValue
        })
        policies.append(selection("touches_boundary") { $0.touchesBoundary })
        policies.append(selection("segment_count=0") { $0.segmentCount == 0 })
        policies.append(selection("segment_count>=2") { $0.segmentCount >= 2 })
        for threshold in [1.0, 2.0, 3.0, 4.0] {
            policies.append(selection("batch_words_per_second>=\(threshold)") {
                Double($0.batchWordCount) /
                    max($0.audioSeconds, 0.001) >= threshold
            })
        }
        for threshold in [500.0, 750.0, 1_000.0, 1_500.0, 2_000.0] {
            policies.append(selection("processing_ms>=\(threshold)") {
                ($0.processingMilliseconds ?? 0) >= threshold
            })
        }
        policies.append(selection("microphone_and_boundary") {
            $0.source == MeetingAudioSourceRole.microphone.apiValue &&
                $0.touchesBoundary
        })
        policies.append(selection("microphone_and_duration<=5") {
            $0.source == MeetingAudioSourceRole.microphone.apiValue &&
                $0.audioSeconds <= 5
        })

        let oracleOrder = diagnosticItems.sorted { left, right in
            if left.editDistance != right.editDistance {
                return left.editDistance > right.editDistance
            }
            if left.differenceRatio != right.differenceRatio {
                return left.differenceRatio > right.differenceRatio
            }
            return left.id < right.id
        }
        var oracleCount = 0
        var oracleSeconds = 0.0
        var oracleCaptured = 0
        for item in oracleOrder where
            Double(max(0, totalEditDistance - oracleCaptured)) /
                Double(max(denominator, 1)) > 0.05 {
            oracleCount += 1
            oracleSeconds += item.audioSeconds
            oracleCaptured += item.editDistance
        }
        let oracle = HomanRemoteModeDiagnostics.Selection(
            policy: "oracle_highest_edit_first",
            selectedItemCount: oracleCount,
            selectedAudioSeconds: oracleSeconds,
            capturedEditDistance: oracleCaptured,
            projectedDifferenceRatio: Double(
                max(0, totalEditDistance - oracleCaptured)
            ) / Double(max(denominator, 1))
        )

        return HomanRemoteModeDiagnostics(
            alignedDenominator: denominator,
            oracleMinimum: oracle,
            policies: policies,
            worstItems: Array(oracleOrder.prefix(20))
        )
    }

    static func makeReport(
        prepared: [HomanNativeBatchAudioItem],
        local: [HomanExactTranscriptionItem],
        remote: [HomanNativeBatchResponse.Item],
        isolatedRemote: [HomanExactTranscriptionItem]?,
        isolatedRemoteSeconds: Double?,
        preparationSeconds: Double,
        localWarmupSeconds: Double,
        localTranscriptionSeconds: Double,
        remoteWarmupSeconds: Double,
        remoteRequestSeconds: Double,
        response: HomanNativeBatchResponse
    ) -> HomanExactItemComparisonReport {
        let orderedItems = ordered(prepared)
        let localByID = Dictionary(uniqueKeysWithValues: local.map {
            ($0.id, $0)
        })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map {
            ($0.id, $0)
        })
        let localTexts = localByID.mapValues(\.text)
        let remoteTexts = remoteByID.mapValues(\.text)
        let isolatedTexts = isolatedRemote.map {
            Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0.text) })
        }
        let localLanguages = Dictionary(uniqueKeysWithValues: local.compactMap {
            item in
            normalizedLanguage(item.language).map { (item.id, $0) }
        })
        let remoteLanguages = Dictionary(uniqueKeysWithValues: remote.compactMap {
            item in
            normalizedLanguage(item.language).map { (item.id, $0) }
        })
        let isolatedLanguages = isolatedRemote.map {
            Dictionary(uniqueKeysWithValues: $0.compactMap { item in
                normalizedLanguage(item.language).map { (item.id, $0) }
            })
        }
        let localPackedLanguageAgreement = languageAgreement(
            items: orderedItems,
            left: localLanguages,
            right: remoteLanguages
        )
        let localIsolatedLanguageAgreement = isolatedLanguages.map {
            languageAgreement(
                items: orderedItems,
                left: localLanguages,
                right: $0
            )
        }
        let packedIsolatedLanguageAgreement = isolatedLanguages.map {
            languageAgreement(
                items: orderedItems,
                left: remoteLanguages,
                right: $0
            )
        }
        let missingLocalItemCount = orderedItems.reduce(into: 0) {
            if localByID[$1.id] == nil { $0 += 1 }
        }
        let missingRemoteItemCount = orderedItems.reduce(into: 0) {
            if remoteByID[$1.id] == nil { $0 += 1 }
        }

        var differences: [HomanExactItemDifference] = []
        var localWordCount = 0
        var remoteWordCount = 0
        var alignedEditDistance = 0
        var alignedDenominator = 0
        var exactItemCount = 0
        var itemCountOverFivePercent = 0
        var emptyMismatchCount = 0
        for item in orderedItems {
            guard let localItem = localByID[item.id],
                  let remoteItem = remoteByID[item.id] else { continue }
            let difference = HomanComparableTranscript.wordDifference(
                localItem.text,
                remoteItem.text
            )
            localWordCount += difference.leftWordCount
            remoteWordCount += difference.rightWordCount
            alignedEditDistance += difference.editDistance
            alignedDenominator += max(
                difference.leftWordCount,
                difference.rightWordCount
            )
            if difference.editDistance == 0 {
                exactItemCount += 1
            }
            if difference.ratio > 0.05 {
                itemCountOverFivePercent += 1
            }
            if (difference.leftWordCount == 0) !=
                (difference.rightWordCount == 0) {
                emptyMismatchCount += 1
            }
            differences.append(HomanExactItemDifference(
                id: item.id,
                source: item.source.apiValue,
                audioSeconds: item.end - item.start,
                localWordCount: difference.leftWordCount,
                remoteWordCount: difference.rightWordCount,
                editDistance: difference.editDistance,
                differenceRatio: difference.ratio
            ))
        }

        let localText = joinedText(orderedItems, texts: localTexts)
        let remoteText = joinedText(orderedItems, texts: remoteTexts)
        let concatenated = HomanComparableTranscript.wordDifference(
            localText,
            remoteText
        )
        let microphone = sourceDifference(
            .microphone,
            items: orderedItems,
            local: localByID,
            remote: remoteByID
        )
        let system = sourceDifference(
            .system,
            items: orderedItems,
            local: localByID,
            remote: remoteByID
        )
        let worstItems = differences.sorted { lhs, rhs in
            if lhs.differenceRatio != rhs.differenceRatio {
                return lhs.differenceRatio > rhs.differenceRatio
            }
            if lhs.editDistance != rhs.editDistance {
                return lhs.editDistance > rhs.editDistance
            }
            return lhs.id < rhs.id
        }
        .prefix(12)

        return HomanExactItemComparisonReport(
            itemCount: orderedItems.count,
            preparationSeconds: preparationSeconds,
            localWarmupSeconds: localWarmupSeconds,
            localTranscriptionSeconds: localTranscriptionSeconds,
            remoteWarmupSeconds: remoteWarmupSeconds,
            remoteRequestSeconds: remoteRequestSeconds,
            remoteServerSeconds: response.serverWallMilliseconds / 1_000,
            remoteConcurrencyUsed: response.concurrencyUsed,
            packedReelCount: response.packing.reelCount,
            packedAudioSeconds: response.packing.packedAudioDuration,
            crossItemSegmentCount: response.packing.crossItemSegments,
            fallbackItemCount: response.packing.fallbackItemCount,
            missingLocalItemCount: missingLocalItemCount,
            missingRemoteItemCount: missingRemoteItemCount,
            exactItemCount: exactItemCount,
            itemCountOverFivePercent: itemCountOverFivePercent,
            emptyMismatchCount: emptyMismatchCount,
            localWordCount: localWordCount,
            remoteWordCount: remoteWordCount,
            alignedEditDistance: alignedEditDistance,
            alignedDifferenceRatio: Double(alignedEditDistance) /
                Double(max(alignedDenominator, 1)),
            concatenatedEditDistance: concatenated.editDistance,
            concatenatedDifferenceRatio: concatenated.ratio,
            microphoneDifferenceRatio: microphone.ratio,
            systemDifferenceRatio: system.ratio,
            localDigest: digest(orderedItems, texts: localTexts),
            remoteDigest: digest(orderedItems, texts: remoteTexts),
            localLanguageCounts: languageCounts(localLanguages),
            packedLanguageCounts: languageCounts(remoteLanguages),
            isolatedLanguageCounts: isolatedLanguages.map(languageCounts),
            localPackedLanguageAgreementCount:
                localPackedLanguageAgreement.agreements,
            localPackedLanguageComparableCount:
                localPackedLanguageAgreement.comparables,
            localIsolatedLanguageAgreementCount:
                localIsolatedLanguageAgreement?.agreements,
            localIsolatedLanguageComparableCount:
                localIsolatedLanguageAgreement?.comparables,
            packedIsolatedLanguageAgreementCount:
                packedIsolatedLanguageAgreement?.agreements,
            packedIsolatedLanguageComparableCount:
                packedIsolatedLanguageAgreement?.comparables,
            worstItems: Array(worstItems),
            isolatedRemoteSeconds: isolatedRemoteSeconds,
            localVersusIsolated: isolatedTexts.map {
                pairMetrics(items: orderedItems, left: localTexts, right: $0)
            },
            packedVersusIsolated: isolatedTexts.map {
                pairMetrics(items: orderedItems, left: remoteTexts, right: $0)
            }
        )
    }

    static func transcribeRemotelyIndividually(
        _ items: [HomanNativeBatchAudioItem],
        endpoint: URL,
        token: String,
        audioFormat: HomanProbeAudioFormat = .m4a,
        requestedLanguages: [String: String] = [:]
    ) async throws -> [HomanExactTranscriptionItem] {
        let orderedItems = ordered(items)
        var result: [HomanExactTranscriptionItem] = []
        result.reserveCapacity(orderedItems.count)
        for (index, item) in orderedItems.enumerated() {
            try Task.checkCancellation()
            let request = try HomanOpenAITranscriptionRequestBuilder.makeRequest(
                endpoint: endpoint,
                token: token,
                item: item,
                audioFormat: audioFormat,
                language: requestedLanguages[item.id] ?? "auto"
            )
            let (data, urlResponse) = try await URLSession.homanIntegration.data(
                for: request
            )
            let http = try #require(urlResponse as? HTTPURLResponse)
            guard http.statusCode == 200 else {
                throw HomanNativeBatchProbeError.httpStatus(http.statusCode)
            }
            let response = try JSONDecoder().decode(
                HomanOpenAITranscriptionResponse.self,
                from: data
            )
            result.append(HomanExactTranscriptionItem(
                id: item.id,
                source: item.source.apiValue,
                text: response.text,
                language: response.language
            ))
            if (index + 1).isMultiple(of: 16) || index + 1 == orderedItems.count {
                print("HOMAN_ITEM_COMPARE_PHASE isolated_remote_progress_\(index + 1)")
            }
        }
        return result
    }

    private static func transcribeSource(
        _ items: [HomanNativeBatchAudioItem],
        coordinator: TranscriptionCoordinator
    ) async throws -> [HomanExactTranscriptionItem] {
        var result: [HomanExactTranscriptionItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            try Task.checkCancellation()
            let transcription = try await coordinator.transcribeMeeting(
                at: item.wavURL,
                backend: .whisperLargeTurbo
            )
            result.append(HomanExactTranscriptionItem(
                id: item.id,
                source: item.source.apiValue,
                text: transcription.text,
                language: nil
            ))
        }
        return result
    }

    private static func ordered(
        _ items: [HomanNativeBatchAudioItem]
    ) -> [HomanNativeBatchAudioItem] {
        items.sorted { lhs, rhs in
            if lhs.source.apiValue != rhs.source.apiValue {
                return lhs.source.apiValue < rhs.source.apiValue
            }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.id < rhs.id
        }
    }

    private static func joinedText<T>(
        _ items: [HomanNativeBatchAudioItem],
        texts: [String: T],
        value: (T) -> String
    ) -> String {
        items.compactMap { texts[$0.id].map(value) }.joined(separator: " ")
    }

    private static func joinedText(
        _ items: [HomanNativeBatchAudioItem],
        texts: [String: String]
    ) -> String {
        joinedText(items, texts: texts) { $0 }
    }

    private static func sourceDifference(
        _ source: MeetingAudioSourceRole,
        items: [HomanNativeBatchAudioItem],
        local: [String: HomanExactTranscriptionItem],
        remote: [String: HomanNativeBatchResponse.Item]
    ) -> HomanWordDifference {
        let sourceItems = items.filter { $0.source == source }
        return HomanComparableTranscript.wordDifference(
            joinedText(sourceItems, texts: local) { $0.text },
            joinedText(sourceItems, texts: remote) { $0.text }
        )
    }

    static func pairMetrics(
        items: [HomanNativeBatchAudioItem],
        left: [String: String],
        right: [String: String]
    ) -> HomanExactPairMetrics {
        var leftWordCount = 0
        var rightWordCount = 0
        var alignedEditDistance = 0
        var alignedDenominator = 0
        var exactItemCount = 0
        var itemCountOverFivePercent = 0
        var emptyMismatchCount = 0
        for item in items {
            let difference = HomanComparableTranscript.wordDifference(
                left[item.id] ?? "",
                right[item.id] ?? ""
            )
            leftWordCount += difference.leftWordCount
            rightWordCount += difference.rightWordCount
            alignedEditDistance += difference.editDistance
            alignedDenominator += max(
                difference.leftWordCount,
                difference.rightWordCount
            )
            if difference.editDistance == 0 { exactItemCount += 1 }
            if difference.ratio > 0.05 { itemCountOverFivePercent += 1 }
            if (difference.leftWordCount == 0) !=
                (difference.rightWordCount == 0) {
                emptyMismatchCount += 1
            }
        }
        let concatenated = HomanComparableTranscript.wordDifference(
            joinedText(items, texts: left),
            joinedText(items, texts: right)
        )
        let microphoneItems = items.filter { $0.source == .microphone }
        let systemItems = items.filter { $0.source == .system }
        let microphone = HomanComparableTranscript.wordDifference(
            joinedText(microphoneItems, texts: left),
            joinedText(microphoneItems, texts: right)
        )
        let system = HomanComparableTranscript.wordDifference(
            joinedText(systemItems, texts: left),
            joinedText(systemItems, texts: right)
        )
        return HomanExactPairMetrics(
            leftWordCount: leftWordCount,
            rightWordCount: rightWordCount,
            alignedEditDistance: alignedEditDistance,
            alignedDifferenceRatio: Double(alignedEditDistance) /
                Double(max(alignedDenominator, 1)),
            concatenatedEditDistance: concatenated.editDistance,
            concatenatedDifferenceRatio: concatenated.ratio,
            microphoneDifferenceRatio: microphone.ratio,
            systemDifferenceRatio: system.ratio,
            exactItemCount: exactItemCount,
            itemCountOverFivePercent: itemCountOverFivePercent,
            emptyMismatchCount: emptyMismatchCount,
            leftDigest: digest(items, texts: left),
            rightDigest: digest(items, texts: right)
        )
    }

    private static func digest(
        _ items: [HomanNativeBatchAudioItem],
        texts: [String: String]
    ) -> String {
        let stableText = items.map {
            "\($0.id)\u{0}\(texts[$0.id] ?? "")"
        }.joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(stableText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func normalizedLanguage(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else { return nil }
        if value.count <= 3,
           let name = Locale(identifier: "en_US_POSIX")
            .localizedString(forLanguageCode: value.lowercased()) {
            return name.lowercased()
        }
        return value.lowercased()
    }

    private static func languageCounts(
        _ languages: [String: String]
    ) -> [String: Int] {
        languages.values.reduce(into: [:]) { counts, language in
            counts[language, default: 0] += 1
        }
    }

    private static func languageAgreement(
        items: [HomanNativeBatchAudioItem],
        left: [String: String],
        right: [String: String]
    ) -> (agreements: Int, comparables: Int) {
        var agreements = 0
        var comparables = 0
        for item in items {
            guard let leftLanguage = left[item.id],
                  let rightLanguage = right[item.id] else { continue }
            comparables += 1
            if leftLanguage == rightLanguage { agreements += 1 }
        }
        return (agreements, comparables)
    }

    private static func cleanedText(_ text: String) -> String {
        FillerWordFilter.apply(
            TranscriptionEngineArtifactsFilter.apply(text)
        )
    }
}

private enum HomanNativeBatchProbeError: Error {
    case couldNotCreateEncoder
    case encodingFailed
    case httpStatus(Int)
    case invalidAudio
    case invalidItemSelection
    case invalidWhisperCppConfiguration
    case missingAPIKey
    case whisperCppFailed(Int32)
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(contentsOf: value.utf8)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension URLSession {
    static let homanIntegration: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30 * 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

private extension Duration {
    var seconds: Double {
        let components = components
        return Double(components.seconds) +
            Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
