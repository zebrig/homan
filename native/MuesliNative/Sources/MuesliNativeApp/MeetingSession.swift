import FluidAudio
import ApplicationServices
import CoreAudio
import Foundation
import MuesliCore
import os

final class MeetingChunkCollector {
    private struct PendingTask {
        let id: UUID
        let task: Task<[SpeechSegment], Never>
    }

    private struct State {
        // Only in-flight tasks live here. Completed tasks are retired into
        // completedSegments so Task objects and their captured state don't
        // accumulate for the full meeting duration.
        var pendingTasks: [PendingTask] = []
        var completedSegments: [SpeechSegment] = []
        var isClosed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Register a transcription task. Returns the retire ID to pass to retire(id:segments:)
    /// once the task completes.
    func add(_ task: Task<[SpeechSegment], Never>) -> (registered: Bool, retireID: UUID) {
        let id = UUID()
        let registered = lock.withLock { state in
            guard !state.isClosed else { return false }
            state.pendingTasks.append(PendingTask(id: id, task: task))
            return true
        }
        return (registered, id)
    }

    /// Move a completed task's result into the collector and drop the Task reference.
    /// Must be called from the watcher Task after awaiting the transcription task's value.
    func retire(id: UUID, segments: [SpeechSegment]) -> Bool {
        lock.withLock { state in
            guard !state.isClosed else { return false }
            state.completedSegments.append(contentsOf: segments)
            state.pendingTasks.removeAll { $0.id == id }
            return true
        }
    }

    func closeAndDrainSortedSegments() async -> [SpeechSegment] {
        let (tasksToAwait, alreadyCompleted) = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            let completed = state.completedSegments
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            return (tasks, completed)
        }

        var segments = alreadyCompleted
        for task in tasksToAwait {
            segments.append(contentsOf: await task.value)
        }

        return segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    func waitUntilRetired() async {
        while true {
            let tasks = lock.withLock { $0.pendingTasks.map(\.task) }
            guard !tasks.isEmpty else { return }
            for task in tasks {
                _ = await task.value
            }
            await Task.yield()
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            return tasks
        }
        tasksToCancel.forEach { $0.cancel() }
    }
}

struct MeetingSessionResult {
    let title: String
    let originalTitle: String
    let calendarEventID: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let retainedRecordingURL: URL?
    let retainedRecordingError: Error?
    let systemRecordingURL: URL?
    var stagedAudio: MeetingStagedAudio? = nil
    var stagedRawAudio: MeetingStagedRawAudio? = nil
    let templateSnapshot: MeetingTemplateSnapshot
    var processingMetadata: MeetingProcessingMetadata = .empty
    /// Provider-neutral ASR and speaker evidence is materialized only after
    /// persistence assigns the definitive meeting id.
    var transcriptionResult: MeetingTranscriptionResult? = nil
    var transcriptEvidence: MeetingTranscriptEvidenceBundle? = nil
    /// Start of this recording segment. This remains distinct from `startTime`
    /// when a resumed meeting is merged back into the original meeting.
    var recordingStartedAt: Date? = nil
}

extension MeetingSessionResult {
    /// Returns a copy with transcript, notes, and optional timing overrides.
    /// Used by the resume-recording flow to persist the merged transcript while
    /// keeping the original meeting date and accumulating only recorded duration.
    func overriding(
        startTime newStartTime: Date? = nil,
        durationSeconds newDurationSeconds: Double? = nil,
        rawTranscript: String,
        formattedNotes: String,
        processingMetadata newProcessingMetadata: MeetingProcessingMetadata? = nil,
        transcriptEvidence newTranscriptEvidence: MeetingTranscriptEvidenceBundle? = nil
    ) -> MeetingSessionResult {
        let resolvedStart = newStartTime ?? startTime
        let resolvedDuration = newDurationSeconds ?? durationSeconds
        return MeetingSessionResult(
            title: title,
            originalTitle: originalTitle,
            calendarEventID: calendarEventID,
            startTime: resolvedStart,
            endTime: endTime,
            durationSeconds: resolvedDuration,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingError,
            systemRecordingURL: systemRecordingURL,
            stagedAudio: stagedAudio,
            stagedRawAudio: stagedRawAudio,
            templateSnapshot: templateSnapshot,
            processingMetadata: newProcessingMetadata ?? processingMetadata,
            transcriptionResult: transcriptionResult,
            transcriptEvidence: newTranscriptEvidence ?? transcriptEvidence,
            recordingStartedAt: recordingStartedAt ?? startTime
        )
    }
}

enum MeetingProcessingStage {
    case cleaningWav
    case writingRecording
    case transcribingAudio
    case preparingDiarizer
    case diarizing
    case applyingSpeakerLabels
    case generatingTitle
    case summarizingNotes
}

private enum MeetingTranscriptRecoveryResult {
    case none
    case append([SpeechSegment])
    case replace([SpeechSegment])
}

final class MeetingSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingSession")

    private let meetingID: Int64
    private let title: String
    private let calendarEventID: String?
    private let finalBackend: BackendOption
    private let runtime: RuntimePaths
    private let processingSupportDirectory: URL
    private let config: AppConfig
    private let templateSnapshot: MeetingTemplateSnapshot
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder: SystemAudioCapturing
    private let neuralAec: MeetingNeuralAec
    private let inferenceScheduler: MeetingInferenceScheduler
    private let inferenceCaptureOwnerID = UUID()
    private let finalDiarizationPolicyStorage: OSAllocatedUnfairLock<ResolvedMeetingDiarizationPolicy>

    /// Route-aware mic recorder with real-time 16 kHz mono PCM access.
    private var meetingMicRecorder: MeetingMicRecording
    private var rawMicChunkRecorder: PCMChunkRecorder?
    private var retainedRecordingWriterError: Error?
    private var rawAudioCapture: MeetingRawAudioCapture?
    /// VAD controller for speech-boundary chunk rotation
    private var vadController: StreamingVadController?
    private var systemVadController: StreamingVadController?
    private var liveVadManager: VadManager?
    private let micChunkCollector = MeetingChunkCollector()
    private let systemChunkCollector = MeetingChunkCollector()
    private let micChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let systemChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let micHealthTracker = MeetingMicHealthTracker()
    private let micRecoveryCoordinator = MeetingMicRecoveryCoordinator()
    private let chunkRotationQueue = DispatchQueue(label: "MuesliNative.MeetingSession.chunkRotation")
    private let pausedDisplayLock = OSAllocatedUnfairLock(initialState: false)
    private var chunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkRecorder: PCMChunkRecorder?
    var onProgress: ((MeetingProcessingStage) -> Void)?
    var onMicHealthChanged: ((MeetingMicHealthSnapshot) -> Void)?
    var onMicHealthEpisode: ((MeetingMicHealthEpisodeEvent) -> Void)?
    var onCaptureIntegrityFailure: ((Error) -> Void)?
    var manualNotesProvider: (() async -> String?)?
    var liveTitleProvider: (() async -> String?)?
    /// Formatted notes of the predecessor meeting when this session records a
    /// follow-up; injected into the summary prompt for action-item carry-forward.
    var previousMeetingNotes: String?
    var onChunkTranscribed: (([SpeechSegment], String, UInt64) -> Void)?
    /// Display-only streaming partial for a source ("You"/"Others", tail text).
    /// Empty text clears the source's tail. Called on a background thread.
    var onPartialTranscript: ((String, String, UInt64) -> Void)?
    var onLiveStateChanged: ((MeetingLiveRuntimeState) -> Void)?
    var onLiveDiarizationStateChanged: ((MeetingLiveDiarizationRuntimeState) -> Void)?
    /// Lock-guarded because sessions are installed by an async model-loading
    /// task, fed on chunkRotationQueue, and committed by chunk-completion tasks.
    /// `isShutDown` closes the async-setup race with meeting teardown.
    private struct PartialSessionsStorage {
        var mic: MeetingStreamingPartialSession?
        var system: MeetingStreamingPartialSession?
        var generation: UInt64 = 0
    }
    private let partialSessionsStorage = OSAllocatedUnfairLock(initialState: PartialSessionsStorage())
    private struct LiveRuntimeStorage {
        var state = MeetingLiveRuntimeState.off(selection: .parakeetRealtimeEOU)
        var micChunkedQueue: MeetingChunkedLiveQueue?
        var systemChunkedQueue: MeetingChunkedLiveQueue?
    }
    private let liveRuntimeStorage = OSAllocatedUnfairLock(initialState: LiveRuntimeStorage())
    private struct LiveDiarizationStorage {
        var state = MeetingLiveDiarizationRuntimeState.off()
        var activity: [MeetingDiarizationActivitySegment] = []
    }
    private let liveDiarizationStorage = OSAllocatedUnfairLock(
        initialState: LiveDiarizationStorage()
    )
    /// These fields are owned exclusively by `chunkRotationQueue`.
    private var liveDiarizationEngine: MeetingLiveDiarizationEngine?
    private var liveDiarizationPreparationTask: Task<Void, Never>?
    private var liveDiarizationPreparationEpoch: UInt64?
    private var liveDiarizationSamples: [Float] = []
    /// The epoch which owns the currently executing native inference. Keeping
    /// the epoch (instead of a Bool) prevents a late completion from an old
    /// Off -> On cycle from clearing the new epoch's in-flight guard.
    private var liveDiarizationInferenceEpoch: UInt64?
    private var liveDiarizationInferenceTask: Task<Void, Never>?
    private var liveDiarizationEpochStart: TimeInterval = 0
    private static let liveDiarizationBatchSampleCount = 32_000
    private static let liveDiarizationLagSampleCount = 64_000
    private static let liveDiarizationMaximumBufferedSampleCount = 160_000
    private let screenContextCollector = MeetingScreenContextCollector()
    private var diagnostics: MeetingSessionDiagnostics?

    /// Current mic power level for waveform visualization.
    func currentPower() -> Float {
        if pausedDisplayLock.withLock({ $0 }) {
            return -160
        }
        return meetingMicRecorder.currentPower()
    }

    private(set) var startTime: Date?
    private(set) var isRecording = false
    private(set) var isPaused = false

    private func setPausedStateOnQueue(_ paused: Bool) {
        isPaused = paused
        pausedDisplayLock.withLock { $0 = paused }
    }

    init(
        meetingID: Int64,
        title: String,
        calendarEventID: String?,
        backend: BackendOption,
        runtime: RuntimePaths,
        config: AppConfig,
        templateSnapshot: MeetingTemplateSnapshot,
        transcriptionCoordinator: TranscriptionCoordinator,
        finalDiarizationPolicy: ResolvedMeetingDiarizationPolicy? = nil,
        processingSupportDirectory: URL = AppIdentity.supportDirectoryURL,
        meetingMicRecorder: MeetingMicRecording = RouteAwareMeetingMicRecorder(),
        inferenceScheduler: MeetingInferenceScheduler = .shared
    ) {
        self.meetingID = meetingID
        self.title = title
        self.calendarEventID = calendarEventID
        self.finalBackend = backend
        self.runtime = runtime
        self.config = config
        self.templateSnapshot = templateSnapshot
        self.transcriptionCoordinator = transcriptionCoordinator
        self.finalDiarizationPolicyStorage = OSAllocatedUnfairLock(
            initialState: finalDiarizationPolicy ?? ResolvedMeetingDiarizationPolicy(
                enabled: config.meetingFinalDiarizationEnabledByDefault,
                profileID: config.resolvedMeetingFinalDiarizationProfile
            )
        )
        self.processingSupportDirectory = processingSupportDirectory
        self.meetingMicRecorder = meetingMicRecorder
        self.inferenceScheduler = inferenceScheduler
        self.neuralAec = MeetingNeuralAec(localVQEModel: config.resolvedMeetingAecModel)
        liveRuntimeStorage.withLock {
            $0.state = .off(selection: config.resolvedMeetingLiveASRModelID)
        }
        liveDiarizationStorage.withLock {
            $0.state = .off()
        }
        if config.useCoreAudioTap {
            self.systemAudioRecorder = CoreAudioSystemRecorder()
        } else {
            self.systemAudioRecorder = SystemAudioRecorder()
        }
        micRecoveryCoordinator.recoveryRequest = { [weak meetingMicRecorder] reason in
            meetingMicRecorder?.requestSameRouteRecovery(reason: reason) ?? false
        }
        micRecoveryCoordinator.onEpisodeEvent = { [weak self] event in
            self?.onMicHealthEpisode?(event)
        }
    }

    deinit {
        // Idempotent safety net for a failed/abandoned lifecycle. Normal stop
        // and discard release the same owner as soon as capture has ended.
        inferenceScheduler.endCapture(ownerID: inferenceCaptureOwnerID)
    }

    func setFinalDiarizationPolicy(_ policy: ResolvedMeetingDiarizationPolicy) {
        finalDiarizationPolicyStorage.withLock { $0 = policy }
        try? rawAudioCapture?.setFinalDiarizationPolicy(
            enabled: policy.enabled,
            profileID: policy.profileID
        )
    }

    func finalDiarizationPolicySnapshot() -> ResolvedMeetingDiarizationPolicy {
        finalDiarizationPolicyStorage.withLock { $0 }
    }

    func setPreferredMicrophoneInputDeviceID(_ deviceID: AudioObjectID?) {
        meetingMicRecorder.preferredInputDeviceID = deviceID
    }

    func microphoneRouteTransitionSnapshot() -> MeetingMicRouteTransitionSnapshot {
        meetingMicRecorder.routeTransitionSnapshot()
    }

    private func currentBackend() -> BackendOption {
        finalBackend
    }

    func start() async throws {
        // Publishing capture ownership is synchronous and cannot wait on model
        // work. Background diarization observes it at its next checkpoint.
        inferenceScheduler.beginCapture(ownerID: inferenceCaptureOwnerID)
        let now = Date()
        diagnostics = MeetingSessionDiagnostics(title: title, startedAt: now)

        chunkRotationQueue.sync {
            startTime = now
            chunkTimingTracker.start()
            systemChunkTimingTracker.start()
            isRecording = true
            setPausedStateOnQueue(false)
        }

        do {
            let finalDiarizationPolicy = finalDiarizationPolicySnapshot()
            let capture = try MeetingRawAudioCapture(
                meetingID: meetingID,
                startedAt: now,
                finalModelID: currentBackend().asrModelID,
                cohereLanguage: config.resolvedCohereLanguage,
                indicASRLanguage: config.resolvedIndicASRLanguage,
                nemotron35Language: config.resolvedNemotron35Language,
                finalDiarizationEnabled: finalDiarizationPolicy.enabled,
                finalDiarizationProfileID: finalDiarizationPolicy.profileID,
                supportDirectory: processingSupportDirectory
            )
            capture.onFailure = { [weak self] error in
                self?.onCaptureIntegrityFailure?(error)
            }
            rawAudioCapture = capture
            prepareRealtimeAudioPipeline()
            meetingMicRecorder.emitsProcessedAudio = false
            systemAudioRecorder.emitsProcessedAudio = false
            try meetingMicRecorder.prepare()
            retainedRecordingWriterError = nil
            try await systemAudioRecorder.start()
            try meetingMicRecorder.start()
        } catch {
            inferenceScheduler.endCapture(ownerID: inferenceCaptureOwnerID)
            vadController?.stop()
            vadController = nil
            systemVadController?.stop()
            systemVadController = nil
            meetingMicRecorder.onRawPCMSamples = nil
            meetingMicRecorder.onNativeAudioChunk = nil
            systemAudioRecorder.onPCMSamples = nil
            systemAudioRecorder.onNativeAudioChunk = nil
            rawAudioCapture?.discard()
            rawAudioCapture = nil
            rawMicChunkRecorder?.cancel()
            rawMicChunkRecorder = nil
            systemChunkRecorder?.cancel()
            systemChunkRecorder = nil
            chunkRotationQueue.sync {
                isRecording = false
                setPausedStateOnQueue(false)
                startTime = nil
                chunkTimingTracker.discard()
                systemChunkTimingTracker.discard()
            }
            meetingMicRecorder.cancel()
            if let url = systemAudioRecorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            systemChunkCollector.cancelAll()
            throw error
        }
        if config.enableScreenContext && CGPreflightScreenCaptureAccess() {
            // OCR screenshots are safe when using CoreAudio tap (no SCStream conflict)
            await screenContextCollector.startPeriodicCapture(useOCR: config.useCoreAudioTap)
        }
        publishLiveState(liveStateSnapshot())
        publishLiveDiarizationState(liveDiarizationStateSnapshot())
        if config.meetingLiveDiarizationEnabledByDefault {
            setLiveDiarizationEnabled(true)
        }
        if config.meetingLiveEnabledByDefault {
            startLive()
        }
    }

    func liveStateSnapshot() -> MeetingLiveRuntimeState {
        liveRuntimeStorage.withLock { $0.state }
    }

    func liveDiarizationStateSnapshot() -> MeetingLiveDiarizationRuntimeState {
        liveDiarizationStorage.withLock { $0.state }
    }

    func setLiveDiarizationEnabled(_ enabled: Bool) {
        if enabled {
            startLiveDiarization()
        } else {
            stopLiveDiarization(userInitiated: true)
        }
    }

    private func startLiveDiarization() {
        guard chunkRotationQueue.sync(execute: { isRecording }) else { return }
        let loading = liveDiarizationStorage.withLock {
            storage -> MeetingLiveDiarizationRuntimeState? in
            guard storage.state.phase == .off || storage.state.phase == .failed else {
                return nil
            }
            let epoch = storage.state.epoch &+ 1
            storage.activity.removeAll()
            storage.state = MeetingLiveDiarizationRuntimeState(
                enabled: true,
                phase: .loading,
                epoch: epoch,
                profileID: .stableFourSpeaker,
                message: epoch > 1 ? "Speaker labels restart with this Live epoch." : nil,
                droppedAudioSeconds: 0
            )
            return storage.state
        }
        guard let loading else { return }
        publishLiveDiarizationState(loading)

        let engine = MeetingLiveDiarizationEngine()
        chunkRotationQueue.sync {
            liveDiarizationPreparationTask?.cancel()
            liveDiarizationPreparationTask = nil
            liveDiarizationPreparationEpoch = loading.epoch
        }
        let preparationTask = Task.detached(priority: .userInitiated) { [weak self, engine] in
            guard let self else { return }
            do {
                try await engine.prepare()
                self.chunkRotationQueue.async { [weak self, engine] in
                    guard let self else {
                        Task { await engine.stop() }
                        return
                    }
                    guard self.liveDiarizationPreparationEpoch == loading.epoch,
                          self.isRecording else {
                        Task { await engine.stop() }
                        return
                    }
                    self.liveDiarizationPreparationTask = nil
                    self.liveDiarizationPreparationEpoch = nil
                    let ready = self.liveDiarizationStorage.withLock {
                        storage -> MeetingLiveDiarizationRuntimeState? in
                        guard storage.state.enabled,
                              storage.state.phase == .loading,
                              storage.state.epoch == loading.epoch else {
                            return nil
                        }
                        self.liveDiarizationEngine = engine
                        self.liveDiarizationSamples.removeAll(keepingCapacity: true)
                        self.liveDiarizationInferenceEpoch = nil
                        self.liveDiarizationEpochStart = self.systemChunkTimingTracker
                            .currentEndTimeSeconds
                        storage.state.phase = self.isPaused ? .suspended : .running
                        return storage.state
                    }
                    guard let ready else {
                        Task { await engine.stop() }
                        return
                    }
                    self.systemAudioRecorder.emitsProcessedAudio = true
                    self.publishLiveDiarizationState(ready)
                }
            } catch is CancellationError {
                self.failLiveDiarization(
                    epoch: loading.epoch,
                    message: "Live speaker separation was cancelled."
                )
            } catch {
                self.failLiveDiarization(
                    epoch: loading.epoch,
                    message: error.localizedDescription
                )
            }
        }
        chunkRotationQueue.sync {
            if liveDiarizationPreparationEpoch == loading.epoch {
                liveDiarizationPreparationTask = preparationTask
            } else {
                preparationTask.cancel()
            }
        }
    }

    private func stopLiveDiarization(userInitiated: Bool) {
        let stoppedState = liveDiarizationStorage.withLock {
            storage -> MeetingLiveDiarizationRuntimeState? in
            guard storage.state.phase != .off || storage.state.enabled else { return nil }
            let priorEpoch = storage.state.epoch
            storage.activity.removeAll()
            storage.state = .off(
                enabled: false,
                epoch: priorEpoch,
                message: userInitiated && priorEpoch > 0
                    ? "Future remote speech uses Others. Labels restart if enabled again."
                    : nil
            )
            return storage.state
        }
        guard let stoppedState else { return }
        let engine = chunkRotationQueue.sync { () -> MeetingLiveDiarizationEngine? in
            liveDiarizationPreparationTask?.cancel()
            liveDiarizationPreparationTask = nil
            liveDiarizationPreparationEpoch = nil
            liveDiarizationInferenceTask?.cancel()
            liveDiarizationInferenceTask = nil
            let engine = liveDiarizationEngine
            liveDiarizationEngine = nil
            liveDiarizationSamples.removeAll(keepingCapacity: true)
            liveDiarizationInferenceEpoch = nil
            if activeLiveSnapshot() == nil {
                systemAudioRecorder.emitsProcessedAudio = false
            }
            return engine
        }
        publishLiveDiarizationState(stoppedState)
        if let engine {
            Task { await engine.stop() }
        }
    }

    private func finishLiveDiarizationForMeetingEnd() async {
        let stoppedState = liveDiarizationStorage.withLock { storage in
            let epoch = storage.state.epoch
            storage.activity.removeAll()
            storage.state = .off(epoch: epoch)
            return storage.state
        }
        let engine = chunkRotationQueue.sync { () -> MeetingLiveDiarizationEngine? in
            liveDiarizationPreparationTask?.cancel()
            liveDiarizationPreparationTask = nil
            liveDiarizationPreparationEpoch = nil
            liveDiarizationInferenceTask?.cancel()
            liveDiarizationInferenceTask = nil
            let engine = liveDiarizationEngine
            liveDiarizationEngine = nil
            liveDiarizationSamples.removeAll(keepingCapacity: true)
            liveDiarizationInferenceEpoch = nil
            systemAudioRecorder.emitsProcessedAudio = false
            return engine
        }
        if let engine {
            await engine.stop()
        }
        publishLiveDiarizationState(stoppedState)
    }

    @discardableResult
    func selectLiveModel(_ modelID: ASRModelID) -> Bool {
        guard let descriptor = MeetingASRModelCatalog.resolve(id: modelID),
              descriptor.capabilities.liveMode.isAvailable else {
            return false
        }
        let updated = liveRuntimeStorage.withLock { storage -> MeetingLiveRuntimeState? in
            guard storage.state.phase == .off || storage.state.phase == .failed else {
                return nil
            }
            storage.state = .off(
                selection: modelID,
                generation: storage.state.generation
            )
            return storage.state
        }
        guard let updated else { return false }
        publishLiveState(updated)
        return true
    }

    static func liveModelIDIsAvailable(_ modelID: ASRModelID) -> Bool {
        guard let descriptor = MeetingASRModelCatalog.resolve(id: modelID),
              descriptor.capabilities.liveMode.isAvailable,
              MeetingASRModelCatalog.isDownloaded(descriptor) else {
            return false
        }
        if let minimum = descriptor.capabilities.minimumMacOSMajorVersion,
           ProcessInfo.processInfo.operatingSystemVersion.majorVersion < minimum {
            return false
        }
        return true
    }

    func startLive(modelID: ASRModelID? = nil) {
        if let modelID, !selectLiveModel(modelID) {
            return
        }
        let selection = liveRuntimeStorage.withLock { $0.state.selection }
        guard chunkRotationQueue.sync(execute: { isRecording }) else { return }

        // Smart live resolution: use the selected model when it's live-capable
        // and downloaded; otherwise fall back to the mandatory Parakeet v3
        // (chunked live) so live captions start instead of failing on a missing
        // optional model.
        let resolved: ASRModelID
        if Self.liveModelIDIsAvailable(selection) {
            resolved = selection
        } else if Self.liveModelIDIsAvailable(BackendOption.parakeetMultilingual.asrModelID) {
            resolved = BackendOption.parakeetMultilingual.asrModelID
            if resolved != selection {
                _ = selectLiveModel(resolved)
            }
        } else {
            rejectLiveStart(
                message: "No live-capable transcription model is downloaded. Install Parakeet v3 to enable live captions."
            )
            return
        }
        guard let descriptor = MeetingASRModelCatalog.resolve(id: resolved) else {
            rejectLiveStart(
                message: "The selected model cannot transcribe live meeting audio."
            )
            return
        }
        let kind: MeetingLiveKind = descriptor.capabilities.liveMode.isNativeStreaming
            ? .streaming
            : .chunked
        let loadingState = liveRuntimeStorage.withLock { storage -> MeetingLiveRuntimeState? in
            guard storage.state.phase == .off || storage.state.phase == .failed else {
                return nil
            }
            let generation = storage.state.generation &+ 1
            storage.state = MeetingLiveRuntimeState(
                selection: resolved,
                phase: .loading,
                kind: kind,
                generation: generation,
                message: nil,
                droppedPreviewChunks: 0
            )
            return storage.state
        }
        guard let loadingState else { return }
        publishLiveState(loadingState)

        switch kind {
        case .streaming:
            guard let backend = MeetingLiveCaptionBackend(asrModelID: descriptor.id) else {
                failLive(
                    generation: loadingState.generation,
                    message: "No streaming adapter is available for \(descriptor.label)."
                )
                return
            }
            startStreamingLive(backend: backend, generation: loadingState.generation)
        case .chunked:
            guard let backend = BackendOption.resolve(
                backend: descriptor.id.backend,
                model: descriptor.id.model
            ) else {
                failLive(
                    generation: loadingState.generation,
                    message: "No chunked live adapter is available for \(descriptor.label)."
                )
                return
            }
            startChunkedLive(backend: backend, generation: loadingState.generation)
        }
    }

    func stopLive() {
        let stopped = liveRuntimeStorage.withLock { storage -> (
            MeetingLiveRuntimeState,
            MeetingChunkedLiveQueue?,
            MeetingChunkedLiveQueue?
        )? in
            guard let offState = storage.state.detachedAfterStopRequest() else {
                return nil
            }
            let micQueue = storage.micChunkedQueue
            let systemQueue = storage.systemChunkedQueue
            storage.micChunkedQueue = nil
            storage.systemChunkedQueue = nil
            storage.state = offState
            return (storage.state, micQueue, systemQueue)
        }
        guard let stopped else { return }
        chunkRotationQueue.sync {
            deactivateLivePreviewPipelineOnQueue()
        }
        stopPartialSessions()
        publishLiveState(stopped.0)

        // A chunked backend can remain inside an inference call that does not
        // react to task cancellation. The old generation is already detached
        // from capture and the UI is Off/selectable, so finish obsolete queue
        // cleanup in the background. Any late callback carries the prior
        // generation and is rejected by handleLiveSegments/failLive.
        Task {
            await stopped.1?.stop()
            await stopped.2?.stop()
        }
    }

    private func finishLiveForMeetingEnd() async {
        let stopped = liveRuntimeStorage.withLock { storage -> (
            MeetingLiveRuntimeState,
            MeetingChunkedLiveQueue?,
            MeetingChunkedLiveQueue?
        ) in
            let generation = storage.state.generation &+ 1
            let selection = storage.state.selection
            let micQueue = storage.micChunkedQueue
            let systemQueue = storage.systemChunkedQueue
            storage.micChunkedQueue = nil
            storage.systemChunkedQueue = nil
            storage.state = .off(selection: selection, generation: generation)
            return (storage.state, micQueue, systemQueue)
        }
        stopPartialSessions()
        chunkRotationQueue.sync {
            deactivateLivePreviewPipelineOnQueue()
        }
        await stopped.1?.stop()
        await stopped.2?.stop()
        publishLiveState(stopped.0)
    }

    private func startChunkedLive(backend: BackendOption, generation: UInt64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.neuralAec.preload()
                let vadManager = await self.transcriptionCoordinator.getVadManager()
                try await self.transcriptionCoordinator.preloadRequired(
                    backend: backend,
                    enablePostProcessor: false,
                    includeMeetingHelpers: false
                )
                let micQueue = self.makeChunkedLiveQueue(
                    source: .microphone,
                    backend: backend,
                    generation: generation
                )
                let systemQueue = self.makeChunkedLiveQueue(
                    source: .system,
                    backend: backend,
                    generation: generation
                )
                let runningState = try self.chunkRotationQueue.sync {
                    () -> MeetingLiveRuntimeState? in
                    guard self.isRecording,
                          self.isLiveGeneration(generation, allowedPhases: [.loading]) else {
                        return nil
                    }
                    self.liveVadManager = vadManager
                    self.neuralAec.resetForStreaming()
                    try self.activateLivePreviewPipelineOnQueue()
                    self.resetLivePreviewBoundaryOnQueue()
                    return self.liveRuntimeStorage.withLock {
                        storage -> MeetingLiveRuntimeState? in
                        guard storage.state.phase == .loading,
                              storage.state.generation == generation else {
                            return nil
                        }
                        storage.micChunkedQueue = micQueue
                        storage.systemChunkedQueue = systemQueue
                        storage.state.phase = self.isPaused ? .suspended : .running
                        return storage.state
                    }
                }
                guard let runningState else {
                    await micQueue.stop()
                    await systemQueue.stop()
                    return
                }
                self.publishLiveState(runningState)
            } catch {
                self.failLive(generation: generation, message: error.localizedDescription)
            }
        }
    }

    private func makeChunkedLiveQueue(
        source: MeetingLiveAudioSource,
        backend: BackendOption,
        generation: UInt64
    ) -> MeetingChunkedLiveQueue {
        MeetingChunkedLiveQueue(
            source: source,
            generation: generation,
            backend: backend,
            cohereLanguage: config.resolvedCohereLanguage,
            indicASRLanguage: config.resolvedIndicASRLanguage,
            coordinator: transcriptionCoordinator,
            onSegments: { [weak self] segments, source, generation in
                self?.handleLiveSegments(
                    segments,
                    source: source,
                    generation: generation
                )
            },
            onLagChanged: { [weak self] isLagging, dropped, generation in
                self?.handleLiveLagChanged(
                    isLagging,
                    droppedCount: dropped,
                    generation: generation
                )
            },
            onFailure: { [weak self] message, generation in
                self?.failLive(generation: generation, message: message)
            }
        )
    }

    private func startStreamingLive(
        backend: MeetingLiveCaptionBackend,
        generation: UInt64
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.neuralAec.preload()
                let vadManager = await self.transcriptionCoordinator.getVadManager()
                let engines = try await MeetingLiveCaptionModelStore.makeEngines(
                    backend: backend,
                    nemotronPromptId: self.config.resolvedNemotron35Language.promptId
                )
                guard self.chunkRotationQueue.sync(execute: { self.isRecording }),
                      self.isLiveGeneration(generation, allowedPhases: [.loading]) else {
                    await engines.mic.shutdown()
                    await engines.system.shutdown()
                    return
                }

                let mic = MeetingStreamingPartialSession(engine: engines.mic, source: .microphone)
                mic.onPartialUpdate = { [weak self] text in
                    guard self?.isLiveGeneration(
                        generation,
                        allowedPhases: [.running, .lagging]
                    ) == true else {
                        return
                    }
                    self?.onPartialTranscript?("You", text, generation)
                }
                await mic.connect()
                let system = MeetingStreamingPartialSession(engine: engines.system, source: .system)
                system.onPartialUpdate = { [weak self] text in
                    guard self?.isLiveGeneration(
                        generation,
                        allowedPhases: [.running, .lagging]
                    ) == true else {
                        return
                    }
                    self?.onPartialTranscript?("Others", text, generation)
                }
                await system.connect()

                let runningState = try self.chunkRotationQueue.sync {
                    () -> MeetingLiveRuntimeState? in
                    guard self.isRecording,
                          self.isLiveGeneration(generation, allowedPhases: [.loading]) else {
                        return nil
                    }
                    self.liveVadManager = vadManager
                    self.neuralAec.resetForStreaming()
                    try self.activateLivePreviewPipelineOnQueue()
                    self.resetLivePreviewBoundaryOnQueue()
                    self.partialSessionsStorage.withLock { storage in
                        storage.mic = mic
                        storage.system = system
                        storage.generation = generation
                    }
                    return self.liveRuntimeStorage.withLock {
                        storage -> MeetingLiveRuntimeState? in
                        guard storage.state.phase == .loading,
                              storage.state.generation == generation else {
                            return nil
                        }
                        storage.state.phase = self.isPaused ? .suspended : .running
                        return storage.state
                    }
                }
                guard let runningState else {
                    self.stopPartialSessions(generation: generation)
                    return
                }
                self.publishLiveState(runningState)
                fputs("[meeting-partials] \(backend.label) active for mic and system audio\n", stderr)
            } catch {
                self.failLive(generation: generation, message: error.localizedDescription)
            }
        }
    }

    private func handleLiveSegments(
        _ segments: [SpeechSegment],
        source: MeetingLiveAudioSource,
        generation: UInt64
    ) {
        guard isLiveGeneration(generation, allowedPhases: [.running, .lagging]) else {
            return
        }
        switch source {
        case .microphone:
            onChunkTranscribed?(segments, source.speakerLabel, generation)
        case .system:
            for segment in segments {
                onChunkTranscribed?(
                    [segment],
                    liveSpeakerLabel(source: source, segment: segment),
                    generation
                )
            }
        }
    }

    private func handleLiveLagChanged(
        _ isLagging: Bool,
        droppedCount: Int,
        generation: UInt64
    ) {
        let updated = liveRuntimeStorage.withLock { storage -> MeetingLiveRuntimeState? in
            guard storage.state.generation == generation,
                  storage.state.phase == .running || storage.state.phase == .lagging else {
                return nil
            }
            storage.state.phase = isLagging ? .lagging : .running
            storage.state.droppedPreviewChunks = droppedCount
            storage.state.message = isLagging
                ? "Live preview is lagging; older queued chunks are being skipped."
                : nil
            return storage.state
        }
        if let updated {
            publishLiveState(updated)
        }
    }

    private func failLive(generation: UInt64, message: String) {
        let failed = liveRuntimeStorage.withLock { storage -> (
            MeetingLiveRuntimeState,
            MeetingChunkedLiveQueue?,
            MeetingChunkedLiveQueue?
        )? in
            guard storage.state.generation == generation,
                  storage.state.phase != .off,
                  storage.state.phase != .stopping else {
                return nil
            }
            let micQueue = storage.micChunkedQueue
            let systemQueue = storage.systemChunkedQueue
            storage.micChunkedQueue = nil
            storage.systemChunkedQueue = nil
            storage.state.phase = .failed
            storage.state.message = message
            return (storage.state, micQueue, systemQueue)
        }
        guard let failed else { return }
        chunkRotationQueue.sync {
            deactivateLivePreviewPipelineOnQueue()
        }
        stopPartialSessions()
        Task {
            await failed.1?.stop()
            await failed.2?.stop()
        }
        publishLiveState(failed.0)
    }

    private func rejectLiveStart(message: String) {
        let failed = liveRuntimeStorage.withLock { storage -> MeetingLiveRuntimeState? in
            guard storage.state.phase == .off || storage.state.phase == .failed else {
                return nil
            }
            storage.state.phase = .failed
            storage.state.kind = nil
            storage.state.message = message
            return storage.state
        }
        if let failed {
            publishLiveState(failed)
        }
    }

    private func isLiveGeneration(
        _ generation: UInt64,
        allowedPhases: Set<MeetingLivePhase>
    ) -> Bool {
        liveRuntimeStorage.withLock {
            $0.state.generation == generation
                && allowedPhases.contains($0.state.phase)
        }
    }

    private func publishLiveState(_ state: MeetingLiveRuntimeState) {
        onLiveStateChanged?(state)
    }

    private func publishLiveDiarizationState(
        _ state: MeetingLiveDiarizationRuntimeState
    ) {
        onLiveDiarizationStateChanged?(state)
    }

    private func failLiveDiarization(epoch: UInt64, message: String) {
        chunkRotationQueue.async { [weak self] in
            self?.failLiveDiarizationOnQueue(epoch: epoch, message: message)
        }
    }

    /// Must run on `chunkRotationQueue`. A Live diarizer failure is deliberately
    /// isolated from captions, raw capture, and Final processing.
    private func failLiveDiarizationOnQueue(epoch: UInt64, message: String) {
        let failedState = liveDiarizationStorage.withLock {
            storage -> MeetingLiveDiarizationRuntimeState? in
            guard storage.state.enabled,
                  storage.state.epoch == epoch,
                  storage.state.phase != .failed,
                  storage.state.phase != .off else {
                return nil
            }
            storage.activity.removeAll()
            storage.state.enabled = false
            storage.state.phase = .failed
            storage.state.message = message
            return storage.state
        }
        guard let failedState else { return }

        let engine = liveDiarizationEngine
        liveDiarizationPreparationTask?.cancel()
        liveDiarizationPreparationTask = nil
        liveDiarizationPreparationEpoch = nil
        liveDiarizationInferenceTask?.cancel()
        liveDiarizationInferenceTask = nil
        liveDiarizationEngine = nil
        liveDiarizationSamples.removeAll(keepingCapacity: true)
        liveDiarizationInferenceEpoch = nil
        if activeLiveSnapshot() == nil {
            systemAudioRecorder.emitsProcessedAudio = false
        }
        publishLiveDiarizationState(failedState)
        if let engine {
            Task { await engine.stop() }
        }
    }

    /// Called only on `chunkRotationQueue`. The bounded queue prevents a
    /// provisional feature from competing indefinitely with capture or Final
    /// processing. We fail closed instead of dropping samples and compressing
    /// the speaker timeline.
    private func feedLiveDiarizationOnQueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let state = liveDiarizationStorage.withLock { $0.state }
        guard state.enabled,
              state.phase == .running || state.phase == .lagging,
              liveDiarizationEngine != nil else {
            return
        }

        liveDiarizationSamples.append(contentsOf: samples)
        guard liveDiarizationSamples.count
                <= Self.liveDiarizationMaximumBufferedSampleCount else {
            failLiveDiarizationOnQueue(
                epoch: state.epoch,
                message: "Live speaker separation could not keep up. Captions and the raw recording continue unchanged."
            )
            return
        }
        updateLiveDiarizationLagStateOnQueue(epoch: state.epoch)
        scheduleLiveDiarizationInferenceOnQueue(epoch: state.epoch)
    }

    private func scheduleLiveDiarizationInferenceOnQueue(epoch: UInt64) {
        guard liveDiarizationInferenceEpoch == nil,
              liveDiarizationSamples.count >= Self.liveDiarizationBatchSampleCount,
              let engine = liveDiarizationEngine else {
            return
        }
        let batch = Array(
            liveDiarizationSamples.prefix(Self.liveDiarizationBatchSampleCount)
        )
        liveDiarizationSamples.removeFirst(Self.liveDiarizationBatchSampleCount)
        liveDiarizationInferenceEpoch = epoch

        let inferenceTask = Task.detached(priority: .utility) { [weak self, engine] in
            do {
                let activity = try await engine.process(batch)
                self?.chunkRotationQueue.async { [weak self] in
                    self?.completeLiveDiarizationInferenceOnQueue(
                        activity: activity,
                        epoch: epoch
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                self?.failLiveDiarization(epoch: epoch, message: error.localizedDescription)
            }
        }
        liveDiarizationInferenceTask = inferenceTask
    }

    private func completeLiveDiarizationInferenceOnQueue(
        activity: [MeetingDiarizationActivitySegment],
        epoch: UInt64
    ) {
        // A completion from a discarded epoch must not mutate any scheduling
        // state owned by a newer epoch.
        guard liveDiarizationInferenceEpoch == epoch else { return }
        let current = liveDiarizationStorage.withLock { $0.state }
        guard current.enabled,
              current.epoch == epoch,
              current.phase == .running || current.phase == .lagging,
              liveDiarizationEngine != nil else {
            liveDiarizationInferenceTask = nil
            liveDiarizationInferenceEpoch = nil
            return
        }

        let epochStart = liveDiarizationEpochStart
        let shifted = activity.map { segment in
            MeetingDiarizationActivitySegment(
                id: segment.id,
                speakerKey: segment.speakerKey,
                startSeconds: epochStart + segment.startSeconds,
                endSeconds: epochStart + segment.endSeconds,
                confidence: segment.confidence
            )
        }
        liveDiarizationStorage.withLock { $0.activity = shifted }
        liveDiarizationInferenceTask = nil
        liveDiarizationInferenceEpoch = nil
        updateLiveDiarizationLagStateOnQueue(epoch: epoch)
        scheduleLiveDiarizationInferenceOnQueue(epoch: epoch)
    }

    private func updateLiveDiarizationLagStateOnQueue(epoch: UInt64) {
        let bufferedCount = liveDiarizationSamples.count
        let updated = liveDiarizationStorage.withLock {
            storage -> MeetingLiveDiarizationRuntimeState? in
            guard storage.state.enabled,
                  storage.state.epoch == epoch,
                  storage.state.phase == .running || storage.state.phase == .lagging else {
                return nil
            }
            if bufferedCount >= Self.liveDiarizationLagSampleCount,
               storage.state.phase != .lagging {
                storage.state.phase = .lagging
                storage.state.message = "Live speaker labels are catching up."
                return storage.state
            }
            if bufferedCount < Self.liveDiarizationBatchSampleCount,
               storage.state.phase == .lagging {
                storage.state.phase = .running
                storage.state.message = nil
                return storage.state
            }
            return nil
        }
        if let updated {
            publishLiveDiarizationState(updated)
        }
    }

    private func liveSpeakerLabel(
        source: MeetingLiveAudioSource,
        segment: SpeechSegment
    ) -> String {
        guard source == .system else { return "You" }
        let snapshot = liveDiarizationStorage.withLock {
            ($0.state, $0.activity)
        }
        guard snapshot.0.enabled,
              snapshot.0.phase == .running || snapshot.0.phase == .lagging else {
            return "Others"
        }
        return MeetingLiveSpeakerResolver.label(
            forStart: segment.start,
            end: segment.end,
            activity: snapshot.1
        )
    }

    /// Establishes an exact "Live starts now" boundary. Audio accumulated while
    /// Live was off or while a model was loading is deliberately discarded from
    /// the preview, but remains intact in the crash-safe full-session staging.
    private func resetLivePreviewBoundaryOnQueue() {
        appendFlushedStreamingMicOnQueue()
        _ = chunkTimingTracker.rotate()
        _ = systemChunkTimingTracker.rotate()
        cleanupTemporaryChunkURLs(rawMicChunkRecorder?.rotateFile())
        cleanupTemporaryChunkURLs(systemChunkRecorder?.rotateFile())
    }

    private func micPartialSession() -> MeetingStreamingPartialSession? {
        partialSessionsStorage.withLock { $0.mic }
    }

    private func systemPartialSession() -> MeetingStreamingPartialSession? {
        partialSessionsStorage.withLock { $0.system }
    }

    private func feedMicPartialSession(_ samples: [Float]) {
        micPartialSession()?.enqueue(samples)
    }

    private func feedSystemPartialSession(_ samples: [Float]) {
        systemPartialSession()?.enqueue(samples)
    }

    private func markMicPartialBoundary(id: UUID) {
        micPartialSession()?.markSegmentBoundary(id: id)
    }

    private func markSystemPartialBoundary(id: UUID) {
        systemPartialSession()?.markSegmentBoundary(id: id)
    }

    private func commitMicPartialSegment(id: UUID) {
        micPartialSession()?.commitSegment(id: id)
    }

    private func commitSystemPartialSegment(id: UUID) {
        systemPartialSession()?.commitSegment(id: id)
    }

    private func segmentsUsingStreamingTranscript(
        _ segments: [SpeechSegment],
        partialSession: MeetingStreamingPartialSession?,
        segmentID: UUID,
        start: TimeInterval,
        end: TimeInterval
    ) -> [SpeechSegment] {
        guard let text = partialSession?.pendingSegmentText(id: segmentID) else { return segments }
        return [SpeechSegment(start: start, end: max(end, start + 0.1), text: text)]
    }

    private struct ActiveLiveSnapshot {
        let state: MeetingLiveRuntimeState
        let micQueue: MeetingChunkedLiveQueue?
        let systemQueue: MeetingChunkedLiveQueue?
    }

    private func activeLiveSnapshot() -> ActiveLiveSnapshot? {
        liveRuntimeStorage.withLock { storage in
            guard storage.state.phase == .running || storage.state.phase == .lagging else {
                return nil
            }
            return ActiveLiveSnapshot(
                state: storage.state,
                micQueue: storage.micChunkedQueue,
                systemQueue: storage.systemChunkedQueue
            )
        }
    }

    private func commitNativeStreamingPreview(
        partialSession: MeetingStreamingPartialSession?,
        source: MeetingLiveAudioSource,
        start: TimeInterval,
        end: TimeInterval,
        generation: UInt64
    ) {
        guard isLiveGeneration(generation, allowedPhases: [.running, .lagging]),
              let partialSession else {
            return
        }
        let boundaryID = UUID()
        partialSession.markSegmentBoundary(id: boundaryID)
        let segments = segmentsUsingStreamingTranscript(
            [],
            partialSession: partialSession,
            segmentID: boundaryID,
            start: start,
            end: end
        )
        partialSession.commitSegment(id: boundaryID)
        guard !segments.isEmpty else { return }
        guard isLiveGeneration(generation, allowedPhases: [.running, .lagging]) else {
            return
        }
        handleLiveSegments(segments, source: source, generation: generation)
    }

    private func suspendPartialSessions() {
        micPartialSession()?.suspend()
        systemPartialSession()?.suspend()
    }

    private func resumePartialSessions() {
        micPartialSession()?.resume()
        systemPartialSession()?.resume()
    }

    private func stopPartialSessions() {
        let sessions = partialSessionsStorage.withLock { s -> (MeetingStreamingPartialSession?, MeetingStreamingPartialSession?) in
            let taken = (s.mic, s.system)
            s.mic = nil
            s.system = nil
            s.generation = 0
            return taken
        }
        sessions.0?.stop()
        sessions.1?.stop()
    }

    private func stopPartialSessions(generation: UInt64) {
        let sessions = partialSessionsStorage.withLock {
            storage -> (MeetingStreamingPartialSession?, MeetingStreamingPartialSession?)? in
            guard storage.generation == generation else { return nil }
            let taken = (storage.mic, storage.system)
            storage.mic = nil
            storage.system = nil
            storage.generation = 0
            return taken
        }
        sessions?.0?.stop()
        sessions?.1?.stop()
    }

    func stopStreamingPartials() {
        stopLive()
    }

    func pause() {
        let shouldPause = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, !isPaused else { return false }
            appendFlushedStreamingMicOnQueue()
            rotateChunkOnQueue()
            rotateSystemChunkOnQueue()
            neuralAec.resetForStreaming()
            setPausedStateOnQueue(true)
            suspendPartialSessions()
            return true
        }
        guard shouldPause else { return }

        let suspended = liveRuntimeStorage.withLock { storage -> (
            MeetingLiveRuntimeState,
            MeetingChunkedLiveQueue?,
            MeetingChunkedLiveQueue?
        )? in
            guard storage.state.phase == .running || storage.state.phase == .lagging else {
                return nil
            }
            storage.state.phase = .suspended
            return (storage.state, storage.micChunkedQueue, storage.systemChunkedQueue)
        }
        if let suspended {
            publishLiveState(suspended.0)
            Task {
                await suspended.1?.suspend()
                await suspended.2?.suspend()
            }
        }
        let suspendedDiarization = liveDiarizationStorage.withLock {
            storage -> MeetingLiveDiarizationRuntimeState? in
            guard storage.state.enabled,
                  storage.state.phase == .running || storage.state.phase == .lagging else {
                return nil
            }
            storage.state.phase = .suspended
            storage.state.message = "Live speaker separation is paused with the recording."
            return storage.state
        }
        if let suspendedDiarization {
            publishLiveDiarizationState(suspendedDiarization)
        }
        meetingMicRecorder.pause()
        systemAudioRecorder.pause()
        Task { await screenContextCollector.setPaused(true) }
        fputs("[meeting] recording paused\n", stderr)
    }

    func resume() {
        let shouldResume = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, isPaused else { return false }
            setPausedStateOnQueue(false)
            resumePartialSessions()
            return true
        }
        guard shouldResume else { return }

        let resumed = liveRuntimeStorage.withLock { storage -> (
            MeetingLiveRuntimeState,
            MeetingChunkedLiveQueue?,
            MeetingChunkedLiveQueue?
        )? in
            guard storage.state.phase == .suspended else { return nil }
            storage.state.phase = storage.state.message == nil ? .running : .lagging
            return (storage.state, storage.micChunkedQueue, storage.systemChunkedQueue)
        }
        if let resumed {
            publishLiveState(resumed.0)
            Task {
                await resumed.1?.resume()
                await resumed.2?.resume()
            }
        }
        let resumedDiarization = liveDiarizationStorage.withLock {
            storage -> MeetingLiveDiarizationRuntimeState? in
            guard storage.state.enabled, storage.state.phase == .suspended else {
                return nil
            }
            storage.state.phase = .running
            storage.state.message = nil
            return storage.state
        }
        if let resumedDiarization {
            publishLiveDiarizationState(resumedDiarization)
        }
        meetingMicRecorder.resume()
        systemAudioRecorder.resume()
        Task { await screenContextCollector.setPaused(false) }
        fputs("[meeting] recording resumed\n", stderr)
    }

    /// Abandon the recording — stop everything, delete temp files, don't transcribe.
    func discard() {
        Task { await screenContextCollector.stopAndDrain() }
        stopLive()
        stopLiveDiarization(userInitiated: false)
        let (rawRecorder, systemRecorder) = chunkRotationQueue.sync { () -> (PCMChunkRecorder?, PCMChunkRecorder?) in
            isRecording = false
            setPausedStateOnQueue(false)
            chunkTimingTracker.discard()
            systemChunkTimingTracker.discard()
            let rawRecorder = rawMicChunkRecorder
            let systemRecorder = systemChunkRecorder
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            return (rawRecorder, systemRecorder)
        }
        micRecoveryCoordinator.finishMeeting()
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        retainedRecordingWriterError = nil
        rawAudioCapture?.discard()
        rawAudioCapture = nil
        rawRecorder?.cancel()
        systemRecorder?.cancel()
        meetingMicRecorder.onRawPCMSamples = nil
        meetingMicRecorder.onNativeAudioChunk = nil
        meetingMicRecorder.cancel()
        systemAudioRecorder.onPCMSamples = nil
        systemAudioRecorder.onNativeAudioChunk = nil
        if let url = systemAudioRecorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        micChunkCollector.cancelAll()
        systemChunkCollector.cancelAll()
        inferenceScheduler.endCapture(ownerID: inferenceCaptureOwnerID)
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop() async throws -> MeetingSessionResult {
        onProgress?(.cleaningWav)
        let endTime = Date()

        await finishLiveForMeetingEnd()
        await finishLiveDiarizationForMeetingEnd()
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        meetingMicRecorder.onRawPCMSamples = nil
        meetingMicRecorder.onNativeAudioChunk = nil
        systemAudioRecorder.onPCMSamples = nil
        systemAudioRecorder.onNativeAudioChunk = nil
        let rawStreamingMicURL = meetingMicRecorder.stop()
        let systemAudioURL = systemAudioRecorder.stop()
        let captureResult: (Date, URL?, URL?, MeetingStagedRawAudio?)
        do {
            captureResult = try chunkRotationQueue.sync { () throws -> (
                Date,
                URL?,
                URL?,
                MeetingStagedRawAudio?
            ) in
                isRecording = false
                setPausedStateOnQueue(false)

                // Flush partial AEC frame before stopping chunk recorder
                appendFlushedStreamingMicOnQueue()

                let meetingStart = self.startTime ?? Date()
                let lastRawMicURL = rawMicChunkRecorder?.stop()
                let lastSystemChunkURL = systemChunkRecorder?.stop()
                rawMicChunkRecorder = nil
                systemChunkRecorder = nil
                _ = chunkTimingTracker.finish()
                _ = systemChunkTimingTracker.finish()
                let stagedRawAudio = try rawAudioCapture?.finalize(endedAt: endTime)
                rawAudioCapture = nil
                return (
                    meetingStart,
                    lastRawMicURL,
                    lastSystemChunkURL,
                    stagedRawAudio
                )
            }
        } catch {
            inferenceScheduler.endCapture(ownerID: inferenceCaptureOwnerID)
            throw error
        }
        inferenceScheduler.endCapture(ownerID: inferenceCaptureOwnerID)
        let (meetingStart, lastRawMicURL, lastSystemChunkURL, stagedRawAudio) = captureResult
        micRecoveryCoordinator.finishMeeting()
        defer {
            if let rawStreamingMicURL {
                try? FileManager.default.removeItem(at: rawStreamingMicURL)
            }
        }
        if let lastRawMicURL {
            try? FileManager.default.removeItem(at: lastRawMicURL)
        }
        if let lastSystemChunkURL {
            try? FileManager.default.removeItem(at: lastSystemChunkURL)
        }
        micChunkCollector.cancelAll()
        systemChunkCollector.cancelAll()

        guard let stagedRawAudio else {
            throw MeetingRawAudioCaptureError.missingManifest
        }
        // Raw capture is finalized before cancellation is observed so an
        // interrupted quit always leaves a recoverable canonical recording.
        try Task.checkCancellation()
        var stagedAudio = try await MeetingRawAudioPostProcessor.prepare(
            stagedRawAudio,
            aec: neuralAec,
            supportDirectory: processingSupportDirectory,
            inferenceScheduler: inferenceScheduler
        )
        onProgress?(.writingRecording)
        let retainedRecordingURL: URL?
        if config.meetingRecordingSavePolicy == .never {
            retainedRecordingURL = nil
        } else {
            do {
                let playbackSources = try MeetingRawAudioRenderer
                    .renderForProcessing(stagedRawAudio)
                defer { playbackSources.removeTemporaryFiles() }
                retainedRecordingURL = try MeetingRecordingWriter
                    .makeTemporarySeparatedRecording(
                        microphoneURL: playbackSources.microphoneURL,
                        systemURL: playbackSources.systemURL
                    )
            } catch {
                retainedRecordingWriterError = error
                retainedRecordingURL = nil
                fputs(
                    "[meeting] failed to create separated retained recording: \(error)\n",
                    stderr
                )
            }
        }
        try Task.checkCancellation()
        stagedAudio = try MeetingProcessingCapture.markProcessing(stagedAudio)
        let finalBackend = currentBackend()
        if finalBackend.backend == BackendOption.nemotron35Multilingual.backend {
            let language = Nemotron35Language.resolved(
                stagedAudio.manifest.nemotron35Language
            )
            await transcriptionCoordinator.setNemotron35PromptId(language.promptId)
        }
        let transcriptionStartedAt = Date()
        if finalBackend.backend == BackendOption.homanWhisper.backend {
            try await transcriptionCoordinator.configureHomanWhisper(
                endpointString: config.homanWhisperEndpoint,
                apiKey: config.homanWhisperAPIKey
            )
        }
        try await transcriptionCoordinator.preloadRequired(
            backend: finalBackend,
            enablePostProcessor: false,
            includeMeetingHelpers: finalBackend.backend == BackendOption.homanWhisper.backend
        )
        try Task.checkCancellation()
        onProgress?(.transcribingAudio)
        fputs("[meeting] processing canonical microphone and system sources with \(finalBackend.label)\n", stderr)
        let finalDiarizationPolicy = finalDiarizationPolicySnapshot()
        let pipelineResult = try await MeetingTranscriptionPipeline(
            coordinator: transcriptionCoordinator
        ).process(
            stagedAudio: stagedAudio,
            backend: finalBackend,
            languages: MeetingLanguageSnapshot(
                cohereLanguage: stagedAudio.manifest.cohereLanguage,
                indicASRLanguage: stagedAudio.manifest.indicASRLanguage,
                nemotron35Language: stagedAudio.manifest.nemotron35Language
            ),
            purpose: .final,
            systemDiarization: finalDiarizationPolicy.enabled ? .optionalPost : .disabled,
            diarizationProfileID: finalDiarizationPolicy.profileID,
            progress: { [weak self] stage in
                switch stage {
                case .transcribing: self?.onProgress?(.transcribingAudio)
                case .preparingDiarizer: self?.onProgress?(.preparingDiarizer)
                case .diarizing: self?.onProgress?(.diarizing)
                case .applyingSpeakerLabels: self?.onProgress?(.applyingSpeakerLabels)
                }
            }
        )
        try Task.checkCancellation()
        guard let processedUnit = pipelineResult.units.first else {
            throw MeetingTranscriptionPipelineError.emptyTranscript
        }
        let protectedTranscriptInputs = ReconciledTranscriptInputs(
            micSegments: processedUnit.microphoneSegments,
            systemSegments: processedUnit.systemSegments,
            diarizationSegments: processedUnit.diarizationSegments
        )
        let evidencePublication = try MeetingTranscriptEvidenceFactory.makePublication(
            meetingID: 0,
            meetingStart: meetingStart,
            result: pipelineResult,
            backend: finalBackend,
            purpose: .final,
            runID: UUID()
        )
        let rawTranscript = evidencePublication.activeTranscript
        let transcriptionMetadata = MeetingProcessingMetadataFactory.transcription(
            backend: finalBackend,
            startedAt: transcriptionStartedAt
        )

        fputs(
            "[meeting] complete final pass produced \(protectedTranscriptInputs.micSegments.count) microphone and \(protectedTranscriptInputs.systemSegments.count) system segments\n",
            stderr
        )

        let manualNotes = await manualNotesProvider?()
        let generatedTitle: String
        onProgress?(.generatingTitle)
        if let liveTitle = await userEditedLiveTitle() {
            generatedTitle = liveTitle
        } else if let calendarTitle = Self.calendarTitleCandidate(
            originalTitle: title,
            calendarEventID: calendarEventID
        ) {
            generatedTitle = calendarTitle
        } else if let autoTitle = await MeetingSummaryClient.generateTitle(
            transcript: rawTranscript,
            manualNotes: manualNotes,
            config: config
        ),
           !autoTitle.isEmpty {
            generatedTitle = autoTitle
            fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
        } else {
            generatedTitle = title
        }

        let visualContext = await screenContextCollector.stopAndDrain()
        try Task.checkCancellation()
        Self.logger.info("visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(self.config.useCoreAudioTap)")
        fputs("[meeting] visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(config.useCoreAudioTap)\n", stderr)
        stagedAudio = try MeetingProcessingCapture.markState(.summarizing, for: stagedAudio)
        onProgress?(.summarizingNotes)
        let formattedNotes: String
        var summaryMetadata: MeetingProcessingRunMetadata?
        let summaryStartedAt = Date()
        do {
            let summaryResult = try await MeetingSummaryClient.summarizeWithMetadata(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                config: config,
                template: templateSnapshot,
                manualNotesToRetain: manualNotes,
                visualContext: visualContext.isEmpty ? nil : visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
            formattedNotes = summaryResult.notes
            summaryMetadata = MeetingProcessingMetadataFactory.summary(
                config: config,
                startedAt: summaryStartedAt,
                thinkingStatus: summaryResult.thinkingStatus
            )
        } catch {
            fputs("[meeting] summary generation failed: \(error.localizedDescription)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: manualNotes
            )
        }

        diagnostics?.writeFinalReport(
            title: generatedTitle,
            startedAt: meetingStart,
            endedAt: endTime,
            rawTranscript: rawTranscript,
            rawMicURL: rawStreamingMicURL,
            systemAudioURL: systemAudioURL,
            systemCapture: (systemAudioRecorder as? SystemAudioDiagnosticsProviding)?.diagnosticsSnapshot,
            micRecorder: meetingMicRecorder.diagnosticsSnapshot(),
            micHealth: micHealthTracker.snapshot(),
            aec: neuralAec.diagnosticsSnapshot,
            micChunks: micChunkHealthTracker.snapshot(),
            systemChunks: systemChunkHealthTracker.snapshot(),
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            protectedSystemSegmentCount: protectedTranscriptInputs.systemSegments.count
        )

        stagedAudio = try MeetingProcessingCapture.markState(.committing, for: stagedAudio)
        return MeetingSessionResult(
            title: generatedTitle,
            originalTitle: title,
            calendarEventID: calendarEventID,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingWriterError,
            systemRecordingURL: systemAudioURL,
            stagedAudio: stagedAudio,
            stagedRawAudio: stagedRawAudio,
            templateSnapshot: templateSnapshot,
            processingMetadata: MeetingProcessingMetadata(
                transcription: transcriptionMetadata,
                summary: summaryMetadata,
                summaryInput: MeetingSummaryInputDescriptor(
                    transcriptRevisionID: evidencePublication.transcriptRevision.id,
                    attributionRevisionID: evidencePublication.attributionRevision.id,
                    presentationMode: evidencePublication.evidence.presentation.activeMode,
                    transcriptDigest: evidencePublication.evidence.presentation.activeTextDigest,
                    ownerName: config.userName
                )
            ),
            transcriptionResult: pipelineResult,
            transcriptEvidence: evidencePublication.evidence,
            recordingStartedAt: meetingStart
        )
    }

    static func calendarTitleCandidate(originalTitle: String, calendarEventID: String?) -> String? {
        guard calendarEventID != nil else { return nil }
        guard !originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return originalTitle
    }

    static func shouldAttemptSystemRecovery(
        usesUnifiedNemotronTranscript: Bool,
        hasSystemSegments: Bool
    ) -> Bool {
        !usesUnifiedNemotronTranscript || !hasSystemSegments
    }

    private func userEditedLiveTitle() async -> String? {
        guard let candidate = await liveTitleProvider?() else { return nil }
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return nil }
        guard trimmedCandidate != trimmedOriginal else { return nil }
        return trimmedCandidate
    }

    private func appendFlushedStreamingMicOnQueue() {
        let flushed = neuralAec.flushStreamingMic()
        appendCleanedMicSamplesOnQueue(flushed)
    }

    /// Called by VAD on speech boundaries or max-duration fallback.
    /// Rotates the streaming mic file and sends the completed chunk for transcription.
    private func rotateChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateChunkOnQueue()
        }
    }

    private func rotateChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        appendFlushedStreamingMicOnQueue()
        guard let chunkTiming = chunkTimingTracker.rotate() else {
            return
        }
        guard let rawChunkURL = rawMicChunkRecorder?.rotateFile() else {
            return
        }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkEnd = chunkOffset + max(chunkTiming.durationSeconds, 0.1)
        guard let live = activeLiveSnapshot() else {
            cleanupTemporaryChunkURLs(rawChunkURL)
            return
        }

        if live.state.kind == .streaming {
            commitNativeStreamingPreview(
                partialSession: micPartialSession(),
                source: .microphone,
                start: chunkOffset,
                end: chunkEnd,
                generation: live.state.generation
            )
            cleanupTemporaryChunkURLs(rawChunkURL)
            return
        }

        guard live.state.kind == .chunked, let queue = live.micQueue else {
            cleanupTemporaryChunkURLs(rawChunkURL)
            return
        }

        fputs("[meeting] rotating raw mic chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        Task {
            await queue.enqueue(
                MeetingChunkedLiveQueue.Work(
                    url: rawChunkURL,
                    start: chunkOffset,
                    end: chunkEnd
                )
            )
        }
    }

    private func rotateSystemChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateSystemChunkOnQueue()
        }
    }

    private func rotateSystemChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        guard let chunkURL = systemChunkRecorder?.rotateFile(),
              let chunkTiming = systemChunkTimingTracker.rotate() else {
            return
        }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        guard let live = activeLiveSnapshot() else {
            try? FileManager.default.removeItem(at: chunkURL)
            return
        }

        if live.state.kind == .streaming {
            commitNativeStreamingPreview(
                partialSession: systemPartialSession(),
                source: .system,
                start: chunkOffset,
                end: chunkOffset + max(chunkDuration, 0.1),
                generation: live.state.generation
            )
            try? FileManager.default.removeItem(at: chunkURL)
            return
        }

        guard live.state.kind == .chunked, let queue = live.systemQueue else {
            try? FileManager.default.removeItem(at: chunkURL)
            return
        }

        fputs("[meeting] rotating system chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        Task {
            await queue.enqueue(
                MeetingChunkedLiveQueue.Work(
                    url: chunkURL,
                    start: chunkOffset,
                    end: chunkOffset + max(chunkDuration, 0.1)
                )
            )
        }
    }

    private func prepareRealtimeAudioPipeline() {
        configureRealtimeAudioCallbacks()
    }

    private func configureRealtimeAudioCallbacks() {
        meetingMicRecorder.onNativeAudioChunk = { [weak self] chunk in
            self?.rawAudioCapture?.append(chunk, role: .microphone)
        }
        systemAudioRecorder.onNativeAudioChunk = { [weak self] chunk in
            self?.rawAudioCapture?.append(chunk, role: .system)
        }
        meetingMicRecorder.onRawPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeMicSamples(samples)
        }
        systemAudioRecorder.onPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeSystemSamples(samples)
        }
    }

    private func activateLivePreviewPipelineOnQueue() throws {
        meetingMicRecorder.emitsProcessedAudio = true
        systemAudioRecorder.emitsProcessedAudio = true
        if rawMicChunkRecorder == nil {
            rawMicChunkRecorder = try PCMChunkRecorder(
                directoryName: "muesli-meeting-mic-chunks"
            )
        }
        if systemChunkRecorder == nil {
            systemChunkRecorder = try PCMChunkRecorder(
                directoryName: "muesli-meeting-system-chunks"
            )
        }
        guard vadController == nil, systemVadController == nil else { return }
        guard let liveVadManager else {
            fputs("[meeting-live] VAD unavailable; preview uses max-duration fallback only\n", stderr)
            return
        }

        let micController = StreamingVadController(vadManager: liveVadManager)
        micController.onChunkBoundary = { [weak self] in
            self?.chunkRotationQueue.async { [weak self] in
                self?.rotateChunkOnQueue()
            }
        }
        micController.start()
        vadController = micController

        let remoteController = StreamingVadController(vadManager: liveVadManager)
        remoteController.onChunkBoundary = { [weak self] in
            self?.chunkRotationQueue.async { [weak self] in
                self?.rotateSystemChunkOnQueue()
            }
        }
        remoteController.start()
        systemVadController = remoteController
        fputs("[meeting-live] VAD-driven preview chunking active\n", stderr)
    }

    private func deactivateLivePreviewPipelineOnQueue() {
        meetingMicRecorder.emitsProcessedAudio = false
        let diarizationState = liveDiarizationStorage.withLock { $0.state }
        systemAudioRecorder.emitsProcessedAudio = diarizationState.enabled
            && diarizationState.phase != .off
            && diarizationState.phase != .failed
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        rawMicChunkRecorder?.cancel()
        rawMicChunkRecorder = nil
        systemChunkRecorder?.cancel()
        systemChunkRecorder = nil
        _ = chunkTimingTracker.rotate()
        _ = systemChunkTimingTracker.rotate()
        neuralAec.resetForStreaming()
    }

    private func enqueueRealtimeMicSamples(_ rawSamples: [Int16]) {
        guard !rawSamples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteRawMicSamples(rawSamples)
            self.onMicHealthChanged?(healthSnapshot)
            self.micRecoveryCoordinator.process(healthSnapshot)
            guard self.activeLiveSnapshot() != nil else { return }
            let floatSamples = rawSamples.map { Float($0) / 32767.0 }

            // AEC: clean mic using position-aligned system reference
            let cleanedFloat = self.neuralAec.processStreamingMic(floatSamples)
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            // Meeting mic chunks must be driven by the cleaned mic stream. Raw
            // mic VAD sees speaker playback bleed and can create false `You`
            // chunks even when AEC removed that speech from the final mic audio.
            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }
        }
    }

    private func enqueueRealtimeSystemSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteSystemSamples(samples)
            self.onMicHealthChanged?(healthSnapshot)
            self.micRecoveryCoordinator.process(healthSnapshot)
            let live = self.activeLiveSnapshot()
            let diarizationState = self.liveDiarizationStorage.withLock { $0.state }
            let diarizationActive = diarizationState.enabled
                && (diarizationState.phase == .running
                    || diarizationState.phase == .lagging)
            guard live != nil || diarizationActive else { return }
            let floatSamples = samples.map { Float($0) / 32767.0 }
            self.systemChunkTimingTracker.append(sampleCount: samples.count)
            if diarizationActive {
                self.feedLiveDiarizationOnQueue(floatSamples)
            }
            guard live != nil else { return }

            self.systemChunkRecorder?.append(samples)
            self.feedSystemPartialSession(floatSamples)
            self.neuralAec.feedSystemSamples(floatSamples)
            let cleanedFloat = self.neuralAec.processStreamingMic([])
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }

            if let systemVadController = self.systemVadController {
                systemVadController.processAudio(floatSamples)
            }
        }
    }

    private func appendCleanedMicSamplesOnQueue(_ cleanedFloat: [Float]) {
        guard !cleanedFloat.isEmpty else { return }
        // Single funnel for all AEC'd mic audio — the streaming partial tail
        // must consume exactly the stream the mic chunks record.
        feedMicPartialSession(cleanedFloat)
        let cleanedInt16 = cleanedFloat.map { sample -> Int16 in
            Int16(max(-1.0, min(1.0, sample)) * 32767)
        }
        rawMicChunkRecorder?.append(cleanedInt16)
        chunkTimingTracker.append(sampleCount: cleanedInt16.count)
        diagnostics?.appendCleanedMicSamples(cleanedInt16)
    }

    private func transcribeMicChunk(
        rawURL: URL?,
        chunkTiming: MeetingChunkTimingSnapshot?,
        isFinalChunk: Bool,
        backend: BackendOption
    ) async -> [SpeechSegment] {
        defer {
            cleanupTemporaryChunkURLs(rawURL)
        }

        guard let chunkTiming, let rawURL else { return [] }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        let logPrefix = isFinalChunk ? "[meeting] transcribing final mic chunk" : "[meeting] transcribing mic chunk"

        return await transcribeMicChunk(
            at: rawURL,
            chunkOffset: chunkOffset,
            chunkDuration: chunkDuration,
            logPrefix: logPrefix,
            backend: backend
        ) ?? []
    }

    private func transcribeMicChunk(
        at url: URL,
        chunkOffset: TimeInterval,
        chunkDuration: TimeInterval,
        logPrefix: String,
        backend: BackendOption
    ) async -> [SpeechSegment]? {
        fputs("\(logPrefix) (offset=\(String(format: "%.0f", chunkOffset))s, source=raw)\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                at: url,
                backend: backend,
                cohereLanguage: config.resolvedCohereLanguage,
                indicASRLanguage: config.resolvedIndicASRLanguage
            )
            if !result.text.isEmpty {
                fputs("[meeting] mic chunk transcribed (raw): \"\(String(result.text.prefix(60)))...\"\n", stderr)
                let normalizedSegments = MicTurnNormalizer.normalize(
                    result: result,
                    startTime: chunkOffset,
                    endTime: chunkOffset + max(chunkDuration, 0.1)
                )
                if normalizedSegments.isEmpty {
                    micChunkHealthTracker.noteEmptyChunk()
                } else {
                    micChunkHealthTracker.noteSuccessfulChunk()
                }
                return normalizedSegments
            }
            micChunkHealthTracker.noteEmptyChunk()
            return []
        } catch {
            micChunkHealthTracker.noteFailedChunk()
            fputs("[meeting] mic chunk transcription failed (raw): \(error)\n", stderr)
            return nil
        }
    }

    private func cleanupTemporaryChunkURLs(_ urls: URL?...) {
        urls.compactMap { $0 }.forEach { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func normalizeSystemTranscription(
        result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        SystemTurnNormalizer.normalize(
            result: result,
            startTime: startTime,
            endTime: endTime
        )
    }

    private func durationSeconds(from start: Date, to end: Date) -> Double {
        max(end.timeIntervalSince(start), 0)
    }

    private func repairSystemSegmentsIfNeeded(
        existingSystemSegments: [SpeechSegment],
        systemAudioURL: URL,
        meetingStart: Date,
        endTime: Date
    ) async -> MeetingTranscriptRecoveryResult {
        let totalDuration = durationSeconds(from: meetingStart, to: endTime)

        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(systemAudioURL)
            let speechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            let health = MeetingTranscriptHealthMonitor.evaluate(
                existingSegments: existingSystemSegments,
                offlineSpeechSegments: speechSegments,
                chunkHealth: systemChunkHealthTracker.snapshot()
            )
            fputs("[meeting] system \(health.summaryLine.dropFirst("[meeting] ".count))\n", stderr)

            switch health.action {
            case .accept:
                return .none
            case .fullFallback(let reason):
                fputs("[meeting] transcript health triggered full system fallback: \(reason)\n", stderr)
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            case .selectiveRepair(let repairSegments):
                guard !repairSegments.isEmpty else { return .none }

                fputs("[meeting] repairing \(repairSegments.count) uncovered system speech regions\n", stderr)

                var repairedSegments: [SpeechSegment] = []
                for speechSegment in repairSegments {
                    let startSample = max(0, speechSegment.startSample(sampleRate: VadManager.sampleRate))
                    let endSample = min(samples.count, speechSegment.endSample(sampleRate: VadManager.sampleRate))
                    guard endSample > startSample else { continue }

                    let segmentURL = try MeetingMicRepairPlanner.writeTemporaryWAV(
                        samples: Array(samples[startSample..<endSample])
                    )
                    defer { try? FileManager.default.removeItem(at: segmentURL) }

                    let result = try await transcriptionCoordinator.transcribeMeeting(
                        at: segmentURL,
                        backend: currentBackend(),
                        cohereLanguage: config.resolvedCohereLanguage,
                        indicASRLanguage: config.resolvedIndicASRLanguage
                    )
                    repairedSegments.append(contentsOf: normalizeSystemTranscription(
                        result: result,
                        startTime: speechSegment.startTime,
                        endTime: speechSegment.endTime
                    ))
                }
                return repairedSegments.isEmpty ? .none : .append(repairedSegments)
            }
        } catch {
            fputs("[meeting] system repair pass failed: \(error)\n", stderr)
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }
    }

    private func fallbackToFullSessionSystemTranscription(
        systemAudioURL: URL,
        meetingDuration: Double
    ) async -> [SpeechSegment] {
        fputs("[meeting] no system chunks survived, falling back to full-session system transcription\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeeting(
                at: systemAudioURL,
                backend: currentBackend(),
                cohereLanguage: config.resolvedCohereLanguage,
                indicASRLanguage: config.resolvedIndicASRLanguage
            )
            return normalizeSystemTranscription(
                result: result,
                startTime: 0,
                endTime: meetingDuration
            )
        } catch {
            fputs("[meeting] full-session system fallback transcription failed: \(error)\n", stderr)
            return []
        }
    }
}
