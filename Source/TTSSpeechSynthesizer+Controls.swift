import Foundation
import MLXAudioTTS

/// What the synthesizer sends to the runtime once the uniform controls have
/// been translated for the loaded model.
struct TTSResolvedRequest: Sendable {
    var text: String
    var voice: String?
    var ignored: [String] = []
}

extension TTSSpeechSynthesizer {
    /// Translates `TTSSynthesisOptions.instruction` / `emotion` / `speed` and
    /// the canonical event-tag markers into the loaded model's own knobs.
    ///
    /// The model instance is shared by every request, so each knob is reset
    /// before it is set. Controls a model cannot honour are reported once per
    /// request through ``TTSDiagnostic/controlsIgnored(modelID:controls:)``
    /// and generation continues without them (the caller emits it).
    nonisolated static func applyControls(
        _ options: TTSSynthesisOptions,
        text: String,
        descriptor: TTSModelDescriptor,
        to model: any SpeechGenerationModel,
        hasReference: Bool
    ) -> TTSResolvedRequest {
        var request = TTSResolvedRequest(
            text: TTSEventTag.rewrite(text, using: descriptor.capabilities.eventTags),
            voice: options.voice?.identifier
        )
        let features = descriptor.features
        func ignore(_ name: String, unless feature: TTSModelFeature, set: Bool) {
            if set, !features.contains(feature) { request.ignored.append(name) }
        }

        switch model {
        case let ming as MingDenseModel:
            // Ming takes one JSON "instruction"; a built-in voice is itself an
            // instruction with the voice in its IP field, and the runtime
            // refuses a voice next to an explicit instruction. Build the whole
            // instruction here and hand the runtime no voice at all.
            ming.options = MingSpeechOptions()
            if let instruction = options.instruction {
                ming.options.instruction = instruction
                ming.options.zeroSpeakerEmbedding = !hasReference
                if request.voice != nil {
                    request.ignored.append("voice (a free-form instruction replaces the built-in voice on Ming)")
                    request.voice = nil
                }
                if options.emotion != nil { request.ignored.append("emotion (not combinable with a free-form instruction on Ming)") }
                if options.speed != nil { request.ignored.append("speed (not combinable with a free-form instruction on Ming)") }
            } else if options.emotion != nil || options.speed != nil {
                ming.options.instruction = MingText.instruction(
                    speed: options.speed.map(Self.mingSpeed),
                    emotion: options.emotion.map(Self.mingEmotion),
                    voice: hasReference ? nil : request.voice
                )
                ming.options.zeroSpeakerEmbedding = !hasReference
                request.voice = nil
            }

        case let kokoro as KokoroModel:
            kokoro.speed = options.effectiveRate ?? 1
            ignore("instruction", unless: .instruction, set: options.instruction != nil)
            ignore("emotion", unless: .emotion, set: options.emotion != nil)

        case let chatterbox as ChatterboxModel:
            chatterbox.emotionAdvOverride = nil
            chatterbox.cfgWeightOverride = nil
            if chatterbox.config.isTurbo {
                if options.emotion != nil { request.ignored.append("emotion (Chatterbox Turbo has no exaggeration input)") }
                if options.expressiveness != nil { request.ignored.append("expressiveness (Chatterbox Turbo has no exaggeration input)") }
                if options.voiceGuidance != nil { request.ignored.append("voiceGuidance (Chatterbox Turbo has no CFG weight)") }
            } else {
                if let expressiveness = options.expressiveness {
                    chatterbox.emotionAdvOverride = min(1, max(0, expressiveness))
                } else if let emotion = options.emotion {
                    chatterbox.emotionAdvOverride = Self.chatterboxExaggeration(emotion)
                }
                if let guidance = options.voiceGuidance {
                    chatterbox.cfgWeightOverride = min(1, max(0, guidance))
                }
            }
            ignore("instruction", unless: .instruction, set: options.instruction != nil)

        case is OmniVoiceModel:
            // OmniVoice reads `voice` as a free-form description of the speaker
            // (voice design); a reference clip with its transcript clones instead.
            var parts: [String] = []
            if let voice = request.voice { parts.append(voice) }
            if let instruction = options.instruction { parts.append(instruction) }
            if let emotion = options.emotion { parts.append("\(emotion.rawValue) tone") }
            if let speed = options.speed, speed != .normal { parts.append(speed == .slow ? "slow pace" : "fast pace") }
            request.voice = parts.isEmpty ? nil : parts.joined(separator: ", ")

        case is Qwen3TTSModel where features.contains(.instruction):
            // CustomVoice builds read the voice as "speaker, instruction".
            var parts: [String] = []
            if let instruction = options.instruction { parts.append(instruction) }
            if let emotion = options.emotion { parts.append("in a \(emotion.rawValue) tone") }
            if let speed = options.speed, speed != .normal { parts.append(speed == .slow ? "speak slowly" : "speak quickly") }
            if !parts.isEmpty {
                let speaker = request.voice ?? descriptor.suggestedVoices.first?.identifier
                request.voice = ([speaker].compactMap { $0 } + [parts.joined(separator: ", ")]).joined(separator: ", ")
            }

        default:
            ignore("instruction", unless: .instruction, set: options.instruction != nil)
            ignore("emotion", unless: .emotion, set: options.emotion != nil)
        }
        if !(model is ChatterboxModel) {
            if options.expressiveness != nil { request.ignored.append("expressiveness") }
            if options.voiceGuidance != nil { request.ignored.append("voiceGuidance") }
        }

        return request
    }

    /// Ming-3.0 "Speech Control" values (the cookbook lists them in Chinese).
    static func mingEmotion(_ emotion: TTSEmotion) -> String {
        switch emotion {
        case .neutral: "中性"
        case .happy: "高兴"
        case .sad: "悲伤"
        case .angry: "愤怒"
        case .fearful: "恐惧"
        case .disgusted: "厌恶"
        case .surprised: "惊讶"
        }
    }

    static func mingSpeed(_ speed: TTSSpeed) -> String {
        switch speed {
        case .slow: "慢速"
        case .normal: "中速"
        case .fast: "快速"
        }
    }

    /// Chatterbox has one "exaggeration" scalar (0.5 is the reference default),
    /// so an emotion maps to how far from flat the delivery should sit.
    static func chatterboxExaggeration(_ emotion: TTSEmotion) -> Float {
        switch emotion {
        case .neutral: 0.3
        case .sad: 0.5
        case .fearful, .disgusted: 0.6
        case .happy: 0.7
        case .surprised, .angry: 0.8
        }
    }
}
