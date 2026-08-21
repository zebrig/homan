import AVFoundation
import AudioGraphExceptionBridge
import CoreAudio
import Testing

// These checks instantiate AVAudioEngine and may consult the real HAL. Keep them out of the
// authoritative unit suite; an explicit isolated dev-lane build may opt in with
// -Xswiftc -DHOMAN_HARDWARE_TESTS.
#if HOMAN_HARDWARE_TESTS
@Suite("AVFAudio exception boundary")
struct AudioGraphExceptionBridgeTests {
    @Test("input state reads return a format or a bridged error")
    func inputStateReadIsContained() {
        let state = MuesliAudioGraphReadInputState(AVAudioEngine())

        #expect(state.outputFormat != nil || state.error != nil)
    }

    @Test("invalid input routing returns an error instead of escaping the boundary")
    func invalidInputRouteIsContained() {
        let error = MuesliAudioGraphSetInputDevice(AVAudioEngine(), AudioObjectID.max)

        #expect(error != nil)
    }
}
#endif
