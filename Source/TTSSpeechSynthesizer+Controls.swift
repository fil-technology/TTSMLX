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

        case let vox as VoxCPM2Model:
            // VoxCPM2 has no preset voices and no separate style input: a
            // natural-language description in parentheses at the front of the
            // text designs the voice (no clip) or steers a cloned one (clip).
            // `voice`, `instruction`, `emotion` and `speed` are compiled into
            // that description; a text that already opens with "(" is left
            // alone so callers can write the prompt themselves.
            let description = Self.voxCPM2Description(
                voice: request.voice, instruction: options.instruction,
                emotion: options.emotion, speed: options.speed)
            if let description, !request.text.hasPrefix("(") {
                request.text = "(\(description))" + request.text
            }
            request.voice = nil
            vox.callParameters = VoxCPM2GenerationParameters(
                inferenceTimesteps: options.diffusionSteps ?? Self.voxCPM2Steps(for: options.generationProfile),
                cfgValue: options.guidanceScale)
            if options.voiceGuidance != nil { request.ignored.append("voiceGuidance (VoxCPM2 takes guidanceScale, a CFG scale, not a 0...1 weight)") }
            if options.expressiveness != nil { request.ignored.append("expressiveness (describe the delivery in instruction instead)") }

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

extension TTSSpeechSynthesizer {
    /// Installs a prepared Chatterbox conditioning on the loaded model (or
    /// clears a stale one, since the instance is shared) and says which clip,
    /// if any, must still be loaded as `referenceAudio`: the explicit clip
    /// wins, a prepared voice without runtime support falls back to its clip.
    nonisolated static func referenceURL(
        for options: TTSSynthesisOptions,
        model: any SpeechGenerationModel,
        prepared: ChatterboxModel.RefAudioConditioning?
    ) -> URL? {
        if let chatterbox = model as? ChatterboxModel {
            chatterbox.preparedConditioning = options.referenceAudio == nil ? prepared : nil
        }
        if let explicit = options.referenceAudio { return explicit }
        guard let voice = options.preparedVoice else { return nil }
        return prepared == nil ? voice.referenceURL : nil
    }
    /// The parenthesised VoxCPM2 voice description built from the uniform
    /// controls. `voice` is read as free text (there are no presets).
    nonisolated static func voxCPM2Description(
        voice: String?, instruction: String?, emotion: TTSEmotion?, speed: TTSSpeed?
    ) -> String? {
        var parts: [String] = []
        if let voice, !voice.isEmpty { parts.append(voice) }
        if let instruction, !instruction.isEmpty { parts.append(instruction) }
        if let emotion { parts.append("\(emotion.rawValue) tone") }
        if let speed, speed != .normal { parts.append(speed == .slow ? "slow speaking pace" : "fast speaking pace") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Diffusion steps per profile. `balanced` is upstream's default (10);
    /// the other two are TTSMLX's choices, listed in Docs/voxcpm2-integration.md
    /// with the measurements behind them.
    nonisolated static func voxCPM2Steps(for profile: TTSGenerationProfile?) -> Int? {
        switch profile {
        case .fast: return 6
        case .balanced, nil: return nil
        case .highQuality: return 16
        }
    }
}
