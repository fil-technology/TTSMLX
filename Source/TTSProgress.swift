import Foundation

public struct TTSProgressUpdate: Sendable, Hashable {
    public enum Stage: String, Sendable, Hashable {
        case resolvingModel
        case downloadingModel
        case loadingModel
        case generatingAudio
        case writingFile
        case completed
    }

    public let stage: Stage
    public let fractionCompleted: Double?
    public let message: String

    public init(stage: Stage, fractionCompleted: Double? = nil, message: String) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted
        self.message = message
    }
}
