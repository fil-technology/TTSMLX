# mlx-swift background-safe fork

## What and why

`mlx-swift` (the C++ MLX runtime wrapped by Swift bindings) throws an
uncaught `std::runtime_error` from Metal's command-buffer completion
handler when iOS revokes GPU access during background transition.
Because the handler runs on Metal's callback thread (`Thread: com.Metal.CommandQueueDispatch`),
the throw is unreachable from any Swift try-catch and terminates the
process. Stack:

```
9   mlx::core::gpu::check_error
10  mlx::core::gpu::eval(array&)::$_1::operator()(MTL::CommandBuffer*)
17  invocation function for block in MTL::CommandBuffer::addCompletedHandler
```

Throw site: `Source/Cmlx/mlx/mlx/backend/metal/eval.cpp:23` (in the
upstream `mlx` submodule of mlx-swift).

The Swift-side defenses TTSMLX ships (synchronous shutdown flag,
synchronous `Stream.gpu.synchronize()` on `willResignActive`, drain-task
cancellation) prevent **new** submissions after backgrounding but
cannot prevent Metal from firing completion handlers on buffers that
were already submitted. The C++ patch is the only way to make those
handlers tolerant of the OS-imposed background error.

## The patch

`Patches/mlx-c-0.31.3-background-safe-check_error.patch` — applies to
the `mlx` submodule inside `mlx-swift`. Adds a `desc` lookup and swallows
the specific "submit GPU work from background" error before throwing.
All other Metal errors still throw as today.

## How to publish your fork (one-time setup)

1. **Fork the upstream `mlx` repository** to your org. The Metal eval
   lives in `ml-explore/mlx`, which is a git submodule of
   `ml-explore/mlx-swift`. (Patching `mlx-swift` alone is not enough —
   `mlx-swift` doesn't own this file, the `mlx` submodule does.)
2. **Apply the patch** at the same commit `mlx-swift v0.31.3` pins
   (currently `ce45c52505c8158ea48d2a54e8caae05efd86bfe`):
   ```bash
   git clone https://github.com/<your-org>/mlx
   cd mlx
   git checkout ce45c52505c8158ea48d2a54e8caae05efd86bfe
   git apply /path/to/TTSMLX/Patches/mlx-c-0.31.3-background-safe-check_error.patch
   git commit -am "check_error: swallow iOS background-permission errors"
   git tag v0.31.3-tts-bg-safe.1
   git push origin v0.31.3-tts-bg-safe.1
   ```
3. **Fork `ml-explore/mlx-swift`** to your org. Update its `.gitmodules`
   to point at your `mlx` fork, and bump the submodule pointer to your
   new tag.
4. **Tag** your `mlx-swift` fork (e.g. `v0.31.3-tts-bg-safe.1`).
5. **Update TTSMLX's `Package.swift`**:
   ```swift
   .package(url: "https://github.com/<your-org>/mlx-swift.git",
            exact: "0.31.3-tts-bg-safe.1"),
   ```
   Run `swift package resolve` and commit the updated `Package.resolved`.
6. **Cut TTSMLX v0.6.1** (or v0.7.0) with just that dependency change.

## How to develop against the patch right now (without publishing)

TTSMLX uses `swift package edit mlx-swift` to make a writable local
checkout under `Packages/mlx-swift/`. The patch is already applied
there in the maintainer's environment; SwiftPM resolves from the local
checkout instead of the remote pin while `edit` is in effect.

To clean up after publishing the fork: `swift package unedit mlx-swift`
returns SwiftPM to the remote-pinned resolution.

## Re-applying the patch after upstream version bumps

When TTSMLX bumps the `mlx-swift` pin (e.g. to 0.32.x), the upstream
`mlx` SHA the submodule points at changes. Re-cherry-pick the patch
onto the new SHA, re-tag your `mlx` and `mlx-swift` forks, and update
TTSMLX's pin. The patch is small and likely to apply cleanly across
versions, but rebase manually if conflicts appear.

## Upstream-able

This is a clean candidate for an upstream PR to `ml-explore/mlx`. Mobile
apps embedding MLX have no other recourse for this crash, and the
behavior change (swallow a single OS-specific error code) is conservative.
File the PR when convenient.
