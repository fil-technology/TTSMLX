import Foundation

/// Structured event a `TTSSpeechSynthesizer` can emit while doing work.
///
/// Diagnostics are observation-only — emitting one never throws, never blocks
/// generation, and never affects audio output. Subscribe by passing a
/// `TTSDiagnosticHandler` when constructing the synthesizer (or via
/// ``TTSSpeechSynthesizer/setDiagnosticHandler(_:)``).
public enum TTSDiagnostic: Sendable {
    /// `synthesizer.synthesize(...)` / `.synthesizeStream(...)` was called.
    case requestStarted(modelID: String, textLength: Int)

    /// The local cache lookup for a model resolved (existed or didn't).
    case modelResolveFinished(modelID: String, wasInstalled: Bool, duration: TimeInterval)

    /// A network download started for the model snapshot.
    case modelDownloadStarted(modelID: String)

    /// The model snapshot finished downloading.
    case modelDownloadFinished(modelID: String, duration: TimeInterval)

    /// MLX began materializing model weights into memory.
    case modelLoadStarted(modelID: String)

    /// MLX finished materializing model weights into memory.
    case modelLoadFinished(modelID: String, duration: TimeInterval)

    /// The model emitted its first audible PCM buffer (streaming) or sample.
    case firstBufferYielded(modelID: String, latency: TimeInterval)

    /// A streaming generation finished successfully.
    case streamingFinished(modelID: String, duration: TimeInterval, bufferCount: Int)

    /// A non-streaming synthesis finished successfully.
    case synthesisFinished(modelID: String, duration: TimeInterval, sampleCount: Int)

    /// Something went wrong. Always paired with an emitted error from the API.
    case errorOccurred(modelID: String?, stage: TTSProgressUpdate.Stage?, error: TTSError)

    /// A model's weights were dropped from memory.
    case modelUnloaded(modelID: String)
}

public typealias TTSDiagnosticHandler = @Sendable (TTSDiagnostic) -> Void
