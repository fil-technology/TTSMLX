#if canImport(AVFoundation)
import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSRealtimeSession")
@MainActor
struct TTSRealtimeSessionTests {
    private func makeSession() -> TTSRealtimeSession {
        TTSRealtimeSession(
            model: TTSModelDescriptor(id: "test/model"),
            playback: TTSPlaybackController()
        )
    }

    @Test("empty or whitespace text is ignored and starts nothing")
    func emptyTextIgnored() {
        let session = makeSession()
        #expect(session.say("") == nil)
        #expect(session.say("   \n\t ") == nil)
        #expect(session.isSpeaking == false)
    }

    @Test("non-empty say returns a turn with the trimmed text")
    func sayReturnsTurn() {
        let session = makeSession()
        let turn = session.say("  Hello there  ")
        #expect(turn != nil)
        #expect(turn?.text == "Hello there")
        // It becomes the current turn synchronously (generation happens async).
        #expect(session.isSpeaking == true)
        session.finish() // cancel before any MLX work actually runs
    }

    @Test("interrupt while idle is a harmless no-op")
    func interruptIdleNoOp() {
        let session = makeSession()
        session.interrupt()
        #expect(session.isSpeaking == false)
    }

    @Test("model descriptor is retained")
    func modelRetained() {
        let session = makeSession()
        #expect(session.model.id == "test/model")
    }

    @Test("event and delivery types are well-formed")
    func valueTypes() {
        let id = UUID()
        let started = TTSRealtimeEvent.turnStarted(id: id, text: "hi")
        if case let .turnStarted(eventID, text) = started {
            #expect(eventID == id)
            #expect(text == "hi")
        } else {
            Issue.record("unexpected case")
        }
        #expect(TTSRealtimeDelivery.interrupt != TTSRealtimeDelivery.enqueue)
    }
}
#endif
