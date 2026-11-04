# mlx-swift background-safe fork

## What and why

iOS revokes GPU access whenever the host app moves to the background. Metal
still completes, with an error, every command buffer that was already
committed when that clamp landed. How `mlx` (the C++ runtime under
`mlx-swift`) reacts to that error decides whether the app survives:

* **0.31.x:** `check_error()` in `mlx/backend/metal/eval.cpp` threw a
  `std::runtime_error` from Metal's completion-handler thread
  (`com.Metal.CommandQueueDispatch`). No Swift `try`/`catch` can reach that
  thread, so the process terminated.
* **0.33.x (current):** the completion handler in
  `mlx/backend/metal/device.cpp` records the error in the encoder's
  `ErrorState` and poisons every event it signals. The next `eval()` /
  `synchronize()` on the *calling* thread rethrows it, which `mlx-swift`'s
  default error handler turns into `fatalError`. Still a crash, now from our
  own thread, and the stream stays poisoned afterwards.

The Swift-side defenses TTSMLX ships (synchronous shutdown flag, synchronous
`Stream.gpu.synchronize()` on `willResignActive`, drain-task cancellation)
prevent **new** submissions after backgrounding but cannot prevent Metal from
completing buffers that were already in flight. The C++ patch is the only way
to make those completions harmless.

## The patch

`Patches/mlx-c-0.33.0-background-safe-command-buffer.patch` applies to the
`mlx` submodule inside `mlx-swift` (fork base: `ml-explore/mlx@36969c09`, the
commit `mlx-swift 0.33.0` pins). In the completion handler it reads the
buffer's error description and, when it contains
`submit GPU work from background`, logs one line and skips recording the
error. Events are still signalled (upstream already does that on every
error), so nothing waits forever. Every other Metal error is recorded exactly
as upstream does.

`Patches/mlx-c-0.31.3-background-safe-check_error.patch` is the 0.31 version
of the same idea, kept for the `0.31.5` fork tag that older TTSMLX releases
pin.

## Published forks (what TTSMLX pins)

| Repository | Ref | Contents |
| --- | --- | --- |
| `fil-technology/mlx` | tag `v0.33.0-tts-bg-safe.1` (branch `tts-bg-safe-0.33.0`) | upstream `36969c09` + the patch above |
| `fil-technology/mlx-swift` | tag `0.33.100` (branch `tts-bg-safe-0.33.0`) | upstream `0.33.0` with `.gitmodules` and the `Source/Cmlx/mlx` pointer moved to the `mlx` fork |

**Why `0.33.100`.** The pin has to be a *normal* semantic version: upstream
`mlx-audio-swift` (and anything else in a consumer's graph, such as
`mlx-swift-lm` 3.x) declares `mlx-swift` with `from: "0.33.0"`, and SwiftPM
excludes prerelease tags such as `0.33.0-bgsafe.1` from such ranges. The
previous fork tag, `0.31.5`, was a normal version too, and upstream later
published its own `0.31.5`, so the tag name stopped identifying the fork. A
patch number upstream will never reach keeps the tag unambiguous.

`mlx-swift-lm` is no longer in TTSMLX's graph: upstream `mlx-audio-swift`
0.1.8 owns its generation code (`GenerateParameters` lives in `MLXAudioCore`).

## How resolution stays on the fork

Upstream `mlx-audio-swift` names `ml-explore/mlx-swift`, so the `mlx-swift`
package identity would resolve to upstream unless the root package redirects
it. TTSMLX tracks `.swiftpm/configuration/mirrors.json` for that; every
consuming app needs its own copy (mirrors apply to the root package only),
installed with `Tools/install-mirrors.sh path/to/App.xcodeproj`.
`Tools/verify-mlx-fork.sh` checks the resolved checkout's submodule URL and
greps the patch marker out of `device.cpp` (or `eval.cpp` for 0.31 trees); CI
runs both.

## Re-applying the patch after upstream version bumps

1. Find the `mlx` commit the new `mlx-swift` tag pins:
   `gh api "repos/ml-explore/mlx-swift/contents/Source/Cmlx/mlx?ref=<tag>" --jq .sha`.
2. In a clone of `fil-technology/mlx`, branch from that commit and
   `git apply Patches/mlx-c-0.33.0-background-safe-command-buffer.patch`. If
   the hunk moved again, re-apply by hand: the rule is "do not record the
   background-clamp error; keep signalling events". Commit, tag
   `v<version>-tts-bg-safe.N`, push.
3. In a clone of `fil-technology/mlx-swift`, branch from the upstream tag,
   point `.gitmodules` at `https://github.com/fil-technology/mlx.git`, set the
   submodule pointer (`git update-index --cacheinfo 160000,<sha>,Source/Cmlx/mlx`),
   commit, tag `<version>.100`, push.
4. Move the `exact:` pin in `Package.swift`, resolve, and check that
   `Package.resolved` records the fork URL as `mlx-swift`'s location.

## Upstream-able

This is a clean candidate for an upstream PR to `ml-explore/mlx`. Mobile
apps embedding MLX have no other recourse for this crash, and the behaviour
change (ignore one OS-specific error string) is conservative.
