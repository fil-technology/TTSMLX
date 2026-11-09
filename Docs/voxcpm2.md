# VoxCPM2 in TTSMLX

OpenBMB's VoxCPM2 (`mlx-community/VoxCPM2-4bit`) through the native
Swift/MLX port in the runtime fork: 30 languages, 48 kHz output, voice
design from a description, cloning from a clip, high-fidelity continuation
from a clip and its transcript, per-patch streaming. Mac only (the audio
decoder peaks above 6 GB on long takes); see `Docs/benchmarks.md` for the
numbers and `Docs/voxcpm2-integration.md` for what each feature is and is
not. Everything below is plain `TTSSpeechSynthesizer` API; nothing here is
specific to VoxCPM2 except the model id and which options it honours.

```swift
import TTSMLX

let voxcpm2 = TTSMLX.modelCatalog.first { $0.id == "mlx-community/VoxCPM2-4bit" }!.descriptor!
let synthesizer = TTSSpeechSynthesizer()
```

## 1. Multilingual TTS

No language tag exists; the model reads the script. `language` is a hint
for TTSMLX's chunker and your own bookkeeping.

```swift
let ru = try await synthesizer.synthesize(
    "Сегодня мы читаем первую главу.", using: voxcpm2,
    options: .init(language: .russian, outputURL: out("ru.wav")))
let he = try await synthesizer.synthesize(
    "היום אנחנו קוראים את הפרק הראשון.", using: voxcpm2,
    options: .init(language: .hebrew, outputURL: out("he.wav")))
```

Ukrainian is not among the 30 supported languages; it synthesises, but
quality is not guaranteed and the catalog does not list it.

## 2. Voice design from text

A description in parentheses at the front of the text designs the voice.
TTSMLX writes those parentheses for you from `voice` (free text here, there
are no presets), `instruction`, `emotion` and `speed`:

```swift
let options = TTSSynthesisOptions(
    voice: TTSVoice("A mature male narrator with a warm, deep, slightly raspy voice"),
    instruction: "calm and reassuring delivery, natural pauses",
    speed: .slow,
    outputURL: out("narrator.wav"))
let take = try await synthesizer.synthesize("Chapter one. The house was quiet.", using: voxcpm2, options: options)
```

The text actually sent was
`(A mature male narrator with a warm, deep, slightly raspy voice, calm and reassuring delivery, slow speaking pace)Chapter one. The house was quiet.`
A text that already starts with "(" is sent as written, so you can hand the
model your own prompt.

## 3. Structured voice controls

`TTSVoiceDesign` turns choices into that sentence. None of its fields is a
measured quantity: "mature" or "deep-pitched" are words the model reads.

```swift
var design = TTSVoiceDesign(gender: .female, age: .young, pitch: .medium,
                            qualities: ["bright", "clear"], pace: .brisk, style: "news anchor")
design.accent = "British"
design.custom = "slight smile in the voice"
print(design.description)
// A young adult female news anchor, medium-pitched, bright, clear voice, British accent, brisk speaking pace, slight smile in the voice
let options = TTSSynthesisOptions(voice: TTSVoice(design.description))
```

## 4. Voice cloning from a clip

A clip alone is an *isolated reference*: it lends its timbre, the style
stays free. Mono or stereo, any sample rate; TTSMLX resamples to the model.

```swift
let options = TTSSynthesisOptions(referenceAudio: clipURL, outputURL: out("cloned.wav"))
```

## 5. Controllable cloning

Same clip, plus a description that steers delivery while keeping the
speaker:

```swift
let options = TTSSynthesisOptions(
    referenceAudio: clipURL, instruction: "whispering, urgent", speed: .fast)
```

## 6. High-fidelity continuation cloning

The clip *and its exact transcript*: the model continues the recording as
if your text followed it. Get the transcript right; TTSMLX sends it as is.

```swift
let options = TTSSynthesisOptions(
    referenceAudio: clipURL,
    referenceText: "The words that are actually spoken in the clip.")
```

Or prepare once and reuse (the clip is re-sent with every call; VoxCPM2 has
no cached speaker conditioning):

```swift
let voice = try await synthesizer.prepareVoice(from: clipURL, referenceText: transcript, using: voxcpm2)
let options = TTSSynthesisOptions(preparedVoice: voice)
```

## 7. Streaming

`synthesizeStream` yields 160 ms of 48 kHz audio per patch as the model
generates; `TTSPlaybackController` plays it with backpressure. Text is
fixed for the take: VoxCPM2 does not accept words appended mid-generation.
For live text, split into sentences and feed them as separate takes
(`synthesizeLong` / `TTSRealtimeSession` do this).

```swift
for try await chunk in try await synthesizer.synthesizeStream(text, using: voxcpm2, options: options) {
    player.schedule(chunk)
}
```

## 8. Saving and reusing voice profiles

```swift
let store = TTSVoiceProfileStore()
let narrator = TTSVoiceProfile(
    name: "Narrator", kind: .designed(description: design.description),
    modelID: voxcpm2.id, language: .english, speed: .slow, seed: 42)
try await store.save(narrator)

let me = TTSVoiceProfile(
    name: "Me", kind: .highFidelity(referenceURL: clipURL, transcript: transcript),
    modelID: voxcpm2.id,
    consent: .init(speaker: "me", basis: "own voice"))
try await store.save(me) // refused without `consent`

let options = narrator.apply(to: .init(outputURL: out("ch1.wav")))
```

A profile is a recipe, not a speaker embedding: a cloned profile points at
the clip and sends it with each request. Audition variants of a designed
voice with `narrator.variants(seeds: [1, 2, 3])`.

## 9. Reproducible takes

```swift
let a = try await synthesizer.synthesize(text, using: voxcpm2, options: .init(seed: 42, outputURL: out("a.wav")))
let b = try await synthesizer.synthesize(text, using: voxcpm2, options: .init(seed: 42, outputURL: out("b.wav")))
// same checkpoint, same runtime, same device: identical samples
```

## 10. Quality settings

```swift
var options = TTSSynthesisOptions()
options.generationProfile = .highQuality   // 16 diffusion steps; .fast is 6; .balanced the checkpoint's 10
options.diffusionSteps = 24                // explicit; overrides the profile
options.guidanceScale = 2.5                // CFG scale, upstream default 2.0
```

`temperature`, `topP` and `voiceGuidance` have no effect on VoxCPM2 and
are reported through the `controlsIgnored` diagnostic.
