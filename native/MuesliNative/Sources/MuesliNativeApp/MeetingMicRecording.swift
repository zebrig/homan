import CoreAudio
import Foundation
import os

enum MeetingMicRecorderKind: String, Codable, Equatable {
    case systemDefaultStreaming
    case appScopedAudioQueue
}

struct MeetingMicRouteDiagnosticsSnapshot: Codable, Equatable {
    let outputRouteKind: String
    let outputIsAmbiguousBluetooth: Bool
    let selectedInputDeviceUID: String?
    let selectedInputDeviceResolved: Bool
    let preferredInputDeviceID: AudioObjectID?
    let preferredInputDeviceName: String?
    let defaultInputDeviceID: AudioObjectID?
    let defaultInputDeviceName: String?
    let builtInInputDeviceID: AudioObjectID?
    let systemDefaultInputIsBuiltIn: Bool
}

struct MeetingMicRecorderDiagnosticsSnapshot: Codable, Equatable {
    let recorderKind: MeetingMicRecorderKind
    let preferredInputDeviceID: AudioObjectID?
    let route: MeetingMicRouteDiagnosticsSnapshot?
}

enum MeetingMicRouteTransitionPhase: Equatable, Sendable {
    case stable
    case switching
    case retrying
    case failed
}

struct MeetingMicRouteTransitionSnapshot: Equatable, Sendable {
    let phase: MeetingMicRouteTransitionPhase
    let activeDeviceID: AudioObjectID?
    let activeDeviceName: String?
    let desiredDeviceID: AudioObjectID?
    let desiredDeviceName: String?
    let attempt: Int
}

protocol MeetingMicRecording: AnyObject {
    var preferredInputDeviceID: AudioObjectID? { get set }
    var onRawPCMSamples: (([Int16]) -> Void)? { get set }
    var onNativeAudioChunk: ((CapturedAudioChunk) -> Void)? { get set }
    var onRecordingFailed: ((Error) -> Void)? { get set }
    var emitsProcessedAudio: Bool { get set }

    func prepare() throws
    func start() throws
    func pause()
    func resume()
    func stop() -> URL?
    func cancel()
    func currentPower() -> Float
    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot
    func routeTransitionSnapshot() -> MeetingMicRouteTransitionSnapshot
    @discardableResult
    func requestSameRouteRecovery(reason: String) -> Bool
}

extension MeetingMicRecording {
    func routeTransitionSnapshot() -> MeetingMicRouteTransitionSnapshot {
        MeetingMicRouteTransitionSnapshot(
            phase: .stable,
            activeDeviceID: preferredInputDeviceID,
            activeDeviceName: nil,
            desiredDeviceID: preferredInputDeviceID,
            desiredDeviceName: nil,
            attempt: 0
        )
    }

    func requestSameRouteRecovery(reason: String) -> Bool { false }
}

final class StreamingMeetingMicRecorderAdapter: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID? {
        get { recorder.preferredInputDeviceID }
        set { recorder.preferredInputDeviceID = newValue }
    }
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onNativeAudioChunk: ((CapturedAudioChunk) -> Void)?
    var emitsProcessedAudio: Bool {
        get {
            (recorder as? ProcessedAudioEmissionControlling)?
                .emitsProcessedAudio ?? true
        }
        set {
            (recorder as? ProcessedAudioEmissionControlling)?
                .emitsProcessedAudio = newValue
        }
    }
    var onRecordingFailed: ((Error) -> Void)? {
        get { recorder.onRecordingFailed }
        set { recorder.onRecordingFailed = newValue }
    }

    private let recorder: StreamingDictationRecording
    private let kind: MeetingMicRecorderKind
    private let lock = OSAllocatedUnfairLock(initialState: false)

    init(
        recorder: StreamingDictationRecording,
        kind: MeetingMicRecorderKind
    ) {
        self.recorder = recorder
        self.kind = kind
        wireCallbacks()
    }

    func prepare() throws {
        try recorder.prepare()
    }

    func start() throws {
        lock.withLock { $0 = false }
        try recorder.start()
    }

    func pause() {
        lock.withLock { $0 = true }
        (recorder as? PausableStreamingDictationRecording)?.pause()
    }

    func resume() {
        lock.withLock { $0 = false }
        (recorder as? PausableStreamingDictationRecording)?.resume()
    }

    func stop() -> URL? {
        recorder.stop()
    }

    func cancel() {
        recorder.cancel()
    }

    func currentPower() -> Float {
        recorder.currentPower()
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: kind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }

    private func wireCallbacks() {
        recorder.onAudioBuffer = { [weak self] samples in
            guard let self else { return }
            guard !self.lock.withLock({ $0 }) else { return }
            let int16Samples = samples.map { sample -> Int16 in
                Int16(max(-1.0, min(1.0, sample)) * 32767)
            }
            self.onRawPCMSamples?(int16Samples)
        }
        (recorder as? NativeAudioChunkProviding)?.onNativeAudioChunk = { [weak self] chunk in
            self?.onNativeAudioChunk?(chunk)
        }
    }
}

final class RouteAwareMeetingMicRecorder: MeetingMicRecording, @unchecked Sendable {
    enum ActiveRecorderKind: Equatable { case systemDefault, appScoped }
    private enum LifecycleState { case idle, prepared, running, paused, failed, stopping }
    private struct Child {
        let id: UUID
        let generation: UInt64
        let kind: ActiveRecorderKind
        let recorder: MeetingMicRecording
        let deviceID: AudioObjectID?
        let resolvedDeviceID: AudioObjectID?
        let deviceName: String?
    }
    private enum CandidatePhysicalState: Equatable {
        case starting
        case returnedSuccess
        case returnedFailure
    }
    private enum CandidateSignal {
        case rawSamples([Int16])
        case nativeChunk(CapturedAudioChunk)
    }
    private enum CandidateReadinessState {
        case none
        case signal(CandidateSignal)
        case expired
    }
    private enum CandidateDisposition: Equatable {
        case eligible
        case superseded
        case paused
    }
    private struct HandoffCandidate {
        let child: Child
        var physicalState: CandidatePhysicalState = .starting
        var readinessState: CandidateReadinessState = .none
        var disposition: CandidateDisposition = .eligible
    }
    private enum CandidateResolution {
        case none
        case promoted(signal: CandidateSignal, old: Child?)
        case retired(candidate: Child, beginLatest: Bool)
        case failed(
            candidate: Child,
            isTerminalRecovery: Bool,
            retryDelay: TimeInterval?,
            generation: UInt64,
            error: Error
        )
    }
    typealias RecorderFactory = () -> MeetingMicRecording
    typealias HandoffTimeoutScheduler = (TimeInterval, DispatchWorkItem) -> Void
    typealias HandoffRetryScheduler = (TimeInterval, DispatchWorkItem) -> Void

    var preferredInputDeviceID: AudioObjectID? {
        get { lock.withLock { $0.preferredInputDeviceIDStorage } }
        set {
            let shouldHandoff = lock.withLock { state -> Bool in
                let changed = state.preferredInputDeviceIDStorage != newValue
                let shouldRefreshCurrentRoute = !changed
                    && state.lifecycleState == .running
                let shouldRetryFailedHandoff = state.transitionPhase == .failed
                    && state.lifecycleState == .running
                guard changed
                        || state.lifecycleState == .failed
                        || shouldRefreshCurrentRoute
                        || shouldRetryFailedHandoff else {
                    return false
                }
                if changed {
                    state.preferredInputDeviceIDStorage = newValue
                }
                guard state.lifecycleState == .running || state.lifecycleState == .failed else { return false }
                state.handoffAttempt = 0
                state.transitionPhase = .switching
                state.generation &+= 1
                return true
            }
            if shouldHandoff {
                lifecycleQueue.async { [weak self] in
                    self?.restartHandoffIfNeeded(force: true)
                }
            }
        }
    }
    var onRawPCMSamples: (([Int16]) -> Void)? {
        get { lock.withLock { $0.onRawPCMSamplesStorage } }
        set { lock.withLock { $0.onRawPCMSamplesStorage = newValue } }
    }
    var onRecordingFailed: ((Error) -> Void)? {
        get { lock.withLock { $0.onRecordingFailedStorage } }
        set { lock.withLock { $0.onRecordingFailedStorage = newValue } }
    }
    var onNativeAudioChunk: ((CapturedAudioChunk) -> Void)? {
        get { lock.withLock { $0.onNativeAudioChunkStorage } }
        set { lock.withLock { $0.onNativeAudioChunkStorage = newValue } }
    }
    var emitsProcessedAudio: Bool {
        get { lock.withLock { $0.emitsProcessedAudioStorage } }
        set {
            let recorders = lock.withLock { state -> [MeetingMicRecording] in
                state.emitsProcessedAudioStorage = newValue
                return [state.active?.recorder, state.pending?.child.recorder]
                    .compactMap { $0 }
            }
            recorders.forEach { $0.emitsProcessedAudio = newValue }
        }
    }

    private let systemDefaultRecorderFactory: RecorderFactory
    private let appScopedRecorderFactory: RecorderFactory
    private var seededSystemDefaultRecorder: MeetingMicRecording?
    private var seededAppScopedRecorder: MeetingMicRecording?
    private let routeSnapshotProvider: () -> MeetingMicRouteDiagnosticsSnapshot?
    private let lifecycleQueue: DispatchQueue
    private let handoffWorkerQueue: DispatchQueue
    private let cleanupQueue: DispatchQueue
    private let handoffTimeout: TimeInterval
    private let scheduleHandoffTimeout: HandoffTimeoutScheduler
    private let handoffRetryDelays: [TimeInterval]
    private let scheduleHandoffRetry: HandoffRetryScheduler
    private let handoffStartGate: MeetingMicHandoffStartGate
    private let handoffOwnerID = UUID()
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var preferredInputDeviceIDStorage: AudioObjectID?
        var lifecycleState: LifecycleState = .idle
        var active: Child?
        var pending: HandoffCandidate?
        var waitingForStartGate = false
        var generation: UInt64 = 0
        var handoffAttempt = 0
        var transitionPhase: MeetingMicRouteTransitionPhase = .stable
        var shouldRecoverOnResume = false
        var onRawPCMSamplesStorage: (([Int16]) -> Void)?
        var onNativeAudioChunkStorage: ((CapturedAudioChunk) -> Void)?
        var onRecordingFailedStorage: ((Error) -> Void)?
        var emitsProcessedAudioStorage = true
    }

    private var preferredInputDeviceIDStorage: AudioObjectID? {
        get { lock.withLock { $0.preferredInputDeviceIDStorage } }
        set { lock.withLock { $0.preferredInputDeviceIDStorage = newValue } }
    }
    private var lifecycleState: LifecycleState { lock.withLock { $0.lifecycleState } }
    private var onRawPCMSamplesStorage: (([Int16]) -> Void)? { lock.withLock { $0.onRawPCMSamplesStorage } }
    private var onNativeAudioChunkStorage: ((CapturedAudioChunk) -> Void)? {
        lock.withLock { $0.onNativeAudioChunkStorage }
    }
    private var onRecordingFailedStorage: ((Error) -> Void)? { lock.withLock { $0.onRecordingFailedStorage } }

    init(
        systemDefaultRecorder: MeetingMicRecording? = nil,
        appScopedRecorder: MeetingMicRecording? = nil,
        systemDefaultRecorderFactory: RecorderFactory? = nil,
        appScopedRecorderFactory: RecorderFactory? = nil,
        routeSnapshotProvider: @escaping () -> MeetingMicRouteDiagnosticsSnapshot? = { nil },
        lifecycleQueue: DispatchQueue = DispatchQueue(label: "com.muesli.route-aware-meeting-mic-recorder-lifecycle"),
        handoffWorkerQueue: DispatchQueue = DispatchQueue(
            label: "com.muesli.route-aware-meeting-mic-recorder-handoff",
            attributes: .concurrent
        ),
        cleanupQueue: DispatchQueue = DispatchQueue(
            label: "com.muesli.route-aware-meeting-mic-recorder-cleanup",
            attributes: .concurrent
        ),
        handoffTimeout: TimeInterval = 2,
        handoffTimeoutScheduler: HandoffTimeoutScheduler? = nil,
        handoffRetryDelays: [TimeInterval] = [0.5, 1.0],
        handoffRetryScheduler: HandoffRetryScheduler? = nil,
        handoffStartGate: MeetingMicHandoffStartGate = .shared
    ) {
        self.seededSystemDefaultRecorder = systemDefaultRecorder
        self.seededAppScopedRecorder = appScopedRecorder
        self.systemDefaultRecorderFactory = systemDefaultRecorderFactory ?? Self.makeSystemDefaultRecorder
        self.appScopedRecorderFactory = appScopedRecorderFactory ?? Self.makeAppScopedRecorder
        self.routeSnapshotProvider = routeSnapshotProvider
        self.lifecycleQueue = lifecycleQueue
        self.handoffWorkerQueue = handoffWorkerQueue
        self.cleanupQueue = cleanupQueue
        self.handoffTimeout = handoffTimeout
        self.handoffRetryDelays = handoffRetryDelays
        self.handoffStartGate = handoffStartGate
        self.scheduleHandoffTimeout = handoffTimeoutScheduler ?? { delay, workItem in
            lifecycleQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
        self.scheduleHandoffRetry = handoffRetryScheduler ?? { delay, workItem in
            lifecycleQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    func activeRecorderKindForDebug() -> ActiveRecorderKind {
        lock.withLock { $0.active?.kind ?? Self.kind(for: $0.preferredInputDeviceIDStorage) }
    }

    func isTerminallyFailedForDebug() -> Bool {
        lock.withLock { $0.lifecycleState == .failed }
    }

    func pendingStartHasReturnedForDebug() -> Bool {
        lock.withLock { $0.pending?.physicalState == .returnedSuccess }
    }

    func prepare() throws {
        try lifecycleQueue.sync {
            let child = try ensureCurrentChild()
            try child.recorder.prepare()
            lock.withLock { $0.lifecycleState = .prepared }
        }
    }

    func start() throws {
        try lifecycleQueue.sync {
            let child = try ensureCurrentChild()
            try child.recorder.start()
            lock.withLock {
                $0.lifecycleState = .running
                $0.handoffAttempt = 0
                $0.transitionPhase = .stable
            }
        }
    }

    func pause() {
        lifecycleQueue.sync {
            let result = lock.withLock { state -> (MeetingMicRecording?, Child?) in
                guard state.lifecycleState == .running || state.lifecycleState == .failed else { return (nil, nil) }
                state.shouldRecoverOnResume = state.lifecycleState == .failed
                state.lifecycleState = .paused
                state.generation &+= 1
                state.waitingForStartGate = false
                guard var pending = state.pending else {
                    return (state.active?.recorder, nil)
                }
                if pending.physicalState == .starting {
                    pending.disposition = .paused
                    state.pending = pending
                    return (state.active?.recorder, nil)
                }
                state.pending = nil
                return (state.active?.recorder, pending.child)
            }
            handoffStartGate.cancelWaiter(ownerID: handoffOwnerID)
            cancelAsync(result.1)
            result.0?.pause()
        }
    }

    func resume() {
        lifecycleQueue.sync {
            let result = lock.withLock { state -> (recorder: MeetingMicRecording?, shouldRecover: Bool)? in
                guard state.lifecycleState == .paused else { return nil }
                let shouldRecover = state.shouldRecoverOnResume
                state.shouldRecoverOnResume = false
                state.lifecycleState = shouldRecover ? .failed : .running
                return (state.active?.recorder, shouldRecover)
            }
            guard let result else { return }
            if result.shouldRecover {
                restartHandoffIfNeeded(force: true)
            } else {
                result.recorder?.resume()
                restartHandoffIfNeeded()
            }
        }
    }

    func stop() -> URL? {
        let resources = lifecycleQueue.sync { () -> (active: Child?, pending: Child?, unused: [MeetingMicRecording]) in
            let children = lock.withLock { state -> (Child?, Child?) in
                state.lifecycleState = .stopping
                state.generation &+= 1
                let pendingToCancel = state.pending.flatMap { pending in
                    pending.physicalState == .starting ? nil : pending.child
                }
                let result = (state.active, pendingToCancel)
                state.active = nil
                state.pending = nil
                state.waitingForStartGate = false
                state.shouldRecoverOnResume = false
                state.handoffAttempt = 0
                state.transitionPhase = .stable
                return result
            }
            return (children.0, children.1, takeUnusedSeedRecorders())
        }
        handoffStartGate.cancelWaiter(ownerID: handoffOwnerID)
        cancelAsync(resources.pending)
        cancelAsync(resources.unused)
        let url = resources.active?.recorder.stop()
        resources.active?.recorder.cancel()
        lock.withLock { $0.lifecycleState = .idle }
        return url
    }

    func cancel() {
        let resources = lifecycleQueue.sync { () -> (Child?, Child?, [MeetingMicRecording]) in
            let children = lock.withLock { state -> (Child?, Child?) in
                state.lifecycleState = .stopping
                state.generation &+= 1
                let pendingToCancel = state.pending.flatMap { pending in
                    pending.physicalState == .starting ? nil : pending.child
                }
                let result = (state.active, pendingToCancel)
                state.active = nil
                state.pending = nil
                state.waitingForStartGate = false
                state.shouldRecoverOnResume = false
                state.handoffAttempt = 0
                state.transitionPhase = .stable
                return result
            }
            lock.withLock { $0.lifecycleState = .idle }
            return (children.0, children.1, takeUnusedSeedRecorders())
        }
        handoffStartGate.cancelWaiter(ownerID: handoffOwnerID)
        cancelAsync(resources.0)
        cancelAsync(resources.1)
        cancelAsync(resources.2)
    }

    func currentPower() -> Float {
        lock.withLock { $0.active?.recorder }?.currentPower() ?? -160
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        let child = lock.withLock { $0.active }
        var snapshot = child?.recorder.diagnosticsSnapshot() ?? MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: Self.kind(for: preferredInputDeviceID).diagnosticsKind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
        if snapshot.route == nil {
            snapshot = MeetingMicRecorderDiagnosticsSnapshot(
                recorderKind: snapshot.recorderKind,
                preferredInputDeviceID: snapshot.preferredInputDeviceID,
                route: routeSnapshotProvider()
            )
        }
        return snapshot
    }

    func routeTransitionSnapshot() -> MeetingMicRouteTransitionSnapshot {
        let current = lock.withLock { state in
            (
                active: state.active,
                pending: state.pending?.child,
                preferredDeviceID: state.preferredInputDeviceIDStorage,
                phase: state.transitionPhase,
                attempt: state.handoffAttempt
            )
        }
        let desiredRoute: (deviceID: AudioObjectID?, deviceName: String?)
        if let pending = current.pending {
            desiredRoute = (pending.resolvedDeviceID, pending.deviceName)
        } else {
            desiredRoute = Self.routeIdentityChild(
                deviceID: current.preferredDeviceID,
                route: routeSnapshotProvider()
            )
        }
        return MeetingMicRouteTransitionSnapshot(
            phase: current.phase,
            activeDeviceID: current.active?.resolvedDeviceID,
            activeDeviceName: current.active?.deviceName,
            desiredDeviceID: desiredRoute.deviceID,
            desiredDeviceName: desiredRoute.deviceName,
            attempt: current.attempt
        )
    }

    @discardableResult
    func requestSameRouteRecovery(reason: String) -> Bool {
        lifecycleQueue.sync {
            let canStart = lock.withLock { state -> Bool in
                guard state.lifecycleState == .running || state.lifecycleState == .failed,
                      state.pending == nil,
                      !state.waitingForStartGate,
                      state.transitionPhase == .stable || state.transitionPhase == .failed else {
                    return false
                }
                state.handoffAttempt = 0
                state.transitionPhase = .switching
                state.generation &+= 1
                return true
            }
            guard canStart else { return false }
            fputs(
                "[meeting-mic] health-triggered same-route recovery requested: \(reason)\n",
                stderr
            )
            return beginHandoffIfNeeded(force: true)
        }
    }

    private func ensureCurrentChild() throws -> Child {
        let desired = preferredInputDeviceID
        if let active = lock.withLock({ $0.active }), active.deviceID == desired { return active }
        let previous = lock.withLock { state -> Child? in
            let old = state.active
            state.active = nil
            return old
        }
        previous?.recorder.cancel()
        let child = makeChild(deviceID: desired, generation: lock.withLock { $0.generation })
        lock.withLock { $0.active = child }
        return child
    }

    private func restartHandoffIfNeeded(force: Bool = false) {
        let transition = lock.withLock { state -> (stale: Child?, retainedStarting: Child?) in
            guard var pending = state.pending else { return (nil, nil) }
            if pending.physicalState == .starting {
                let didSupersede = pending.disposition == .eligible
                pending.disposition = .superseded
                state.pending = pending
                return (nil, didSupersede ? pending.child : nil)
            }
            state.pending = nil
            return (pending.child, nil)
        }
        if let retained = transition.retainedStarting {
            AudioLifecycleDiagnostics.emit(
                .info,
                operation: "mic_handoff_superseded",
                operationID: retained.id,
                generation: retained.generation,
                routeRole: Self.routeRole(for: retained.deviceID),
                deviceID: retained.deviceID,
                status: "waiting_for_physical_return"
            )
            return
        }
        cancelAsync(transition.stale)
        beginHandoffIfNeeded(force: force)
    }

    @discardableResult
    private func beginHandoffIfNeeded(force: Bool = false) -> Bool {
        let waitState = lock.withLock { state -> (eligible: Bool, shouldLog: Bool) in
            guard state.lifecycleState == .running || state.lifecycleState == .failed,
                  state.pending == nil,
                  force || state.active?.deviceID != state.preferredInputDeviceIDStorage else {
                return (false, false)
            }
            let shouldLog = !state.waitingForStartGate
            // Set this before touching the gate. A lease can be released and
            // dispatch its wake immediately after our waiter is registered;
            // the callback must never observe a false waiting state.
            state.waitingForStartGate = true
            return (true, shouldLog)
        }
        guard waitState.eligible else { return false }

        let acquisition = handoffStartGate.acquireOrWait(
            ownerID: handoffOwnerID,
            wake: { [weak self] in
                guard let self else { return }
                self.lifecycleQueue.async { [weak self] in
                    self?.restartHandoffAfterStartGateWake()
                }
            }
        )
        let lease: MeetingMicHandoffStartLease
        switch acquisition {
        case .acquired(let acquiredLease):
            lease = acquiredLease
        case .waiting(let blockingLeaseID):
            if waitState.shouldLog {
                AudioLifecycleDiagnostics.emit(
                    .notice,
                    operation: "mic_handoff_gate_wait",
                    operationID: blockingLeaseID,
                    generation: lock.withLock { $0.generation },
                    status: "replacement_start_busy"
                )
            }
            return false
        }

        let request = lock.withLock { state -> (AudioObjectID, UInt64, Int)? in
            state.waitingForStartGate = false
            guard state.lifecycleState == .running || state.lifecycleState == .failed,
                  state.pending == nil,
                  force || state.active?.deviceID != state.preferredInputDeviceIDStorage else { return nil }
            state.handoffAttempt += 1
            state.transitionPhase = state.handoffAttempt == 1 ? .switching : .retrying
            return (
                state.preferredInputDeviceIDStorage ?? kAudioObjectUnknown,
                state.generation,
                state.handoffAttempt
            )
        }
        guard let (encodedDeviceID, generation, _) = request else {
            lease.release()
            return false
        }
        let deviceID = encodedDeviceID == kAudioObjectUnknown ? nil : encodedDeviceID
        let child = makeChild(deviceID: deviceID, generation: generation, id: lease.id)
        let candidate = HandoffCandidate(child: child)
        let installed = lock.withLock { state -> Bool in
            guard state.generation == generation,
                  state.lifecycleState == .running || state.lifecycleState == .failed,
                  state.pending == nil else { return false }
            state.pending = candidate
            return true
        }
        guard installed else {
            lease.release()
            cancelAsync(child)
            lifecycleQueue.async { [weak self] in
                self?.restartHandoffIfNeeded(force: true)
            }
            return false
        }

        AudioLifecycleDiagnostics.emit(
            .info,
            operation: "mic_handoff_start_begin",
            operationID: child.id,
            generation: generation,
            routeRole: Self.routeRole(for: deviceID),
            deviceID: deviceID,
            status: "starting"
        )

        // Schedule the wall-clock deadline before starting the graph. CoreAudio
        // can block inside AudioQueueStart, so a timeout scheduled afterward is
        // not a real bound and can also hold stop/discard behind it.
        scheduleHandoffTimeout(
            handoffTimeout,
            DispatchWorkItem { [weak self] in
                self?.expirePendingHandoff(
                    candidateID: child.id,
                    generation: generation,
                    error: NSError(domain: "MeetingMicrophoneRoute", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "The selected microphone did not produce audio."
                    ])
                )
            }
        )
        let lifecycleQueue = self.lifecycleQueue
        let cleanupQueue = self.cleanupQueue
        handoffWorkerQueue.async { [weak self, lease] in
            defer { lease.release() }
            let result: Result<Void, Error>
            do {
                try child.recorder.prepare()
                try child.recorder.start()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            let didSucceed: Bool
            switch result {
            case .success:
                didSucceed = true
            case .failure:
                didSucceed = false
            }

            AudioLifecycleDiagnostics.emit(
                didSucceed ? .info : .error,
                operation: "mic_handoff_start_return",
                operationID: child.id,
                generation: generation,
                routeRole: Self.routeRole(for: deviceID),
                deviceID: deviceID,
                durationMilliseconds: AudioLifecycleDiagnostics.elapsedMilliseconds(
                    since: lease.startedAtNanoseconds
                ),
                status: didSucceed ? "success" : "failure"
            )

            if let owner = self,
               owner.isCurrentCandidate(childID: child.id, generation: generation)
            {
                lifecycleQueue.async {
                    owner.handleCandidateStartResult(
                        result,
                        candidate: child
                    )
                }
            } else {
                Self.cancelDetachedCandidate(child, on: cleanupQueue)
            }
        }
        return true
    }

    private func isCurrentCandidate(childID: UUID, generation: UInt64) -> Bool {
        lock.withLock { state in
            state.pending?.child.id == childID
                && state.pending?.child.generation == generation
        }
    }

    private func restartHandoffAfterStartGateWake() {
        let shouldRestart = lock.withLock { state -> Bool in
            guard state.waitingForStartGate else { return false }
            state.waitingForStartGate = false
            return state.lifecycleState == .running || state.lifecycleState == .failed
        }
        guard shouldRestart else { return }
        beginHandoffIfNeeded(force: true)
    }

    private func makeChild(
        deviceID: AudioObjectID?,
        generation: UInt64,
        id: UUID = UUID()
    ) -> Child {
        let kind = Self.kind(for: deviceID)
        let recorder: MeetingMicRecording
        switch kind {
        case .systemDefault:
            recorder = seededSystemDefaultRecorder ?? systemDefaultRecorderFactory()
            seededSystemDefaultRecorder = nil
        case .appScoped:
            recorder = seededAppScopedRecorder ?? appScopedRecorderFactory()
            seededAppScopedRecorder = nil
        }
        recorder.preferredInputDeviceID = deviceID
        recorder.emitsProcessedAudio = lock.withLock {
            $0.emitsProcessedAudioStorage
        }
        let identity = Self.routeIdentityChild(
            deviceID: deviceID,
            route: routeSnapshotProvider()
        )
        let child = Child(
            id: id,
            generation: generation,
            kind: kind,
            recorder: recorder,
            deviceID: deviceID,
            resolvedDeviceID: identity.deviceID,
            deviceName: identity.deviceName
        )
        recorder.onRawPCMSamples = { [weak self] samples in self?.receive(samples, from: child.id) }
        recorder.onNativeAudioChunk = { [weak self] chunk in self?.receive(chunk, from: child.id) }
        recorder.onRecordingFailed = { [weak self] error in self?.receive(error, from: child.id) }
        return child
    }

    private func receive(_ samples: [Int16], from childID: UUID) {
        let role = lock.withLock { state -> (isActive: Bool, isPending: Bool, UInt64) in
            (
                state.active?.id == childID,
                state.pending?.child.id == childID,
                state.pending?.child.generation ?? state.generation
            )
        }
        if role.isActive {
            onRawPCMSamplesStorage?(samples)
        } else if role.isPending {
            guard samples.contains(where: { $0 != 0 }) else { return }
            lifecycleQueue.async { [weak self] in
                self?.recordCandidateSignal(
                    .rawSamples(samples),
                    childID: childID,
                    generation: role.2
                )
            }
        }
    }

    private func receive(_ error: Error, from childID: UUID) {
        let role = lock.withLock { state -> (
            isActive: Bool,
            isPending: Bool,
            generation: UInt64,
            failureHandler: ((Error) -> Void)?,
            shouldRecover: Bool
        ) in
            if state.pending?.child.id == childID {
                return (false, true, state.pending?.child.generation ?? state.generation, nil, false)
            }
            guard state.active?.id == childID else {
                return (false, false, state.generation, nil, false)
            }
            if state.lifecycleState == .paused {
                guard !state.shouldRecoverOnResume else {
                    return (false, false, state.generation, nil, false)
                }
                state.shouldRecoverOnResume = true
                return (true, false, state.generation, state.onRecordingFailedStorage, false)
            }
            guard state.lifecycleState == .running else {
                return (false, false, state.generation, nil, false)
            }
            state.lifecycleState = .failed
            let shouldRecover = state.pending == nil && !state.waitingForStartGate
            if shouldRecover {
                state.generation &+= 1
                state.handoffAttempt = 0
                state.transitionPhase = .switching
            }
            return (true, false, state.generation, state.onRecordingFailedStorage, shouldRecover)
        }
        if role.isActive {
            role.failureHandler?(error)
            if role.shouldRecover {
                lifecycleQueue.async { [weak self] in
                    self?.beginHandoffIfNeeded(force: true)
                }
            }
        } else if role.isPending {
            lifecycleQueue.async { [weak self] in
                self?.expirePendingHandoff(
                    candidateID: childID,
                    generation: role.generation,
                    error: error
                )
            }
        }
    }

    private func receive(_ chunk: CapturedAudioChunk, from childID: UUID) {
        let role = lock.withLock { state -> (isActive: Bool, isPending: Bool, UInt64) in
            (
                state.active?.id == childID,
                state.pending?.child.id == childID,
                state.pending?.child.generation ?? state.generation
            )
        }
        if role.isActive {
            onNativeAudioChunkStorage?(chunk)
        } else if role.isPending {
            guard chunk.containsInputSignal() else { return }
            lifecycleQueue.async { [weak self] in
                self?.recordCandidateSignal(
                    .nativeChunk(chunk),
                    childID: childID,
                    generation: role.2
                )
            }
        }
    }

    private func recordCandidateSignal(
        _ signal: CandidateSignal,
        childID: UUID,
        generation: UInt64
    ) {
        let recorded = lock.withLock { state -> Bool in
            guard var pending = state.pending,
                  pending.child.id == childID,
                  pending.child.generation == generation,
                  pending.disposition == .eligible else { return false }
            guard case .none = pending.readinessState else { return false }
            pending.readinessState = .signal(signal)
            state.pending = pending
            return true
        }
        guard recorded else { return }
        resolvePendingCandidate(childID: childID)
    }

    private func handleCandidateStartResult(
        _ result: Result<Void, Error>,
        candidate: Child
    ) {
        switch result {
        case .success:
            let resolution = lock.withLock { state -> CandidateResolution in
                guard var pending = state.pending,
                      pending.child.id == candidate.id,
                      pending.child.generation == candidate.generation else {
                    return .retired(candidate: candidate, beginLatest: false)
                }
                pending.physicalState = .returnedSuccess
                state.pending = pending
                return .none
            }
            apply(resolution)
            resolvePendingCandidate(childID: candidate.id)
        case .failure(let error):
            let resolution = lock.withLock { state -> CandidateResolution in
                guard var pending = state.pending,
                      pending.child.id == candidate.id,
                      pending.child.generation == candidate.generation else {
                    return .retired(candidate: candidate, beginLatest: false)
                }
                pending.physicalState = .returnedFailure
                state.pending = pending
                if pending.disposition != .eligible
                    || state.generation != candidate.generation
                    || !(state.lifecycleState == .running || state.lifecycleState == .failed)
                {
                    state.pending = nil
                    let canBeginLatest = state.lifecycleState == .running || state.lifecycleState == .failed
                    return .retired(candidate: pending.child, beginLatest: canBeginLatest)
                }
                return makeFailureResolutionLocked(state: &state, error: error)
            }
            apply(resolution)
        }
    }

    private func expirePendingHandoff(candidateID: UUID, generation: UInt64, error: Error) {
        let result = lock.withLock { state -> (changed: Bool, physicalReturned: Bool) in
            guard var pending = state.pending,
                  pending.child.id == candidateID,
                  pending.child.generation == generation else { return (false, false) }
            guard case .none = pending.readinessState else { return (false, false) }
            pending.readinessState = .expired
            state.pending = pending
            let retryIndex = state.handoffAttempt - 1
            state.transitionPhase = handoffRetryDelays.indices.contains(retryIndex) ? .retrying : .failed
            return (true, pending.physicalState != .starting)
        }
        guard result.changed else { return }
        AudioLifecycleDiagnostics.emit(
            .notice,
            operation: "mic_handoff_readiness_timeout",
            operationID: candidateID,
            generation: generation,
            status: result.physicalReturned ? "start_returned" : "start_still_running"
        )
        if result.physicalReturned {
            resolvePendingCandidate(childID: candidateID, failureError: error)
        }
    }

    private func resolvePendingCandidate(
        childID: UUID,
        failureError: Error = NSError(
            domain: "MeetingMicrophoneRoute",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The selected microphone did not produce audio."]
        )
    ) {
        let resolution = lock.withLock { state -> CandidateResolution in
            guard let pending = state.pending,
                  pending.child.id == childID,
                  pending.physicalState == .returnedSuccess else { return .none }

            if pending.disposition != .eligible
                || state.generation != pending.child.generation
                || !(state.lifecycleState == .running || state.lifecycleState == .failed)
            {
                state.pending = nil
                let canBeginLatest = state.lifecycleState == .running || state.lifecycleState == .failed
                return .retired(candidate: pending.child, beginLatest: canBeginLatest)
            }

            switch pending.readinessState {
            case .none:
                return .none
            case .expired:
                return makeFailureResolutionLocked(state: &state, error: failureError)
            case .signal(let signal):
                let old = state.active
                state.active = pending.child
                state.pending = nil
                state.lifecycleState = .running
                state.handoffAttempt = 0
                state.transitionPhase = .stable
                return .promoted(signal: signal, old: old)
            }
        }
        apply(resolution)
    }

    private func makeFailureResolutionLocked(
        state: inout State,
        error: Error
    ) -> CandidateResolution {
        guard let pending = state.pending else { return .none }
        state.pending = nil
        let retryIndex = state.handoffAttempt - 1
        let retryDelay = handoffRetryDelays.indices.contains(retryIndex)
            ? handoffRetryDelays[retryIndex]
            : nil
        state.transitionPhase = retryDelay == nil ? .failed : .retrying
        return .failed(
            candidate: pending.child,
            isTerminalRecovery: state.lifecycleState == .failed,
            retryDelay: retryDelay,
            generation: pending.child.generation,
            error: error
        )
    }

    private func apply(_ resolution: CandidateResolution) {
        switch resolution {
        case .none:
            return
        case .promoted(let signal, let old):
            AudioLifecycleDiagnostics.emit(
                .info,
                operation: "mic_handoff_promoted",
                operationID: lock.withLock { $0.active?.id },
                generation: lock.withLock { $0.generation },
                status: "signal_ready"
            )
            switch signal {
            case .rawSamples(let samples):
                onRawPCMSamplesStorage?(samples)
            case .nativeChunk(let chunk):
                onNativeAudioChunkStorage?(chunk)
            }
            retireAfterHandoffAsync(old)
        case .retired(let candidate, let beginLatest):
            cancelAsync(candidate)
            if beginLatest {
                beginHandoffIfNeeded(force: true)
            }
        case .failed(let candidate, let isTerminalRecovery, let retryDelay, let generation, let error):
            cancelAsync(candidate)
            let outcome = isTerminalRecovery
                ? "microphone recovery failed"
                : "microphone handoff failed; continuing current route"
            fputs("[meeting-mic] \(outcome): \(error)\n", stderr)
            AudioLifecycleDiagnostics.emit(
                .error,
                operation: "mic_handoff_failed",
                operationID: candidate.id,
                generation: generation,
                routeRole: Self.routeRole(for: candidate.deviceID),
                deviceID: candidate.deviceID,
                status: isTerminalRecovery ? "terminal_recovery" : "active_preserved"
            )
            guard let retryDelay else { return }
            scheduleHandoffRetry(
                retryDelay,
                DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let shouldRetry = self.lock.withLock { state in
                        state.generation == generation
                            && state.pending == nil
                            && (state.lifecycleState == .running || state.lifecycleState == .failed)
                    }
                    guard shouldRetry else { return }
                    self.beginHandoffIfNeeded(force: true)
                }
            )
        }
    }

    private static func routeIdentityChild(
        deviceID: AudioObjectID?,
        route: MeetingMicRouteDiagnosticsSnapshot?
    ) -> (deviceID: AudioObjectID?, deviceName: String?) {
        let resolvedDeviceID = deviceID ?? route?.defaultInputDeviceID
        let resolvedName: String?
        if resolvedDeviceID == route?.preferredInputDeviceID {
            resolvedName = route?.preferredInputDeviceName
        } else if resolvedDeviceID == route?.defaultInputDeviceID {
            resolvedName = route?.defaultInputDeviceName
        } else {
            resolvedName = nil
        }
        return (resolvedDeviceID, resolvedName)
    }

    private static func kind(for deviceID: AudioObjectID?) -> ActiveRecorderKind {
        deviceID == nil ? .systemDefault : .appScoped
    }

    private static func routeRole(for deviceID: AudioObjectID?) -> String {
        deviceID == nil ? "system_default" : "app_scoped"
    }

    private func takeUnusedSeedRecorders() -> [MeetingMicRecording] {
        let recorders = [seededSystemDefaultRecorder, seededAppScopedRecorder].compactMap { $0 }
        seededSystemDefaultRecorder = nil
        seededAppScopedRecorder = nil
        return recorders
    }

    private func cancelAsync(_ child: Child?) {
        guard let child else { return }
        let startedAt = AudioLifecycleDiagnostics.monotonicNowNanoseconds()
        AudioLifecycleDiagnostics.emit(
            .debug,
            operation: "mic_candidate_cleanup_begin",
            operationID: child.id,
            generation: child.generation,
            routeRole: Self.routeRole(for: child.deviceID),
            deviceID: child.deviceID,
            status: "cancel"
        )
        cleanupQueue.async {
            child.recorder.cancel()
            AudioLifecycleDiagnostics.emit(
                .debug,
                operation: "mic_candidate_cleanup_end",
                operationID: child.id,
                generation: child.generation,
                routeRole: Self.routeRole(for: child.deviceID),
                deviceID: child.deviceID,
                durationMilliseconds: AudioLifecycleDiagnostics.elapsedMilliseconds(since: startedAt),
                status: "cancelled"
            )
        }
    }

    private func cancelAsync(_ recorders: [MeetingMicRecording]) {
        guard !recorders.isEmpty else { return }
        let operationID = UUID()
        let startedAt = AudioLifecycleDiagnostics.monotonicNowNanoseconds()
        AudioLifecycleDiagnostics.emit(
            .debug,
            operation: "mic_unused_cleanup_begin",
            operationID: operationID,
            status: "count_\(recorders.count)"
        )
        cleanupQueue.async {
            for recorder in recorders { recorder.cancel() }
            AudioLifecycleDiagnostics.emit(
                .debug,
                operation: "mic_unused_cleanup_end",
                operationID: operationID,
                durationMilliseconds: AudioLifecycleDiagnostics.elapsedMilliseconds(since: startedAt),
                status: "cancelled"
            )
        }
    }

    private func retireAfterHandoffAsync(_ child: Child?) {
        guard let child else { return }
        let startedAt = AudioLifecycleDiagnostics.monotonicNowNanoseconds()
        AudioLifecycleDiagnostics.emit(
            .debug,
            operation: "mic_active_retirement_begin",
            operationID: child.id,
            generation: child.generation,
            routeRole: Self.routeRole(for: child.deviceID),
            deviceID: child.deviceID,
            status: "stop_cancel"
        )
        cleanupQueue.async {
            let url = child.recorder.stop()
            child.recorder.cancel()
            if let url { try? FileManager.default.removeItem(at: url) }
            AudioLifecycleDiagnostics.emit(
                .debug,
                operation: "mic_active_retirement_end",
                operationID: child.id,
                generation: child.generation,
                routeRole: Self.routeRole(for: child.deviceID),
                deviceID: child.deviceID,
                durationMilliseconds: AudioLifecycleDiagnostics.elapsedMilliseconds(since: startedAt),
                status: "retired"
            )
        }
    }

    private static func cancelDetachedCandidate(_ child: Child, on cleanupQueue: DispatchQueue) {
        let startedAt = AudioLifecycleDiagnostics.monotonicNowNanoseconds()
        AudioLifecycleDiagnostics.emit(
            .notice,
            operation: "mic_detached_cleanup_begin",
            operationID: child.id,
            generation: child.generation,
            routeRole: routeRole(for: child.deviceID),
            deviceID: child.deviceID,
            status: "owner_or_candidate_released"
        )
        cleanupQueue.async {
            child.recorder.cancel()
            AudioLifecycleDiagnostics.emit(
                .notice,
                operation: "mic_detached_cleanup_end",
                operationID: child.id,
                generation: child.generation,
                routeRole: routeRole(for: child.deviceID),
                deviceID: child.deviceID,
                durationMilliseconds: AudioLifecycleDiagnostics.elapsedMilliseconds(since: startedAt),
                status: "cancelled"
            )
        }
    }

    private static func makeSystemDefaultRecorder() -> MeetingMicRecording {
        StreamingMeetingMicRecorderAdapter(
            recorder: StreamingMicRecorder(
                directoryName: "muesli-meeting-mic",
                recoversFromInputConfigurationChanges: true
            ),
            kind: .systemDefaultStreaming
        )
    }

    private static func makeAppScopedRecorder() -> MeetingMicRecording {
        StreamingMeetingMicRecorderAdapter(
            recorder: FallbackStreamingDictationRecorder(
                primary: AudioQueueInputRecorder(directoryName: "muesli-meeting-mic-audioqueue"),
                fallback: StreamingMicRecorder(
                    directoryName: "muesli-meeting-mic-app-scoped-fallback",
                    recoversFromInputConfigurationChanges: true
                )
            ),
            kind: .appScopedAudioQueue
        )
    }
}

private extension RouteAwareMeetingMicRecorder.ActiveRecorderKind {
    var diagnosticsKind: MeetingMicRecorderKind {
        switch self {
        case .systemDefault: return .systemDefaultStreaming
        case .appScoped: return .appScopedAudioQueue
        }
    }
}
