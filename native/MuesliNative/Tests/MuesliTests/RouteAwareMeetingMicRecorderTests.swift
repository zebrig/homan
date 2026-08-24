import CoreAudio
import Foundation
import Testing
import os
@testable import MuesliNativeApp

@Suite("RouteAwareMeetingMicRecorder", .serialized)
struct RouteAwareMeetingMicRecorderTests {
    @Test("default input uses system default recorder")
    func defaultInputUsesSystemDefaultRecorder() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        try recorder.prepare()
        try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.prepareCalls == 1)
        #expect(system.startCalls == 1)
        #expect(appScoped.prepareCalls == 0)
        #expect(appScoped.startCalls == 0)
    }

    @Test("preferred input uses app scoped recorder")
    func preferredInputUsesAppScopedRecorder() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        recorder.preferredInputDeviceID = 82
        try recorder.prepare()
        try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.prepareCalls == 0)
        #expect(system.startCalls == 0)
        #expect(appScoped.prepareCalls == 1)
        #expect(appScoped.startCalls == 1)
        #expect(appScoped.preferredInputDeviceID == 82)
    }

    @Test("callbacks from inactive recorder are ignored")
    func callbacksFromInactiveRecorderAreIgnored() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)
        var forwardedSamples: [[Int16]] = []
        var failureCount = 0
        recorder.onRawPCMSamples = { forwardedSamples.append($0) }
        recorder.onRecordingFailed = { _ in failureCount += 1 }

        try recorder.start()
        appScoped.onRawPCMSamples?([1, 2, 3])
        appScoped.onRecordingFailed?(NSError(domain: "RouteAwareMeetingMicRecorderTests", code: 1))
        system.onRawPCMSamples?([4, 5])

        #expect(forwardedSamples == [[4, 5]])
        #expect(failureCount == 0)
    }

    @Test("lifecycle delegates to active recorder and cancels inactive recorder on stop")
    func lifecycleDelegatesToActiveRecorderAndCancelsInactiveRecorderOnStop() throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let inactiveCancelled = DispatchSemaphore(value: 0)
        system.onCancel = { inactiveCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)
        recorder.preferredInputDeviceID = 91

        try recorder.start()
        recorder.pause()
        recorder.resume()
        _ = recorder.stop()

        #expect(appScoped.startCalls == 1)
        #expect(appScoped.pauseCalls == 1)
        #expect(appScoped.resumeCalls == 1)
        #expect(appScoped.stopCalls == 1)
        #expect(inactiveCancelled.wait(timeout: .now() + 5) == .success)
    }

    @Test("diagnostics include active recorder kind and route snapshot")
    func diagnosticsIncludeActiveRecorderKindAndRouteSnapshot() throws {
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let route = MeetingMicRouteDiagnosticsSnapshot(
            outputRouteKind: "headphone-like",
            outputIsAmbiguousBluetooth: false,
            selectedInputDeviceUID: "built-in",
            selectedInputDeviceResolved: true,
            preferredInputDeviceID: 82,
            preferredInputDeviceName: "MacBook Microphone",
            defaultInputDeviceID: 90,
            defaultInputDeviceName: "Headset Mic",
            builtInInputDeviceID: 82,
            systemDefaultInputIsBuiltIn: false
        )
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: appScoped,
            routeSnapshotProvider: { route }
        )
        recorder.preferredInputDeviceID = 82
        try recorder.start()

        let diagnostics = recorder.diagnosticsSnapshot()

        #expect(diagnostics.recorderKind == .appScopedAudioQueue)
        #expect(diagnostics.preferredInputDeviceID == 82)
        #expect(diagnostics.route == route)
    }

    @Test("live route change keeps old recorder until replacement produces audio")
    func liveRouteChangeWaitsForFirstBuffer() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: appScoped,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.startCalls == 1 }

        system.onRawPCMSamples?([1])
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.stopCalls == 0)

        appScoped.onRawPCMSamples?([2])
        try await waitUntil { recorder.activeRecorderKindForDebug() == .appScoped }
        try await waitUntil { samples == [[1], [2]] }

        #expect(samples == [[1], [2]])
        #expect(system.stopCalls == 1)
        #expect(system.cancelCalls == 1)
    }

    @Test("digital silence from a replacement never displaces the current microphone")
    func digitalSilenceDoesNotCompleteHandoff() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: appScoped,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        var chunks: [CapturedAudioChunk] = []
        recorder.onRawPCMSamples = { samples.append($0) }
        recorder.onNativeAudioChunk = { chunks.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.startCalls == 1 }

        appScoped.onRawPCMSamples?([0, 0])
        appScoped.onNativeAudioChunk?(makeFloatChunk([0, 0], timestamp: 1_000))
        system.onRawPCMSamples?([7])

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(recorder.routeTransitionSnapshot().phase == .switching)
        #expect(samples == [[7]])
        #expect(chunks.isEmpty)

        let liveChunk = makeFloatChunk([0.0002, 0], timestamp: 2_000)
        appScoped.onNativeAudioChunk?(liveChunk)
        try await waitUntil { recorder.activeRecorderKindForDebug() == .appScoped }
        try await waitUntil { chunks == [liveChunk] }

        #expect(recorder.routeTransitionSnapshot().phase == .stable)
        #expect(system.stopCalls == 1)
    }

    @Test("native-only capture preference survives a live route handoff")
    func nativeOnlyCapturePreferenceSurvivesHandoff() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: appScoped,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        let chunk = CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: 48_000,
                channelCount: 1,
                sampleRepresentation: .float32,
                interleaved: true
            ),
            frameCount: 2,
            timestamp: CapturedAudioTimestamp(
                monotonicNanoseconds: 1_000,
                origin: .sourceHostClock
            ),
            planes: [
                CapturedAudioPlane(
                    channelCount: 1,
                    data: [Float(0.1), Float(0.2)].withUnsafeBufferPointer {
                        Data(buffer: $0)
                    }
                ),
            ]
        )
        var forwardedChunks: [CapturedAudioChunk] = []
        recorder.onNativeAudioChunk = { forwardedChunks.append($0) }
        recorder.emitsProcessedAudio = false

        try recorder.start()
        #expect(!system.emitsProcessedAudio)

        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.startCalls == 1 }
        #expect(!appScoped.emitsProcessedAudio)

        appScoped.onNativeAudioChunk?(chunk)
        try await waitUntil { recorder.activeRecorderKindForDebug() == .appScoped }
        try await waitUntil { forwardedChunks == [chunk] }

        #expect(!recorder.emitsProcessedAudio)
        #expect(!appScoped.emitsProcessedAudio)
        #expect(system.stopCalls == 1)
    }

    @Test("automatic input change hands off between pinned physical devices")
    func automaticInputChangeHandsOffBetweenPhysicalDevices() async throws {
        let initial = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            appScopedRecorder: initial,
            appScopedRecorderFactory: { replacement },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        let chunk = CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: 48_000,
                channelCount: 1,
                sampleRepresentation: .float32,
                interleaved: true
            ),
            frameCount: 1,
            timestamp: CapturedAudioTimestamp(
                monotonicNanoseconds: 1_000,
                origin: .sourceHostClock
            ),
            planes: [
                CapturedAudioPlane(
                    channelCount: 1,
                    data: [Float(0.25)].withUnsafeBufferPointer {
                        Data(buffer: $0)
                    }
                ),
            ]
        )

        recorder.preferredInputDeviceID = 82
        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { replacement.startCalls == 1 }

        replacement.onNativeAudioChunk?(chunk)
        try await waitUntil { initial.stopCalls == 1 }

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(replacement.preferredInputDeviceID == 91)
        #expect(initial.stopCalls == 1)
        #expect(replacement.startCalls == 1)
    }

    @Test("route refresh rebuilds the same pinned physical device")
    func routeRefreshRebuildsSamePhysicalDevice() async throws {
        let initial = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            appScopedRecorder: initial,
            appScopedRecorderFactory: { replacement },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        recorder.preferredInputDeviceID = 82
        try recorder.start()
        recorder.preferredInputDeviceID = 82
        try await waitUntil { replacement.startCalls == 1 }

        initial.onRawPCMSamples?([1])
        replacement.onRawPCMSamples?([2])
        try await waitUntil { initial.stopCalls == 1 }

        #expect(replacement.preferredInputDeviceID == 82)
        #expect(recorder.routeTransitionSnapshot().phase == .stable)
    }

    @Test("failed live route change preserves current capture")
    func failedLiveRouteChangePreservesCurrentCapture() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let appScoped = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        appScoped.startError = NSError(domain: "test", code: 1)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: appScoped,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { appScoped.cancelCalls == 1 }
        system.onRawPCMSamples?([7])

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.stopCalls == 0)
        #expect(samples == [[7]])
    }

    @Test("failed handoff retries without dropping the current microphone")
    func failedHandoffRetriesInBackground() async throws {
        let retryScheduler = ManualMeetingMicHandoffTimeoutScheduler()
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let failed = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        failed.startError = NSError(domain: "test", code: 10)
        let recovered = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: failed,
            appScopedRecorderFactory: { recovered },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffRetryDelays: [0],
            handoffRetryScheduler: retryScheduler.schedule
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { failed.cancelCalls == 1 }
        system.onRawPCMSamples?([5])

        #expect(recorder.routeTransitionSnapshot().phase == .retrying)
        #expect(samples == [[5]])
        #expect(retryScheduler.fireNext())
        try await waitUntil { recovered.startCalls == 1 }

        recovered.onRawPCMSamples?([6])
        try await waitUntil { recorder.activeRecorderKindForDebug() == .appScoped }

        #expect(samples == [[5], [6]])
        #expect(recorder.routeTransitionSnapshot().phase == .stable)
        #expect(system.stopCalls == 1)
    }

    @Test("active recorder failure rebuilds the same route and recovers on first buffer")
    func activeFailureRebuildsSameRoute() async throws {
        let failed = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: failed,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: { replacement },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var failures = 0
        var samples: [[Int16]] = []
        recorder.onRecordingFailed = { _ in failures += 1 }
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        failed.onRecordingFailed?(NSError(domain: "test", code: 2))

        try await waitUntil { replacement.startCalls == 1 }
        #expect(recorder.isTerminallyFailedForDebug())
        #expect(failures == 1)

        replacement.onRawPCMSamples?([8, 9])
        try await waitUntil { !recorder.isTerminallyFailedForDebug() }
        try await waitUntil { samples == [[8, 9]] }
        try await waitUntil { failed.stopCalls == 1 }

        #expect(samples == [[8, 9]])
        #expect(failed.stopCalls == 1)
    }

    @Test("same route can retry after a terminal recovery failure")
    func sameRouteRetriesAfterTerminalFailure() async throws {
        let initial = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let failedReplacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        failedReplacement.startError = NSError(domain: "test", code: 3)
        let recoveredReplacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        var replacements = [failedReplacement, recoveredReplacement]
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: initial,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: { replacements.removeFirst() },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        try recorder.start()
        initial.onRecordingFailed?(NSError(domain: "test", code: 2))
        try await waitUntil { failedReplacement.cancelCalls == 1 }

        #expect(recorder.isTerminallyFailedForDebug())
        recorder.preferredInputDeviceID = nil
        try await waitUntil { recoveredReplacement.startCalls == 1 }
        recoveredReplacement.onRawPCMSamples?([3, 2, 0])
        try await waitUntil { !recorder.isTerminallyFailedForDebug() }
        try await waitUntil { initial.stopCalls == 1 }

        #expect(recoveredReplacement.startCalls == 1)
        #expect(initial.stopCalls == 1)
    }

    @Test("discard returns while a replacement start is blocked")
    func discardDoesNotWaitForBlockedReplacementStart() throws {
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        replacement.onCancel = { replacementCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var deliveredSamples: [[Int16]] = []
        recorder.onRawPCMSamples = { deliveredSamples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(startEntered.wait(timeout: .now() + 5) == .success)

        let startedAt = Date()
        recorder.cancel()
        let elapsed = Date().timeIntervalSince(startedAt)
        #expect(replacementCancelled.wait(timeout: .now() + 0.05) == .timedOut)
        allowStart.signal()

        #expect(elapsed < 0.2)
        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)
        replacement.onRawPCMSamples?([4, 2])
        #expect(deliveredSamples.isEmpty)
    }

    @Test("stop returns while a replacement start is blocked")
    func stopDoesNotWaitForBlockedReplacementStart() throws {
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        replacement.onCancel = { replacementCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        try recorder.start()
        recorder.preferredInputDeviceID = 93
        #expect(startEntered.wait(timeout: .now() + 5) == .success)

        let startedAt = Date()
        _ = recorder.stop()
        let elapsed = Date().timeIntervalSince(startedAt)
        #expect(replacementCancelled.wait(timeout: .now() + 0.05) == .timedOut)
        allowStart.signal()

        #expect(elapsed < 0.2)
        #expect(system.stopCalls == 1)
        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)
    }

    @Test("blocked replacement start is not multiplied by later route requests")
    func blockedReplacementStartDoesNotMultiplyPhysicalWorkers() throws {
        let lifecycleQueue = DispatchQueue(label: "test.route-aware-meeting.blocked-start-bound")
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let startReturned = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let factoryState = OSAllocatedUnfairLock(initialState: (count: 0, first: Optional<FakeMeetingMicRecorder>.none))
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorderFactory: {
                let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
                let index = factoryState.withLock { state -> Int in
                    state.count += 1
                    if state.first == nil {
                        state.first = replacement
                    }
                    return state.count
                }
                if index == 1 {
                    replacement.onStart = {
                        startEntered.signal()
                        _ = allowStart.wait(timeout: .now() + 10)
                        startReturned.signal()
                    }
                    replacement.onCancel = { replacementCancelled.signal() }
                }
                return replacement
            },
            lifecycleQueue: lifecycleQueue,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        try recorder.start()
        recorder.preferredInputDeviceID = 100
        #expect(startEntered.wait(timeout: .now() + 5) == .success)

        for offset in 1...100 {
            recorder.preferredInputDeviceID = AudioObjectID(100 + offset)
        }
        lifecycleQueue.sync {}

        let factoryCalls = factoryState.withLock { $0.count }
        #expect(factoryCalls == 1)

        recorder.cancel()
        allowStart.signal()
        #expect(startReturned.wait(timeout: .now() + 5) == .success)
        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)
    }

    @Test("blocked replacement prepare is not multiplied by later route requests")
    func blockedReplacementPrepareDoesNotMultiplyPhysicalWorkers() throws {
        let lifecycleQueue = DispatchQueue(label: "test.route-aware-meeting.blocked-prepare-bound")
        let startGate = MeetingMicHandoffStartGate()
        let prepareEntered = DispatchSemaphore(value: 0)
        let allowPrepare = DispatchSemaphore(value: 0)
        let prepareReturned = DispatchSemaphore(value: 0)
        let factoryCalls = OSAllocatedUnfairLock(initialState: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorderFactory: {
                let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
                let index = factoryCalls.withLock { count -> Int in
                    count += 1
                    return count
                }
                if index == 1 {
                    replacement.onPrepare = {
                        prepareEntered.signal()
                        _ = allowPrepare.wait(timeout: .now() + 10)
                        prepareReturned.signal()
                    }
                }
                return replacement
            },
            lifecycleQueue: lifecycleQueue,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffStartGate: startGate
        )

        try recorder.start()
        recorder.preferredInputDeviceID = 100
        #expect(prepareEntered.wait(timeout: .now() + 5) == .success)

        for offset in 1...100 {
            recorder.preferredInputDeviceID = AudioObjectID(100 + offset)
        }
        lifecycleQueue.sync {}

        #expect(factoryCalls.withLock { $0 } == 1)
        #expect(startGate.unfinishedLeaseCountForDebug() == 1)

        recorder.cancel()
        allowPrepare.signal()
        #expect(prepareReturned.wait(timeout: .now() + 5) == .success)
        waitUntilSynchronously { startGate.unfinishedLeaseCountForDebug() == 0 }
    }

    @Test("signal before physical start return promotes only after return")
    func signalBeforeStartReturnWaitsForPhysicalSuccess() throws {
        let startGate = MeetingMicHandoffStartGate()
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            replacement.onRawPCMSamples?([8])
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffStartGate: startGate
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(startEntered.wait(timeout: .now() + 5) == .success)
        system.onRawPCMSamples?([1])

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(samples == [[1]])

        allowStart.signal()
        waitUntilSynchronously { recorder.activeRecorderKindForDebug() == .appScoped }
        waitUntilSynchronously { samples == [[1], [8]] }

        #expect(samples == [[1], [8]])
        _ = recorder.stop()
    }

    @Test("superseded blocked start hands off to the latest route after physical return")
    func supersededBlockedStartContinuesWithLatestRoute() throws {
        let lifecycleQueue = DispatchQueue(label: "test.route-aware-meeting.latest-after-return")
        let startGate = MeetingMicHandoffStartGate()
        let firstStartEntered = DispatchSemaphore(value: 0)
        let allowFirstStart = DispatchSemaphore(value: 0)
        let first = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let second = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        first.onStart = {
            firstStartEntered.signal()
            _ = allowFirstStart.wait(timeout: .now() + 10)
        }
        var replacements = [first, second]
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorderFactory: { replacements.removeFirst() },
            lifecycleQueue: lifecycleQueue,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffStartGate: startGate
        )

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(firstStartEntered.wait(timeout: .now() + 5) == .success)
        recorder.preferredInputDeviceID = 92
        lifecycleQueue.sync {}

        #expect(second.startCalls == 0)
        #expect(startGate.unfinishedLeaseCountForDebug() == 1)

        allowFirstStart.signal()
        waitUntilSynchronously { second.startCalls == 1 }
        #expect(first.cancelCalls == 1)
        #expect(second.preferredInputDeviceID == 92)

        second.onRawPCMSamples?([4])
        waitUntilSynchronously { recorder.diagnosticsSnapshot().preferredInputDeviceID == 92 }
        _ = recorder.stop()
    }

    @Test("blocked A to B to A waits for B to return before refreshing A")
    func blockedRoundTripToActiveRouteRemainsBounded() throws {
        let lifecycleQueue = DispatchQueue(label: "test.route-aware-meeting.blocked-round-trip")
        let startGate = MeetingMicHandoffStartGate()
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let active = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let blocked = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let refreshedActive = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        blocked.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: active,
            appScopedRecorder: blocked,
            systemDefaultRecorderFactory: { refreshedActive },
            lifecycleQueue: lifecycleQueue,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffStartGate: startGate
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(startEntered.wait(timeout: .now() + 5) == .success)
        recorder.preferredInputDeviceID = nil
        lifecycleQueue.sync {}

        #expect(refreshedActive.prepareCalls == 0)
        #expect(refreshedActive.startCalls == 0)
        #expect(startGate.unfinishedLeaseCountForDebug() == 1)

        blocked.onRawPCMSamples?([9])
        active.onRawPCMSamples?([1])
        lifecycleQueue.sync {}
        #expect(samples == [[1]])
        #expect(active.stopCalls == 0)

        allowStart.signal()
        waitUntilSynchronously { refreshedActive.startCalls == 1 }
        #expect(blocked.cancelCalls == 1)
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)

        refreshedActive.onRawPCMSamples?([6])
        waitUntilSynchronously { active.stopCalls == 1 }
        _ = recorder.stop()
    }

    @Test("pause and resume cannot overtake a physically blocked replacement")
    func pauseResumeWaitsForBlockedReplacementReturn() throws {
        let startGate = MeetingMicHandoffStartGate()
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let first = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let second = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        first.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: first,
            appScopedRecorderFactory: { second },
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffStartGate: startGate
        )

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        #expect(startEntered.wait(timeout: .now() + 5) == .success)

        recorder.pause()
        recorder.resume()
        #expect(second.prepareCalls == 0)
        #expect(second.startCalls == 0)

        allowStart.signal()
        waitUntilSynchronously { second.startCalls == 1 }
        #expect(first.cancelCalls == 1)
        _ = recorder.stop()
    }

    @Test("two waiting owners re-register and start across successive lease releases")
    func twoWaitingOwnersEventuallyAcquireWithoutNewRouteEvents() throws {
        let startGate = MeetingMicHandoffStartGate()
        let blockerEntered = DispatchSemaphore(value: 0)
        let allowBlocker = DispatchSemaphore(value: 0)
        let waiterEntered = DispatchSemaphore(value: 0)
        let allowWaiter = DispatchSemaphore(value: 0)
        let blockerReplacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        blockerReplacement.onStart = {
            blockerEntered.signal()
            _ = allowBlocker.wait(timeout: .now() + 10)
        }
        let blocker = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: blockerReplacement,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffStartGate: startGate
        )

        let secondLifecycle = DispatchQueue(label: "test.route-aware-meeting.waiter.second")
        let thirdLifecycle = DispatchQueue(label: "test.route-aware-meeting.waiter.third")
        let secondTimeouts = ManualMeetingMicHandoffTimeoutScheduler()
        let thirdTimeouts = ManualMeetingMicHandoffTimeoutScheduler()
        let secondReplacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let thirdReplacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        for replacement in [secondReplacement, thirdReplacement] {
            replacement.onStart = {
                waiterEntered.signal()
                _ = allowWaiter.wait(timeout: .now() + 10)
            }
        }
        let second = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorderFactory: { secondReplacement },
            lifecycleQueue: secondLifecycle,
            handoffTimeoutScheduler: secondTimeouts.schedule,
            handoffStartGate: startGate
        )
        let third = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorderFactory: { thirdReplacement },
            lifecycleQueue: thirdLifecycle,
            handoffTimeoutScheduler: thirdTimeouts.schedule,
            handoffStartGate: startGate
        )

        try blocker.start()
        try second.start()
        try third.start()
        blocker.preferredInputDeviceID = 90
        #expect(blockerEntered.wait(timeout: .now() + 5) == .success)

        second.preferredInputDeviceID = 91
        third.preferredInputDeviceID = 92
        secondLifecycle.sync {}
        thirdLifecycle.sync {}

        #expect(startGate.waiterCountForDebug() == 2)
        #expect(second.routeTransitionSnapshot().attempt == 0)
        #expect(third.routeTransitionSnapshot().attempt == 0)
        #expect(secondTimeouts.scheduledCount == 0)
        #expect(thirdTimeouts.scheduledCount == 0)

        allowBlocker.signal()
        #expect(waiterEntered.wait(timeout: .now() + 5) == .success)
        waitUntilSynchronously {
            secondReplacement.startCalls + thirdReplacement.startCalls == 1
                && startGate.waiterCountForDebug() == 1
        }

        allowWaiter.signal()
        #expect(waiterEntered.wait(timeout: .now() + 5) == .success)
        allowWaiter.signal()
        waitUntilSynchronously {
            secondReplacement.startCalls == 1
                && thirdReplacement.startCalls == 1
                && startGate.unfinishedLeaseCountForDebug() == 0
        }

        blocker.cancel()
        second.cancel()
        third.cancel()
    }

    @Test("stopped gate waiter never starts after another owner releases")
    func stoppedGateWaiterIsCancelled() throws {
        let startGate = MeetingMicHandoffStartGate()
        let blockerEntered = DispatchSemaphore(value: 0)
        let allowBlocker = DispatchSemaphore(value: 0)
        let blockerReplacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        blockerReplacement.onStart = {
            blockerEntered.signal()
            _ = allowBlocker.wait(timeout: .now() + 10)
        }
        let blocker = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: blockerReplacement,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffStartGate: startGate
        )
        let waiterLifecycle = DispatchQueue(label: "test.route-aware-meeting.stopped-waiter")
        let waiterFactoryCalls = OSAllocatedUnfairLock(initialState: 0)
        let waiter = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorderFactory: {
                waiterFactoryCalls.withLock { $0 += 1 }
                return FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
            },
            lifecycleQueue: waiterLifecycle,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffStartGate: startGate
        )

        try blocker.start()
        try waiter.start()
        blocker.preferredInputDeviceID = 90
        #expect(blockerEntered.wait(timeout: .now() + 5) == .success)
        waiter.preferredInputDeviceID = 91
        waiterLifecycle.sync {}
        #expect(startGate.waiterCountForDebug() == 1)

        waiter.cancel()
        #expect(startGate.waiterCountForDebug() == 0)
        allowBlocker.signal()
        waitUntilSynchronously { startGate.unfinishedLeaseCountForDebug() == 0 }
        Thread.sleep(forTimeInterval: 0.05)

        #expect(waiterFactoryCalls.withLock { $0 } == 0)
        blocker.cancel()
    }

    @Test("owner deallocation after blocked start still cancels the candidate")
    func ownerDeallocationCleansUpReturnedCandidate() throws {
        let startGate = MeetingMicHandoffStartGate()
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        replacement.onCancel = { replacementCancelled.signal() }

        var recorder: RouteAwareMeetingMicRecorder? = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: replacement,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler,
            handoffStartGate: startGate
        )
        let weakRecorder = WeakRouteAwareMeetingMicRecorder(recorder)

        try recorder?.start()
        recorder?.preferredInputDeviceID = 91
        #expect(startEntered.wait(timeout: .now() + 5) == .success)

        recorder = nil
        #expect(weakRecorder.value == nil)
        allowStart.signal()

        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)
        waitUntilSynchronously { startGate.unfinishedLeaseCountForDebug() == 0 }
    }

    @Test("handoff timeout runs while replacement start is blocked")
    func handoffTimeoutBoundsBlockedReplacementStart() throws {
        let timeoutScheduler = ManualMeetingMicHandoffTimeoutScheduler()
        let startEntered = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let replacementCancelled = DispatchSemaphore(value: 0)
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        replacement.onStart = {
            startEntered.signal()
            _ = allowStart.wait(timeout: .now() + 10)
        }
        replacement.onCancel = { replacementCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: replacement,
            handoffTimeout: 0.05,
            handoffTimeoutScheduler: timeoutScheduler.schedule
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 92
        #expect(startEntered.wait(timeout: .now() + 5) == .success)
        #expect(timeoutScheduler.fireNext())
        #expect(replacementCancelled.wait(timeout: .now() + 0.05) == .timedOut)

        system.onRawPCMSamples?([7])
        allowStart.signal()
        #expect(replacementCancelled.wait(timeout: .now() + 5) == .success)
        replacement.onRawPCMSamples?([9])

        #expect(samples == [[7]])
        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
    }

    @Test("rapid route changes reject late callbacks from superseded recorders")
    func rapidRouteChangesRejectSupersededCallbacks() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let first = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let second = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        var replacements = [first, second]
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorderFactory: { replacements.removeFirst() },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { first.startCalls == 1 }
        recorder.preferredInputDeviceID = 92
        try await waitUntil { first.cancelCalls == 1 && second.startCalls == 1 }

        first.onRawPCMSamples?([1])
        system.onRawPCMSamples?([2])
        second.onRawPCMSamples?([3])
        try await waitUntil { recorder.diagnosticsSnapshot().preferredInputDeviceID == 92 }
        try await waitUntil { system.stopCalls == 1 }
        first.onRawPCMSamples?([4])

        #expect(samples == [[2], [3]])
        #expect(system.stopCalls == 1)
    }

    @Test("pause cancels a pending handoff and resume starts a fresh replacement")
    func pauseDuringPendingHandoffStartsFreshReplacementOnResume() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let pendingBeforePause = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let replacementAfterResume = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: pendingBeforePause,
            appScopedRecorderFactory: { replacementAfterResume },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { pendingBeforePause.startCalls == 1 }

        recorder.pause()
        try await waitUntil { pendingBeforePause.cancelCalls == 1 }
        pendingBeforePause.onRawPCMSamples?([1])
        recorder.resume()
        try await waitUntil { replacementAfterResume.startCalls == 1 }
        pendingBeforePause.onRawPCMSamples?([2])
        replacementAfterResume.onRawPCMSamples?([3])
        try await waitUntil { recorder.activeRecorderKindForDebug() == .appScoped }
        try await waitUntil { samples == [[3]] }

        #expect(samples == [[3]])
        #expect(system.pauseCalls == 1)
        #expect(system.resumeCalls == 1)
    }

    @Test("a pending handoff can recover an active recorder failure")
    func activeFailureUsesPendingHandoffForRecovery() async throws {
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let pending = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: pending,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var failures = 0
        var samples: [[Int16]] = []
        recorder.onRecordingFailed = { _ in failures += 1 }
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { pending.startCalls == 1 }
        system.onRecordingFailed?(NSError(domain: "test", code: 4))

        #expect(recorder.isTerminallyFailedForDebug())
        pending.onRawPCMSamples?([8])
        try await waitUntil { !recorder.isTerminallyFailedForDebug() }
        try await waitUntil { samples == [[8]] }

        #expect(failures == 1)
        #expect(samples == [[8]])
        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
    }

    @Test("stop remains correct when first-buffer promotion is already queued")
    func stopRacingQueuedFirstBufferPromotion() throws {
        let lifecycleQueue = DispatchQueue(label: "test.route-aware-meeting.stop-first-buffer-race")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let pending = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: pending,
            lifecycleQueue: lifecycleQueue,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        lifecycleQueue.sync {}
        waitUntilSynchronously { recorder.pendingStartHasReturnedForDebug() }

        var queueIsSuspended = true
        lifecycleQueue.suspend()
        defer {
            if queueIsSuspended { lifecycleQueue.resume() }
        }
        pending.onRawPCMSamples?([9])
        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = recorder.stop()
            stopReturned.signal()
        }
        #expect(stopReturned.wait(timeout: .now() + 0.02) == .timedOut)

        lifecycleQueue.resume()
        queueIsSuspended = false
        #expect(stopReturned.wait(timeout: .now() + 5) == .success)
        pending.onRawPCMSamples?([10])

        #expect(samples == [[9]])
        #expect(pending.stopCalls == 1)
        #expect(pending.cancelCalls == 1)
    }

    @Test("discard remains correct when first-buffer promotion is already queued")
    func discardRacingQueuedFirstBufferPromotion() throws {
        let lifecycleQueue = DispatchQueue(label: "test.route-aware-meeting.discard-first-buffer-race")
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let pending = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let pendingCancelled = DispatchSemaphore(value: 0)
        pending.onCancel = { pendingCancelled.signal() }
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorder: pending,
            lifecycleQueue: lifecycleQueue,
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        lifecycleQueue.sync {}
        waitUntilSynchronously { recorder.pendingStartHasReturnedForDebug() }

        var queueIsSuspended = true
        lifecycleQueue.suspend()
        defer {
            if queueIsSuspended { lifecycleQueue.resume() }
        }
        pending.onRawPCMSamples?([9])
        let discardReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            recorder.cancel()
            discardReturned.signal()
        }
        #expect(discardReturned.wait(timeout: .now() + 0.02) == .timedOut)

        lifecycleQueue.resume()
        queueIsSuspended = false
        #expect(discardReturned.wait(timeout: .now() + 5) == .success)
        #expect(pendingCancelled.wait(timeout: .now() + 5) == .success)
        pending.onRawPCMSamples?([10])

        #expect(samples == [[9]])
    }

    @Test("repeated handoff timeouts cannot promote stale recorders")
    func repeatedTimeoutsRecoverWithoutPromotingStaleRecorders() async throws {
        let timeoutScheduler = ManualMeetingMicHandoffTimeoutScheduler()
        let system = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let first = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let second = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let recovered = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        var replacements = [first, second, recovered]
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: system,
            appScopedRecorderFactory: { replacements.removeFirst() },
            handoffTimeout: 0.2,
            handoffTimeoutScheduler: timeoutScheduler.schedule
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        recorder.preferredInputDeviceID = 91
        try await waitUntil { first.startCalls == 1 }
        #expect(timeoutScheduler.fireNext())
        try await waitUntil { first.cancelCalls == 1 }
        recorder.preferredInputDeviceID = 92
        try await waitUntil { second.startCalls == 1 }
        #expect(timeoutScheduler.fireNext())
        try await waitUntil { second.cancelCalls == 1 }
        recorder.preferredInputDeviceID = 93
        try await waitUntil { recovered.startCalls == 1 }

        first.onRawPCMSamples?([1])
        second.onRawPCMSamples?([2])
        system.onRawPCMSamples?([3])
        recovered.onRawPCMSamples?([4])
        try await waitUntil { recorder.diagnosticsSnapshot().preferredInputDeviceID == 93 }
        try await waitUntil { samples == [[3], [4]] }

        #expect(samples == [[3], [4]])
        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
    }

    @Test("health recovery rebuilds the same route and waits for real signal")
    func healthRecoveryRebuildsSameRoute() async throws {
        let degraded = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        let replacement = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        var factoryCalls = 0
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: degraded,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: {
                factoryCalls += 1
                return replacement
            },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )
        var samples: [[Int16]] = []
        recorder.onRawPCMSamples = { samples.append($0) }

        try recorder.start()
        #expect(recorder.requestSameRouteRecovery(reason: "silent_graph"))
        try await waitUntil { replacement.startCalls == 1 }
        replacement.onRawPCMSamples?([0, 0])
        #expect(degraded.stopCalls == 0)
        replacement.onRawPCMSamples?([4, 5, 6])
        try await waitUntil { samples == [[4, 5, 6]] }
        try await waitUntil { degraded.stopCalls == 1 }

        #expect(factoryCalls == 1)
    }

    @Test("health recovery is ignored outside an active recording")
    func healthRecoveryRequiresActiveRecording() {
        var factoryCalls = 0
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: FakeMeetingMicRecorder(kind: .systemDefaultStreaming),
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: {
                factoryCalls += 1
                return FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
            }
        )

        #expect(!recorder.requestSameRouteRecovery(reason: "silent_graph"))
        #expect(factoryCalls == 0)
    }

    @Test("health recovery does not stack behind an in-flight handoff")
    func healthRecoveryDoesNotStack() async throws {
        let degraded = FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
        var factoryCalls = 0
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: degraded,
            appScopedRecorder: FakeMeetingMicRecorder(kind: .appScopedAudioQueue),
            systemDefaultRecorderFactory: {
                factoryCalls += 1
                return FakeMeetingMicRecorder(kind: .systemDefaultStreaming)
            },
            handoffTimeout: 1,
            handoffTimeoutScheduler: disabledMeetingMicHandoffTimeoutScheduler
        )

        try recorder.start()
        #expect(recorder.requestSameRouteRecovery(reason: "first"))
        #expect(!recorder.requestSameRouteRecovery(reason: "second"))
        try await waitUntil { factoryCalls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(factoryCalls == 1)
    }

    @Test("failed configuration-change restart marks the recorder inactive")
    func failedConfigurationChangeRestartMarksRecorderInactive() {
        var state = StreamingMicRecorderRunState()

        state.markStarted()
        #expect(state.isRunning)
        state.markConfigurationChangeRestartFailed()

        #expect(!state.isRunning)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for asynchronous recorder state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntilSynchronously(
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if !condition() {
            Issue.record("Timed out waiting for synchronous recorder state")
        }
    }
}

private final class WeakRouteAwareMeetingMicRecorder {
    weak var value: RouteAwareMeetingMicRecorder?

    init(_ value: RouteAwareMeetingMicRecorder?) {
        self.value = value
    }
}

private let disabledMeetingMicHandoffTimeoutScheduler: RouteAwareMeetingMicRecorder.HandoffTimeoutScheduler = {
    _, _ in
}

private func makeFloatChunk(_ samples: [Float], timestamp: UInt64) -> CapturedAudioChunk {
    CapturedAudioChunk(
        format: CapturedAudioFormat(
            sampleRate: 48_000,
            channelCount: 1,
            sampleRepresentation: .float32,
            interleaved: true
        ),
        frameCount: samples.count,
        timestamp: CapturedAudioTimestamp(
            monotonicNanoseconds: timestamp,
            origin: .sourceHostClock
        ),
        planes: [
            CapturedAudioPlane(
                channelCount: 1,
                data: samples.withUnsafeBufferPointer { Data(buffer: $0) }
            ),
        ]
    )
}

private final class ManualMeetingMicHandoffTimeoutScheduler {
    private let lock = NSLock()
    private var scheduledWorkItems: [DispatchWorkItem] = []

    func schedule(_ delay: TimeInterval, _ workItem: DispatchWorkItem) {
        lock.withLock {
            scheduledWorkItems.append(workItem)
        }
    }

    func fireNext() -> Bool {
        let workItem = lock.withLock { () -> DispatchWorkItem? in
            guard !scheduledWorkItems.isEmpty else { return nil }
            return scheduledWorkItems.removeFirst()
        }
        guard let workItem else { return false }
        workItem.perform()
        return true
    }

    var scheduledCount: Int {
        lock.withLock { scheduledWorkItems.count }
    }
}

private final class FakeMeetingMicRecorder: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onNativeAudioChunk: ((CapturedAudioChunk) -> Void)?
    var emitsProcessedAudio = true
    var onRecordingFailed: ((Error) -> Void)?

    let kind: MeetingMicRecorderKind
    var prepareCalls = 0
    var startCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var startError: Error?
    var onPrepare: (() -> Void)?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?

    init(kind: MeetingMicRecorderKind) {
        self.kind = kind
    }

    func prepare() throws {
        prepareCalls += 1
        onPrepare?()
    }

    func start() throws {
        startCalls += 1
        onStart?()
        if let startError { throw startError }
    }

    func pause() {
        pauseCalls += 1
    }

    func resume() {
        resumeCalls += 1
    }

    func stop() -> URL? {
        stopCalls += 1
        return nil
    }

    func cancel() {
        cancelCalls += 1
        onCancel?()
    }

    func currentPower() -> Float {
        -80
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: kind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }
}
