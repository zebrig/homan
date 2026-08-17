import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting transcription pipeline")
struct MeetingTranscriptionPipelineTests {
    @Test(
        "source-aware final output preserves authoritative roles",
        arguments: [
            PipelineScenario(
                name: "microphone only",
                microphone: .init(
                    text: "local",
                    segments: [.init(start: 0, end: 1, text: "local")]
                ),
                system: .init(text: "", segments: []),
                expectedRoles: [.you]
            ),
            PipelineScenario(
                name: "system only",
                microphone: .init(text: "", segments: []),
                system: .init(
                    text: "remote",
                    segments: [.init(start: 0, end: 1, text: "remote")]
                ),
                expectedRoles: [.others]
            ),
            PipelineScenario(
                name: "alternating",
                microphone: .init(
                    text: "local",
                    segments: [.init(start: 0, end: 1, text: "local")]
                ),
                system: .init(
                    text: "remote",
                    segments: [.init(start: 2, end: 3, text: "remote")]
                ),
                expectedRoles: [.you, .others]
            ),
            PipelineScenario(
                name: "overlapping",
                microphone: .init(
                    text: "local overlap",
                    segments: [.init(start: 0, end: 0.1, text: "local overlap")]
                ),
                system: .init(
                    text: "remote overlap",
                    segments: [.init(start: 0, end: 0.1, text: "remote overlap")]
                ),
                expectedRoles: [.you, .others]
            ),
        ]
    )
    func preservesSourceRoles(_ scenario: PipelineScenario) async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let provider = PipelineTranscriptionProvider(
            results: [
                "mic-cleaned.wav": scenario.microphone,
                "system.wav": scenario.system,
            ]
        )
        let pipeline = MeetingTranscriptionPipeline(provider: provider)

        let result = try await pipeline.process(
            MeetingTranscriptionRequest(
                units: [.sourceBundle(.init(
                    recording: nil,
                    playbackURL: nil,
                    bundle: fixture.bundle
                ))],
                backend: .parakeetMultilingual,
                languages: .init(),
                purpose: .final,
                systemDiarization: .disabled
            )
        )

        #expect(result.attributedTurns.map(\.sourceRole) == scenario.expectedRoles)
        #expect(result.attributedTurns.allSatisfy { !$0.isProvisional })
        #expect(result.formattedTranscript.contains("You:") == scenario.expectedRoles.contains(.you))
        #expect(result.formattedTranscript.contains("Others:") == scenario.expectedRoles.contains(.others))
    }

    @Test("disabled speaker analysis retains source identity without invoking a diarizer")
    func disabledDiarizationRetainsTimelineEvidence() async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let provider = DiarizationCountingPipelineProvider()

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: [.sourceBundle(.init(
                    recording: nil,
                    playbackURL: nil,
                    bundle: fixture.bundle
                ))],
                backend: .parakeetMultilingual,
                languages: .init(),
                purpose: .final,
                systemDiarization: .disabled
            )
        )

        #expect(result.systemTimelineMap != nil)
        #expect(result.attributedTurns.map(\.sourceRole) == [.others])
        #expect(await provider.diarizationCount == 0)
    }

    @Test("optional diarization failure falls back to Others")
    func optionalDiarizationFailureFallsBack() async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let provider = PipelineTranscriptionProvider(
            results: [
                "mic-cleaned.wav": .init(text: "", segments: []),
                "system.wav": .init(
                    text: "remote",
                    segments: [.init(start: 0, end: 1, text: "remote")]
                ),
            ],
            diarizationError: PipelineTestError.diarizationFailed
        )

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: [.sourceBundle(.init(
                    recording: nil,
                    playbackURL: nil,
                    bundle: fixture.bundle
                ))],
                backend: .parakeetMultilingual,
                languages: .init(),
                purpose: .final,
                systemDiarization: .optionalPost
            )
        )

        #expect(result.attributedTurns.map(\.sourceRole) == [.others])
        #expect(result.attributedTurns.first?.remoteSpeaker == nil)
        #expect(result.degradations.contains(.optionalDiarizationFailed))
        #expect(result.formattedTranscript.contains("Others: remote"))
    }

    @Test("compatible speaker evidence is reused without a diarizer pass")
    func compatibleDiarizationIsReused() async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let units: [MeetingRecordingUnitInput] = [.sourceBundle(.init(
            recording: nil,
            playbackURL: nil,
            bundle: fixture.bundle
        ))]
        let reusable = try makeReusableDiarization(
            units: units,
            meetingStart: fixture.bundle.manifest.startedAt
        )
        let provider = PipelineTranscriptionProvider(results: [
            "mic-cleaned.wav": .init(text: "", segments: []),
            "system.wav": .init(
                text: "remote",
                segments: [.init(start: 0, end: 0.05, text: "remote")]
            ),
        ])

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: units,
                backend: .parakeetMultilingual,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .reuseCompatible,
                diarizationProfileID: .automatic,
                reusableDiarization: reusable
            )
        )

        #expect(result.reusedDiarizationRevisionID == reusable.id)
        #expect(result.diarizationProfile == reusable.profile)
        #expect(result.attributedTurns.first?.remoteSpeaker != nil)
    }

    @Test("explicit reuse rejects a stale speaker profile instead of silently collapsing")
    func explicitReuseRejectsStaleProfile() async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let units: [MeetingRecordingUnitInput] = [.sourceBundle(.init(
            recording: nil,
            playbackURL: nil,
            bundle: fixture.bundle
        ))]
        let current = try makeReusableDiarization(
            units: units,
            meetingStart: fixture.bundle.manifest.startedAt
        )
        let staleProfile = MeetingDiarizationProfileSnapshot(
            profileID: current.profile.profileID,
            profileRevision: current.profile.profileRevision - 1,
            engineID: current.profile.engineID,
            engineVersion: current.profile.engineVersion,
            modelRevision: current.profile.modelRevision,
            modelDigest: current.profile.modelDigest,
            effectiveConfigurationDigest: current.profile.effectiveConfigurationDigest,
            maximumSpeakers: current.profile.maximumSpeakers
        )
        let stale = MeetingDiarizationRevision(
            meetingID: current.meetingID,
            runID: current.runID,
            timelineDigest: current.timelineDigest,
            timelineMap: current.timelineMap,
            sourceFingerprints: current.sourceFingerprints,
            profile: staleProfile,
            activitySegments: current.activitySegments,
            audioDurationSeconds: current.audioDurationSeconds
        )
        let provider = PipelineTranscriptionProvider(results: [
            "mic-cleaned.wav": .init(text: "", segments: []),
            "system.wav": .init(
                text: "remote",
                segments: [.init(start: 0, end: 0.05, text: "remote")]
            ),
        ])

        await #expect(throws: MeetingTranscriptionPipelineError.compatibleDiarizationUnavailable) {
            _ = try await MeetingTranscriptionPipeline(provider: provider).process(
                MeetingTranscriptionRequest(
                    units: units,
                    backend: .parakeetMultilingual,
                    languages: .init(),
                    purpose: .retranscribe,
                    systemDiarization: .reuseCompatible,
                    diarizationProfileID: .automatic,
                    reusableDiarization: stale
                )
            )
        }
    }

    @Test("opportunistic reuse reruns the diarizer when captured evidence is stale")
    func opportunisticReuseFallsBackToFreshAnalysis() async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let units: [MeetingRecordingUnitInput] = [.sourceBundle(.init(
            recording: nil,
            playbackURL: nil,
            bundle: fixture.bundle
        ))]
        let current = try makeReusableDiarization(
            units: units,
            meetingStart: fixture.bundle.manifest.startedAt
        )
        let staleProfile = MeetingDiarizationProfileSnapshot(
            profileID: current.profile.profileID,
            profileRevision: current.profile.profileRevision - 1,
            engineID: current.profile.engineID,
            engineVersion: current.profile.engineVersion,
            modelRevision: current.profile.modelRevision,
            modelDigest: current.profile.modelDigest,
            effectiveConfigurationDigest: current.profile.effectiveConfigurationDigest,
            maximumSpeakers: current.profile.maximumSpeakers
        )
        let stale = MeetingDiarizationRevision(
            meetingID: current.meetingID,
            runID: current.runID,
            timelineDigest: current.timelineDigest,
            timelineMap: current.timelineMap,
            sourceFingerprints: current.sourceFingerprints,
            profile: staleProfile,
            activitySegments: current.activitySegments,
            audioDurationSeconds: current.audioDurationSeconds
        )
        let provider = PipelineTranscriptionProvider(
            results: [
                "mic-cleaned.wav": .init(text: "", segments: []),
                "system.wav": .init(
                    text: "remote",
                    segments: [.init(start: 0, end: 0.05, text: "remote")]
                ),
            ],
            diarizationSegments: [
                TimedSpeakerSegment(
                    speakerId: "fresh-speaker",
                    embedding: [],
                    startTimeSeconds: 0,
                    endTimeSeconds: 0.05,
                    qualityScore: 1
                ),
            ]
        )

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: units,
                backend: .parakeetMultilingual,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .optionalPost,
                diarizationProfileID: .automatic,
                reusableDiarization: stale
            )
        )

        #expect(result.reusedDiarizationRevisionID == nil)
        #expect(result.diarizationProfile?.profileRevision
            == MeetingDiarizationProfiles.resolve(.automatic).revision)
        #expect(result.attributedTurns.first?.remoteSpeaker != nil)
    }

    private func makeReusableDiarization(
        units: [MeetingRecordingUnitInput],
        meetingStart: Date
    ) throws -> MeetingDiarizationRevision {
        let rendered = try MeetingSystemTimelineRenderer.render(
            units: units,
            meetingStart: meetingStart
        )
        defer { rendered.removeTemporaryFile() }
        let definition = MeetingDiarizationProfiles.resolve(.automatic)
        return MeetingDiarizationRevision(
            meetingID: 42,
            runID: UUID(),
            timelineDigest: rendered.map.digest,
            timelineMap: rendered.map,
            sourceFingerprints: rendered.map.sourceFingerprints,
            profile: definition.snapshot(modelDigest: "fixture-model-digest"),
            activitySegments: [
                MeetingDiarizationActivitySegment(
                    speakerKey: "remote-a",
                    startSeconds: 0,
                    endSeconds: max(0.05, rendered.map.totalDurationSeconds)
                ),
            ],
            audioDurationSeconds: rendered.map.totalDurationSeconds
        )
    }

    @Test("units and equal-time source turns have stable chronological order")
    func stableOrdering() async throws {
        let later = try PipelineBundleFixture(
            sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            startedAt: Date(timeIntervalSince1970: 2_000),
            filePrefix: "later-"
        )
        let earlier = try PipelineBundleFixture(
            sessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            startedAt: Date(timeIntervalSince1970: 1_000),
            filePrefix: "earlier-"
        )
        defer {
            later.cleanup()
            earlier.cleanup()
        }
        let provider = PipelineTranscriptionProvider(results: [
            "later-mic-cleaned.wav": .init(
                text: "later local",
                segments: [.init(start: 0, end: 1, text: "later local")]
            ),
            "later-system.wav": .init(
                text: "later remote",
                segments: [.init(start: 0, end: 1, text: "later remote")]
            ),
            "earlier-mic-cleaned.wav": .init(
                text: "earlier local",
                segments: [.init(start: 0, end: 1, text: "earlier local")]
            ),
            "earlier-system.wav": .init(
                text: "earlier remote",
                segments: [.init(start: 0, end: 1, text: "earlier remote")]
            ),
        ])

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: [
                    .sourceBundle(.init(recording: nil, playbackURL: nil, bundle: later.bundle)),
                    .sourceBundle(.init(recording: nil, playbackURL: nil, bundle: earlier.bundle)),
                ],
                backend: .parakeetMultilingual,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .disabled
            )
        )

        #expect(result.attributedTurns.map(\.text) == [
            "earlier local",
            "earlier remote",
            "later local",
            "later remote",
        ])
        #expect(result.attributedTurns.map(\.sourceRole) == [.you, .others, .you, .others])
    }

    @Test("post transcription uses VAD boundaries to preserve conversational turns")
    func postTranscriptionPreservesVADTurns() async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let provider = VADSegmentingPipelineProvider()

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: [.sourceBundle(.init(
                    recording: nil,
                    playbackURL: nil,
                    bundle: fixture.bundle
                ))],
                backend: .whisperSmall,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .disabled
            )
        )

        #expect(result.attributedTurns.map(\.sourceRole) == [.you, .others, .you])
        #expect(result.attributedTurns.map(\.startSeconds) == [0.0, 0.03, 0.07])
        #expect(await provider.transcriptionCount == 3)
    }

    @Test("local Final ASR yields to capture before VAD and every bounded utterance")
    func localFinalASRYieldsToCapture() async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let provider = VADSegmentingPipelineProvider()
        let scheduler = MeetingInferenceScheduler()
        let captureOwner = UUID()
        scheduler.beginCapture(ownerID: captureOwner)

        let processing = Task {
            try await MeetingTranscriptionPipeline(
                provider: provider,
                inferenceScheduler: scheduler
            ).process(MeetingTranscriptionRequest(
                units: [.sourceBundle(.init(
                    recording: nil,
                    playbackURL: nil,
                    bundle: fixture.bundle
                ))],
                backend: .whisperSmall,
                languages: .init(),
                purpose: .final,
                systemDiarization: .disabled
            ))
        }
        try await Task.sleep(for: .milliseconds(25))
        #expect(await provider.speechSegmentationCount == 0)

        scheduler.endCapture(ownerID: captureOwner)
        let result = try await processing.value
        #expect(!result.attributedTurns.isEmpty)
        #expect(await provider.speechSegmentationCount == 2)
        #expect(await provider.transcriptionCount == 3)
    }

    @Test("Homan Whisper batches canonical sources and composes local speaker analysis")
    func homanWhisperUsesOneSourceAwareBatch() async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let provider = HomanWhisperBatchPipelineProvider()

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: [.sourceBundle(.init(
                    recording: nil,
                    playbackURL: nil,
                    bundle: fixture.bundle
                ))],
                backend: .homanWhisper,
                languages: .init(),
                purpose: .final,
                systemDiarization: .optionalPost
            )
        )

        #expect(await provider.batchCount == 1)
        #expect(await provider.submittedItems.map(\.source) == [.microphone, .system])
        #expect(await provider.submittedItems.map(\.id) == [
            "u0000-microphone-0000",
            "u0000-system-0000",
        ])
        #expect(await provider.diarizationCount == 1)
        #expect(result.attributedTurns.map(\.sourceRole) == [.you, .others])
        #expect(result.formattedTranscript.contains("You: local remote batch"))
        #expect(result.formattedTranscript.contains("Speaker 1: system remote batch"))
        #expect(result.units.count == 1)
        #expect(result.units[0].recognizedSegments.map(\.id) == [
            "u0000-microphone-0000/segment-0",
            "u0000-system-0000/segment-0",
        ])
        #expect(Set(result.units[0].recognizedSegments.map(\.id)).count == 2)
    }

    @Test(
        "a valid source remains usable when its peer is unavailable",
        arguments: [
            PipelineDegradedScenario(
                name: "microphone only",
                microphone: .valid,
                system: .empty,
                expectedRole: .you,
                expectedDegradation: .sourceEmpty(.system)
            ),
            PipelineDegradedScenario(
                name: "system only",
                microphone: .empty,
                system: .valid,
                expectedRole: .others,
                expectedDegradation: .sourceEmpty(.microphone)
            ),
            PipelineDegradedScenario(
                name: "system file missing",
                microphone: .valid,
                system: .missing,
                expectedRole: .you,
                expectedDegradation: .sourceMissing(.system)
            ),
            PipelineDegradedScenario(
                name: "system file corrupt",
                microphone: .valid,
                system: .corrupt,
                expectedRole: .you,
                expectedDegradation: .sourceCorrupt(.system)
            ),
        ]
    )
    func processesSurvivingSource(_ scenario: PipelineDegradedScenario) async throws {
        let fixture = try PipelineBundleFixture(
            microphoneState: scenario.microphone,
            systemState: scenario.system
        )
        defer { fixture.cleanup() }
        let provider = PipelineTranscriptionProvider(results: [
            "mic-cleaned.wav": .init(
                text: "local",
                segments: [.init(start: 0, end: 1, text: "local")]
            ),
            "system.wav": .init(
                text: "remote",
                segments: [.init(start: 0, end: 1, text: "remote")]
            ),
        ])

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: [.sourceBundle(.init(
                    recording: nil,
                    playbackURL: nil,
                    bundle: fixture.bundle
                ))],
                backend: .parakeetMultilingual,
                languages: .init(),
                purpose: .final,
                systemDiarization: .disabled
            )
        )

        #expect(result.attributedTurns.map(\.sourceRole) == [scenario.expectedRole])
        #expect(result.degradations.contains(scenario.expectedDegradation))
    }

    @Test("both invalid canonical sources fail without altering retained media")
    func bothInvalidSourcesFail() async throws {
        let fixture = try PipelineBundleFixture(
            microphoneState: .missing,
            systemState: .corrupt
        )
        defer { fixture.cleanup() }

        await #expect(throws: MeetingTranscriptionPipelineError.noUsableAudio) {
            _ = try await MeetingTranscriptionPipeline(
                provider: PipelineTranscriptionProvider(results: [:])
            ).process(MeetingTranscriptionRequest(
                units: [.sourceBundle(.init(
                    recording: nil,
                    playbackURL: nil,
                    bundle: fixture.bundle
                ))],
                backend: .parakeetMultilingual,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .optionalPost
            ))
        }

        fixture.support.assertExists(fixture.bundle.directoryURL)
    }

    @Test("recognition failure on one source preserves its valid peer")
    func recognitionFailureIsIsolated() async throws {
        let fixture = try PipelineBundleFixture()
        defer { fixture.cleanup() }
        let provider = PipelineTranscriptionProvider(results: [
            "mic-cleaned.wav": .init(
                text: "local",
                segments: [.init(start: 0, end: 1, text: "local")]
            ),
        ])

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: [.sourceBundle(.init(
                    recording: nil,
                    playbackURL: nil,
                    bundle: fixture.bundle
                ))],
                backend: .whisperSmall,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .optionalPost
            )
        )

        #expect(result.attributedTurns.map(\.sourceRole) == [.you])
        #expect(result.degradations.contains(.sourceRecognitionFailed(.system)))
    }

    @Test("future source schema uses mixed playback without fabricating You")
    func futureSchemaMixedFallback() async throws {
        let support = try MeetingRecordingBundleTestSupport(testName: "future-pipeline")
        defer { support.cleanup() }
        let playback = try support.makePlaybackFile(named: "future.wav")
        let recording = MeetingRecordingRecord(
            id: 9,
            meetingID: 42,
            path: playback.path,
            createdAt: Date(timeIntervalSince1970: 1_000),
            deleteAfter: nil
        )
        let provider = PipelineTranscriptionProvider(results: [
            playback.lastPathComponent: .init(
                text: "mixed voices",
                segments: [.init(start: 0, end: 1, text: "mixed voices")]
            ),
        ])

        let result = try await MeetingTranscriptionPipeline(provider: provider).process(
            MeetingTranscriptionRequest(
                units: [.legacyMixed(.init(
                    recording: recording,
                    playbackURL: playback,
                    degradations: [.sourceBundleVersionUnsupported(99)]
                ))],
                backend: .whisperSmall,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .optionalPost
            )
        )

        #expect(result.attributedTurns.map(\.sourceRole) == [.legacyUnknown])
        #expect(!result.formattedTranscript.contains("You:"))
        #expect(result.formattedTranscript.contains("Speaker: mixed voices"))
        #expect(result.degradations.contains(.legacySourceIdentityUnavailable))
        #expect(result.degradations.contains(.sourceBundleVersionUnsupported(99)))
        support.assertExists(playback)
    }

    @Test("schema-v2 raw bundle is reprocessed into separate source roles")
    func rawBundleReprocessingPreservesRoles() async throws {
        let support = try MeetingRecordingBundleTestSupport(
            testName: "raw-pipeline"
        )
        defer { support.cleanup() }
        let capture = try MeetingRawAudioCapture(
            meetingID: 42,
            startedAt: Date(timeIntervalSince1970: 1_000),
            timelineAnchorNanoseconds: 10_000,
            finalModelID: .parakeetRealtimeEOU,
            supportDirectory: support.supportDirectory,
            compactLosslessly: true
        )
        capture.append(
            rawPipelineChunk(samples: [1_000, 2_000], timestamp: 10_000),
            role: .microphone
        )
        capture.append(
            rawPipelineChunk(samples: [3_000, 4_000], timestamp: 10_000),
            role: .system
        )
        let raw = try capture.finalize(
            endedAt: Date(timeIntervalSince1970: 1_001)
        )
        let bundle = try MeetingRecordingBundlePublisher.publish(
            stagedRawAudio: raw,
            playbackURL: try support.makePlaybackFile(),
            supportDirectory: support.supportDirectory
        )
        let pipeline = MeetingTranscriptionPipeline(
            provider: RawPipelineProvider(),
            aecFactory: { _ in
                MeetingNeuralAec(
                    preloadedProcessor: RawPipelinePassThroughAec()
                )
            }
        )

        let result = try await pipeline.process(
            MeetingTranscriptionRequest(
                units: [
                    .sourceBundle(.init(
                        recording: nil,
                        playbackURL: nil,
                        bundle: bundle
                    )),
                ],
                backend: .parakeetMultilingual,
                languages: .init(),
                purpose: .retranscribe,
                systemDiarization: .disabled
            )
        )

        #expect(result.attributedTurns.map(\.sourceRole) == [.you, .others])
        #expect(result.attributedTurns.map(\.text) == ["local", "remote"])
    }

    private func rawPipelineChunk(
        samples: [Int16],
        timestamp: UInt64
    ) -> CapturedAudioChunk {
        CapturedAudioChunk(
            format: CapturedAudioFormat(
                sampleRate: 16_000,
                channelCount: 1,
                sampleRepresentation: .signedInt16,
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
}

struct PipelineScenario: Sendable, CustomTestStringConvertible {
    let name: String
    let microphone: SpeechTranscriptionResult
    let system: SpeechTranscriptionResult
    let expectedRoles: [MeetingTranscriptRole]

    var testDescription: String { name }
}

struct PipelineDegradedScenario: Sendable, CustomTestStringConvertible {
    let name: String
    let microphone: PipelineFixtureSourceState
    let system: PipelineFixtureSourceState
    let expectedRole: MeetingTranscriptRole
    let expectedDegradation: MeetingProcessingDegradation

    var testDescription: String { name }
}

enum PipelineFixtureSourceState: Equatable, Sendable {
    case valid
    case empty
    case missing
    case corrupt
}

private enum PipelineTestError: Error {
    case diarizationFailed
    case missingResult
}

private struct RawPipelineProvider: MeetingTranscriptionProviding {
    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        let isMicrophone = url.deletingLastPathComponent().lastPathComponent
            == "muesli-meeting-post-aec"
        let text = isMicrophone ? "local" : "remote"
        return SpeechTranscriptionResult(
            text: text,
            segments: [
                SpeechSegment(
                    start: isMicrophone ? 0 : 1,
                    end: isMicrophone ? 0.5 : 1.5,
                    text: text
                ),
            ]
        )
    }

    func meetingDiarizationSegments(
        at url: URL
    ) async throws -> [TimedSpeakerSegment]? {
        nil
    }
}

private final class RawPipelinePassThroughAec: MeetingAecProcessor {
    let name = "test-pass-through"
    let frameSize = 2
    let sampleRate = 16_000

    func reset() {}

    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        mic
    }
}

private final class PipelineTranscriptionProvider: MeetingTranscriptionProviding, @unchecked Sendable {
    private let results: [String: SpeechTranscriptionResult]
    private let diarizationError: Error?
    private let diarizationSegments: [TimedSpeakerSegment]?

    init(
        results: [String: SpeechTranscriptionResult],
        diarizationError: Error? = nil,
        diarizationSegments: [TimedSpeakerSegment]? = nil
    ) {
        self.results = results
        self.diarizationError = diarizationError
        self.diarizationSegments = diarizationSegments
    }

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        guard let result = results[url.lastPathComponent] else {
            throw PipelineTestError.missingResult
        }
        return result
    }

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        if let diarizationError {
            throw diarizationError
        }
        return diarizationSegments
    }
}

private actor VADSegmentingPipelineProvider: MeetingTranscriptionProviding {
    private(set) var transcriptionCount = 0
    private(set) var speechSegmentationCount = 0

    func meetingSpeechSegments(at url: URL) async throws -> [VadSegment]? {
        speechSegmentationCount += 1
        if url.lastPathComponent.contains("mic-cleaned") {
            return [
                VadSegment(startTime: 0.0, endTime: 0.02),
                VadSegment(startTime: 0.07, endTime: 0.09),
            ]
        }
        return [VadSegment(startTime: 0.03, endTime: 0.06)]
    }

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        transcriptionCount += 1
        return SpeechTranscriptionResult(
            text: "utterance \(transcriptionCount)",
            segments: []
        )
    }

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        nil
    }
}

private actor DiarizationCountingPipelineProvider: MeetingTranscriptionProviding {
    private(set) var diarizationCount = 0

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        guard url.lastPathComponent == "system.wav" else {
            return SpeechTranscriptionResult(text: "", segments: [])
        }
        return SpeechTranscriptionResult(
            text: "remote",
            segments: [SpeechSegment(start: 0, end: 0.05, text: "remote")]
        )
    }

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        diarizationCount += 1
        return []
    }
}

private actor HomanWhisperBatchPipelineProvider:
    MeetingTranscriptionProviding,
    MeetingBatchTranscriptionProviding
{
    private(set) var batchCount = 0
    private(set) var submittedItems: [RemoteMeetingSpeechItem] = []
    private(set) var diarizationCount = 0

    func meetingSpeechSegments(at url: URL) async throws -> [VadSegment]? {
        if url.lastPathComponent.contains("mic-cleaned") {
            return [VadSegment(startTime: 0.0, endTime: 0.03)]
        }
        return [VadSegment(startTime: 0.04, endTime: 0.07)]
    }

    func transcribeMeetingBatch(
        items: [RemoteMeetingSpeechItem],
        requestID: UUID
    ) async throws -> [RemoteMeetingSpeechResult] {
        batchCount += 1
        submittedItems = items
        return items.map { item in
            RemoteMeetingSpeechResult(
                id: item.id,
                source: item.source,
                start: item.start,
                end: item.end,
                text: item.source == .microphone
                    ? "local remote batch"
                    : "system remote batch",
                segments: [RemoteMeetingSpeechSubsegment(
                    // IDs are intentionally item-local and therefore repeat
                    // across the batch. The pipeline must namespace them.
                    id: "segment-0",
                    start: item.start,
                    end: item.end,
                    text: item.source == .microphone
                        ? "local remote batch"
                        : "system remote batch"
                )]
            )
        }
    }

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        throw PipelineTestError.missingResult
    }

    func meetingDiarizationSegments(at url: URL) async throws -> [TimedSpeakerSegment]? {
        diarizationCount += 1
        return [TimedSpeakerSegment(
            speakerId: "remote-a",
            embedding: [],
            startTimeSeconds: 0.04,
            endTimeSeconds: 0.07,
            qualityScore: 0.95
        )]
    }
}

private struct PipelineBundleFixture {
    let support: MeetingRecordingBundleTestSupport
    let bundle: MeetingRecordingBundle

    init(
        sessionID: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        filePrefix: String = "",
        microphoneState: PipelineFixtureSourceState = .valid,
        systemState: PipelineFixtureSourceState = .valid
    ) throws {
        support = try MeetingRecordingBundleTestSupport(testName: "pipeline")
        let directory = support.bundleDirectory(sessionID: sessionID)
        let micName = "\(filePrefix)mic-cleaned.wav"
        let systemName = "\(filePrefix)system.wav"
        let microphone = MeetingAudioTestFixtures.microphoneOnly().microphone
        let system = MeetingAudioTestFixtures.systemOnly().system
        try Self.writeFixtureSource(
            microphoneState,
            samples: microphone,
            to: directory.appendingPathComponent(micName)
        )
        try Self.writeFixtureSource(
            systemState,
            samples: system,
            to: directory.appendingPathComponent(systemName)
        )
        let microphoneCount = microphoneState == .empty ? 0 : microphone.count
        let systemCount = systemState == .empty ? 0 : system.count
        let manifest = MeetingRecordingBundleManifest(
            schemaVersion: 1,
            meetingID: 42,
            recordingID: nil,
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(10),
            timelinePolicy: .activeCaptureCompacted,
            sampleRate: 16_000,
            channelsPerSource: 1,
            microphone: .init(
                role: .microphone,
                relativePath: micName,
                sampleCount: microphoneCount,
                encoding: .pcmS16LEWAV,
                availability: Self.availability(for: microphoneState),
                contentDigest: nil
            ),
            system: .init(
                role: .system,
                relativePath: systemName,
                sampleCount: systemCount,
                encoding: .pcmS16LEWAV,
                availability: Self.availability(for: systemState),
                contentDigest: nil
            ),
            preprocessing: .current,
            captureModelSnapshot: nil,
            playback: nil,
            rawAudio: nil
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(MeetingRecordingBundle.manifestFilename),
            options: .atomic
        )
        bundle = try MeetingRecordingBundle.load(
            directoryURL: directory,
            supportDirectory: support.supportDirectory
        )
    }

    func cleanup() {
        support.cleanup()
    }

    private static func writeFixtureSource(
        _ state: PipelineFixtureSourceState,
        samples: [Int16],
        to url: URL
    ) throws {
        switch state {
        case .valid:
            try MeetingAudioTestFixtures.writeMonoPCM16WAV(samples: samples, to: url)
        case .corrupt:
            try MeetingAudioTestFixtures.writeCorruptWAV(to: url)
        case .empty, .missing:
            break
        }
    }

    private static func availability(
        for state: PipelineFixtureSourceState
    ) -> MeetingRecordingSourceAvailability {
        switch state {
        case .valid:
            return .available
        case .empty:
            return .empty
        case .missing:
            return .missing
        case .corrupt:
            return .corrupt
        }
    }
}
