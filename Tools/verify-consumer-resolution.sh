#!/bin/bash
# Resolves a throwaway package that depends on TTSMLX, with NO SwiftPM mirror,
# and checks which mlx-swift it picked. Since mlx-audio-swift 0.1.8-tts.5 names
# the background-safe fork itself, nothing in a consumer's graph should name
# ml-explore/mlx-swift any more; this turns a regression into a hard failure.
set -euo pipefail

package_dir="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [.package(name: "TTSMLX", path: "$package_dir")],
    targets: [.target(name: "Consumer", dependencies: [.product(name: "TTSMLX", package: "TTSMLX")])]
)
MANIFEST
mkdir -p "$work/Sources/Consumer"
echo 'import TTSMLX' > "$work/Sources/Consumer/Consumer.swift"

(cd "$work" && swift package resolve >/dev/null)
location="$(python3 -c "import json,sys; d=json.load(open('$work/Package.resolved')); print(next(p['location'] for p in d['pins'] if p['identity']=='mlx-swift'))")"
echo "consumer resolved mlx-swift to: $location"
case "$location" in
    *fil-technology/mlx-swift*) echo "OK: background-safe fork, no mirror involved" ;;
    *) echo "FAIL: a consumer without a mirror would get $location" >&2; exit 1 ;;
esac
