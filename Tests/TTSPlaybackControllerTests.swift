#if canImport(AVFoundation)
import Foundation
import Testing
@testable import TTSMLX

@MainActor
@Suite("TTSPlaybackController")
struct TTSPlaybackControllerTests {
    @Test("rate is clamped to the 0.5–2.0 range")
    func rateClamping() {
        let controller = TTSPlaybackController(rate: 1.0)
        controller.rate = 5.0
        #expect(controller.rate == 2.0)
        controller.rate = 0.1
        #expect(controller.rate == 0.5)
        controller.rate = 1.25
        #expect(controller.rate == 1.25)
    }

    @Test("constructor clamps initial rate the same way")
    func initialRateClamping() {
        let high = TTSPlaybackController(rate: 99)
        #expect(high.rate == 2.0)
        let low = TTSPlaybackController(rate: -1)
        #expect(low.rate == 0.5)
    }

    @Test("default state is idle and stop transitions to stopped")
    func stateMachine() {
        let controller = TTSPlaybackController()
        #expect(controller.state == .idle)
        controller.stop()
        #expect(controller.state == .stopped)
    }
}
#endif
