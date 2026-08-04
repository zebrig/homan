import Testing
@testable import MuesliNativeApp

@Suite("Interactive audio session ownership")
struct InteractiveAudioSessionOwnershipTests {
    @Test("idle ownership allows either feature to start")
    func idleAllowsEitherOwner() {
        let ownership = InteractiveAudioSessionOwnership(
            dictationIsActive: false,
            computerUseIsActive: false
        )

        #expect(ownership.canStart(.dictation))
        #expect(ownership.canStart(.computerUse))
        #expect(!ownership.shouldIgnoreCleanup(for: .dictation))
        #expect(!ownership.shouldIgnoreCleanup(for: .computerUse))
    }

    @Test("dictation ownership rejects computer use")
    func dictationWinsOverComputerUse() {
        let ownership = InteractiveAudioSessionOwnership(
            dictationIsActive: true,
            computerUseIsActive: false
        )

        #expect(!ownership.canStart(.computerUse))
        #expect(ownership.shouldIgnoreCleanup(for: .computerUse))
    }

    @Test("computer use ownership rejects dictation")
    func computerUseWinsOverDictation() {
        let ownership = InteractiveAudioSessionOwnership(
            dictationIsActive: false,
            computerUseIsActive: true
        )

        #expect(!ownership.canStart(.dictation))
        #expect(ownership.shouldIgnoreCleanup(for: .dictation))
    }

    @Test("an existing overlap lets both owners clean up")
    func existingOverlapCanCleanUp() {
        let ownership = InteractiveAudioSessionOwnership(
            dictationIsActive: true,
            computerUseIsActive: true
        )

        #expect(!ownership.shouldIgnoreCleanup(for: .dictation))
        #expect(!ownership.shouldIgnoreCleanup(for: .computerUse))
    }
}
