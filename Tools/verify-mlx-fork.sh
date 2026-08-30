#!/usr/bin/env bash
#
# Fails if the resolved mlx-swift is not the background-safe fork.
#
# TTSMLX depends on fil-technology/mlx-swift, whose only difference from
# upstream is that its `mlx` C++ submodule carries a patch letting Metal's
# completion handlers survive iOS revoking GPU access on backgrounding.
# Without it the app dies from an uncatchable C++ exception on Metal's
# callback thread.
#
# Upstream publishes the SAME version tags, so when both URLs appear in one
# dependency graph SwiftPM resolves the shared `mlx-swift` identity to
# whichever it encounters first. The build still succeeds — it just silently
# lacks the patch. This has happened three separate ways: a drifted
# Package.resolved pin, Xcode picking upstream during resolution, and a stale
# local repository mirror.
#
# Usage:  Tools/verify-mlx-fork.sh [checkouts-dir ...]
# With no arguments it looks in the usual SwiftPM and Xcode locations.

set -uo pipefail

PATCH_MARKER="submit GPU work from background"
EXPECTED_SUBMODULE="fil-technology/mlx"

candidates=()
if [ "$#" -gt 0 ]; then
    candidates=("$@")
else
    candidates+=(".build/checkouts/mlx-swift")
    while IFS= read -r dir; do
        candidates+=("$dir")
    done < <(find . -maxdepth 6 -type d -path "*/SourcePackages/checkouts/mlx-swift" 2>/dev/null)
    while IFS= read -r dir; do
        candidates+=("$dir")
    done < <(find "${HOME}/Library/Developer/Xcode/DerivedData" -maxdepth 3 \
             -type d -path "*/SourcePackages/checkouts/mlx-swift" 2>/dev/null)
fi

checked=0
failed=0

for dir in "${candidates[@]}"; do
    [ -d "$dir" ] || continue
    checked=$((checked + 1))
    echo "checking $dir"

    url=$(git -C "$dir" config --file .gitmodules --get submodule.submodules/mlx.url 2>/dev/null \
          || grep -A2 'submodule "submodules/mlx"' "$dir/.gitmodules" 2>/dev/null | sed -n 's/.*url = //p')

    if [[ "$url" != *"$EXPECTED_SUBMODULE"* ]]; then
        echo "  FAIL: mlx submodule is '${url:-<none>}', expected $EXPECTED_SUBMODULE"
        echo "        This build would ship WITHOUT the background-Metal crash fix."
        failed=1
        continue
    fi
    echo "  ok: submodule -> $url"

    # The submodule may not be checked out (SwiftPM does not need it to build
    # from the prebuilt sources), so treat a missing file as inconclusive
    # rather than a failure.
    eval_cpp="$dir/Source/Cmlx/mlx/mlx/backend/metal/eval.cpp"
    if [ -f "$eval_cpp" ]; then
        if grep -q "$PATCH_MARKER" "$eval_cpp"; then
            echo "  ok: check_error patch present"
        else
            echo "  FAIL: $eval_cpp lacks the background-safe patch"
            failed=1
        fi
    fi
done

if [ "$checked" -eq 0 ]; then
    echo "no mlx-swift checkout found — resolve the package first" >&2
    exit 2
fi

if [ "$failed" -ne 0 ]; then
    echo
    echo "mlx-swift is NOT the background-safe fork. Fix before shipping:" >&2
    echo "  * check Package.resolved pins fil-technology/mlx-swift" >&2
    echo "  * consumers need .swiftpm/configuration/mirrors.json mapping" >&2
    echo "    ml-explore/mlx-swift -> fil-technology/mlx-swift" >&2
    exit 1
fi

echo
echo "mlx-swift verified as the background-safe fork ($checked checkout(s))"
