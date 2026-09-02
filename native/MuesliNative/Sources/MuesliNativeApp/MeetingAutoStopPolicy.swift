import Foundation

enum MeetingRecordingStartOrigin: Equatable {
    case manual
    case detectedPrompt
    case calendarAutoRecord
    case scheduledMeetingPrompt
    case joinAndRecord

    /// A missing detector signal is useful diagnostic evidence, but it is not
    /// proof that a recording should end. User-initiated and unattended starts
    /// can therefore opt into signal-loss warnings without granting the
    /// detector authority to stop capture.
    var tracksMeetingSignalLoss: Bool {
        switch self {
        case .manual:
            return false
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return true
        }
    }

    var signalLossResponse: MeetingSignalLossResponse {
        tracksMeetingSignalLoss ? .warnOnly : .none
    }

    var diagnosticName: String {
        switch self {
        case .manual: return "manual"
        case .detectedPrompt: return "detected_prompt"
        case .calendarAutoRecord: return "calendar_auto_record"
        case .scheduledMeetingPrompt: return "scheduled_meeting_prompt"
        case .joinAndRecord: return "join_and_record"
        }
    }

    func signalLossSource(
        explicitSource: MeetingAutoStopSource?,
        recentSource: @autoclosure () -> MeetingAutoStopSource?
    ) -> MeetingAutoStopSource? {
        switch self {
        case .manual:
            return nil
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return explicitSource ?? recentSource()
        }
    }
}

enum MeetingSignalLossResponse: Equatable {
    case none
    case warnOnly

    var diagnosticName: String {
        switch self {
        case .none: return "none"
        case .warnOnly: return "warn_only"
        }
    }
}

enum MeetingSignalLossPromptEvent: Equatable {
    case stopRequested
    case dismissedByUser
    case autoDismissed
    case presentationUnavailable

    var diagnosticName: String {
        switch self {
        case .stopRequested: return "stop_requested"
        case .dismissedByUser: return "dismissed_by_user"
        case .autoDismissed: return "auto_dismissed"
        case .presentationUnavailable: return "presentation_unavailable"
        }
    }
}

enum MeetingSignalLossPromptResolution: Equatable {
    case keepRecording
    case stopRecording
}

/// Central safety boundary for the signal-loss prompt. Only an explicit click
/// on Stop Recording may end capture; timer expiry and UI failures fail safe.
enum MeetingSignalLossPromptPolicy {
    static func resolution(
        for event: MeetingSignalLossPromptEvent
    ) -> MeetingSignalLossPromptResolution {
        switch event {
        case .stopRequested:
            return .stopRecording
        case .dismissedByUser, .autoDismissed, .presentationUnavailable:
            return .keepRecording
        }
    }
}

struct MeetingSignalLossPromptState: Equatable {
    private(set) var isPromptSuppressed = false
    private(set) var isDismissedForRecording = false

    var canPresentPrompt: Bool {
        !isPromptSuppressed && !isDismissedForRecording
    }

    mutating func resetForRecording() {
        isPromptSuppressed = false
        isDismissedForRecording = false
    }

    mutating func markPromptPresented() {
        isPromptSuppressed = true
    }

    mutating func markSourceRecovered() {
        isPromptSuppressed = false
    }

    mutating func markDismissedByUser() {
        isPromptSuppressed = true
        isDismissedForRecording = true
    }

    mutating func markAutoDismissed() {
        isPromptSuppressed = true
    }
}

struct MeetingAutoStopSource: Equatable {
    let candidateID: String?
    let suppressionID: String?
    let normalizedURL: String?
    let sourceBundleID: String?
    let continuityIdentity: MeetingContinuityIdentity?
    let hasObservedCandidate: Bool

    private init(
        candidateID: String?,
        suppressionID: String?,
        normalizedURL: String?,
        sourceBundleID: String?,
        continuityIdentity: MeetingContinuityIdentity?,
        hasObservedCandidate: Bool
    ) {
        self.candidateID = candidateID
        self.suppressionID = suppressionID
        self.normalizedURL = normalizedURL
        self.sourceBundleID = sourceBundleID
        self.continuityIdentity = continuityIdentity
        self.hasObservedCandidate = hasObservedCandidate
    }

    init(candidate: MeetingCandidate) {
        self.candidateID = candidate.id
        self.suppressionID = candidate.suppressionID
        self.normalizedURL = candidate.url
        self.sourceBundleID = candidate.sourceBundleID
        self.continuityIdentity = candidate.continuityIdentity
        self.hasObservedCandidate = true
    }

    init?(meetingURL: URL) {
        guard let normalized = MeetingURLNormalizer.normalize(meetingURL.absoluteString) else {
            return nil
        }
        self.candidateID = normalized.id
        self.suppressionID = normalized.id
        self.normalizedURL = normalized.url
        self.sourceBundleID = nil
        self.continuityIdentity = .browserRoom(normalizedURL: normalized.url)
        self.hasObservedCandidate = false
    }

    func refined(with candidate: MeetingCandidate) -> MeetingAutoStopSource {
        let refinedSuppressionID = candidate.suppressionID == candidate.id
            ? suppressionID ?? candidate.suppressionID
            : candidate.suppressionID
        return MeetingAutoStopSource(
            candidateID: candidateID ?? candidate.id,
            suppressionID: refinedSuppressionID,
            normalizedURL: normalizedURL ?? candidate.url,
            sourceBundleID: sourceBundleID ?? candidate.sourceBundleID,
            continuityIdentity: continuityIdentity ?? candidate.continuityIdentity,
            hasObservedCandidate: true
        )
    }
}

struct MeetingAutoStopTracker: Equatable {
    private(set) var source: MeetingAutoStopSource?
    private(set) var lastSeenAt: Date?
    private var observedBeforeRecordingStarted = false

    var isArmed: Bool {
        source != nil
    }

    mutating func arm(source: MeetingAutoStopSource?) {
        self.source = source
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
    }

    mutating func disarm() {
        source = nil
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
    }

    mutating func observeBeforeRecordingStarted(candidate: MeetingCandidate?) {
        guard let currentSource = source,
              let candidate,
              MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) else {
            return
        }
        source = currentSource.refined(with: candidate)
        observedBeforeRecordingStarted = true
    }

    mutating func markRecordingStarted(now: Date) {
        guard observedBeforeRecordingStarted, lastSeenAt == nil else { return }
        lastSeenAt = now
        observedBeforeRecordingStarted = false
    }

    mutating func observe(
        candidate: MeetingCandidate?,
        now: Date,
        gracePeriod: TimeInterval
    ) -> Bool {
        guard let currentSource = source else {
            return false
        }

        if let candidate,
           MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) {
            source = currentSource.refined(with: candidate)
            lastSeenAt = now
            return false
        }

        guard let lastSeenAt else {
            return false
        }

        return now.timeIntervalSince(lastSeenAt) >= gracePeriod
    }
}

enum MeetingAutoStopPolicy {
    static func matches(candidate: MeetingCandidate, source: MeetingAutoStopSource) -> Bool {
        if let candidateID = source.candidateID, candidate.id == candidateID {
            return true
        }

        if let suppressionID = source.suppressionID, candidate.suppressionID == suppressionID {
            return true
        }

        if let normalizedURL = source.normalizedURL, candidate.url == normalizedURL {
            return true
        }

        if let continuityIdentity = source.continuityIdentity,
           candidate.continuityIdentity == continuityIdentity {
            return true
        }

        return false
    }
}
