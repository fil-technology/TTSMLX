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

    /// The synthesizer reused a previously-loaded model instance instead of
    /// running the MLX load pipeline. Emitted in place of
    /// ``modelResolveFinished`` / ``modelLoadStarted`` / ``modelLoadFinished``
    /// when the instance was already resident from a prior call. Lets
    /// consumers tell "first generation of the session" from "subsequent
    /// generations" without re-deriving it from timings.
    case modelLoadServedFromCache(modelID: String)

    /// In-flight generation was cancelled because the host app entered the
    /// background, and ``TTSSpeechSynthesizer/allowsBackgroundGeneration``
    /// is `false` (the default). Consumers should treat any subsequent
    /// `CancellationError` thrown by an in-flight stream as expected.
    /// `cancelledCount` is the number of generation Tasks that were
    /// terminated.
    case cancelledByBackground(cancelledCount: Int)

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

    /// A long-form chunk just started yielding audio. `characterRange` maps
    /// back into the original text passed to `synthesizeLong`, so apps can
    /// highlight the currently-playing paragraph. Half-open Character offsets.
    case chunkStarted(modelID: String, chunkIndex: Int, characterRange: Range<Int>)

    /// A long-form chunk finished streaming all its buffers.
    case chunkFinished(modelID: String, chunkIndex: Int, duration: TimeInterval)

    /// Word-level timings for a long-form chunk, emitted right after
    /// ``chunkFinished`` once the actual duration is known. Timings are
    /// proportional to character weight; ranges are in the original input.
    /// Use these to drive word-by-word highlight UIs without per-token
    /// callbacks from the model. See ``TTSChunkInfo/wordTimings(forDuration:)``.
    case chunkTimings(modelID: String, chunkIndex: Int, timings: [TTSWordTiming])
}

public typealias TTSDiagnosticHandler = @Sendable (TTSDiagnostic) -> Void
