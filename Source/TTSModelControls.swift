import Foundation

// One vocabulary for what a model can do and how a caller steers it, so an
// app can show the same picker and pass the same options whichever loader is
// behind the descriptor. The per-model translation (Ming's JSON instruction,
// Chatterbox's exaggeration scalar, Kokoro's speed factor, Qwen3's
// "speaker, instruction" voice string, each model's event-tag spelling) lives
// in `TTSSpeechSynthesizer+Controls.swift`; nothing here imports the runtime.

/// Gender of a built-in voice, where the model's documentation states it.
public enum TTSVoiceGender: String, Sendable, Codable, Hashable, CaseIterable {
    case female
    case male
    case neutral
}

/// A capability a model exposes through the uniform options.
///
/// `TTSModelCapabilities.features` always contains the implied members
/// (`.streaming`, `.voiceCloning`, `.multilingual`, `.builtInVoices`) derived
/// from the older boolean fields and the voice list, so apps can read one set.
public enum TTSModelFeature: String, Sendable, Codable, Hashable, CaseIterable {
    /// Audio arrives in chunks while generation continues.
    case streaming
    /// Named voices selectable with `TTSSynthesisOptions.voice`.
    case builtInVoices
    /// Clones the speaker of `TTSSynthesisOptions.referenceAudio`.
    case voiceCloning
    /// `TTSSynthesisOptions.referenceText` conditions on the clip's transcript as well.
    case referenceTranscript
    /// More than one target language; pick with `TTSSynthesisOptions.language`.
    case multilingual
    /// Canonical `TTSEventTag` markers in the text become non-verbal sounds.
    case eventTags
    /// Free-form delivery instruction (`TTSSynthesisOptions.instruction`).
    case instruction
    /// Discrete emotion (`TTSSynthesisOptions.emotion`).
    case emotion
    /// Speaking rate (`TTSSynthesisOptions.speed`).
    case speed
    /// Describes a new voice in words (through `instruction`, with no voice or clip).
    case voiceDesign

    public var displayName: String {
        switch self {
        case .streaming: "streaming"
        case .builtInVoices: "built-in voices"
        case .voiceCloning: "voice cloning"
        case .referenceTranscript: "reference transcript"
        case .multilingual: "multilingual"
        case .eventTags: "event tags"
        case .instruction: "style instruction"
        case .emotion: "emotion"
        case .speed: "speed"
        case .voiceDesign: "voice design"
        }
    }

    /// Stable display order (declaration order).
    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

extension TTSModelFeature: Comparable {}

/// Non-verbal sound a caller writes into the text as `marker` (for example
/// `"That's hilarious [laugh] anyway"`). The synthesizer rewrites each marker
/// into the loaded model's own spelling (`[laugh]`, `[Laughter]`, `<laugh>`)
/// and drops markers the model does not support, so the same text can be sent
/// to any model without the tag being read aloud.
public enum TTSEventTag: String, Sendable, Codable, Hashable, CaseIterable, CodingKeyRepresentable, CustomStringConvertible {
    case laugh
    case chuckle
    case giggle
    case sigh
    case cough
    case breath
    case gasp
    case groan
    case sniffle
    case clearThroat
    case hesitation
    case yawn

    /// The canonical form to write in the text: `[laugh]`, `[clearThroat]`.
    public var marker: String { "[\(rawValue)]" }
    public var description: String { marker }

    /// Replaces canonical markers with the model's spelling from `syntax` and
    /// removes the ones it has no spelling for.
    public static func rewrite(_ text: String, using syntax: [TTSEventTag: String]) -> String {
        guard text.contains("[") else { return text }
        var out = text
        for tag in allCases where out.contains(tag.marker) {
            if let spelling = syntax[tag] {
                out = out.replacingOccurrences(of: tag.marker, with: spelling)
            } else {
                out = out
                    .replacingOccurrences(of: " \(tag.marker)", with: "")
                    .replacingOccurrences(of: tag.marker, with: "")
            }
        }
        return out
    }

    /// Canonical markers present in `text`.
    public static func markers(in text: String) -> [TTSEventTag] {
        allCases.filter { text.contains($0.marker) }
    }
}

/// Discrete emotion for models that take one (`TTSModelFeature.emotion`).
public enum TTSEmotion: String, Sendable, Codable, Hashable, CaseIterable {
    case neutral
    case happy
    case sad
    case angry
    case fearful
    case disgusted
    case surprised
}

/// Speaking rate for models that take one (`TTSModelFeature.speed`).
public enum TTSSpeed: String, Sendable, Codable, Hashable, CaseIterable {
    case slow
    case normal
    case fast

    /// Multiplier models with a continuous rate knob use (Kokoro).
    public var rate: Float {
        switch self {
        case .slow: 0.85
        case .normal: 1.0
        case .fast: 1.2
        }
    }
}
