#!/bin/zsh
# Runs the shared TTS benchmark harness (Source/TTSBenchmark.swift).
#
#   Tools/bench.sh mac    [models...]   # macOS, through the test target
#   Tools/bench.sh device [models...]   # a connected iPhone, through the demo app
#   Tools/bench.sh pull                 # copy the device's reports into Benchmarks/results
#
# Models default to the validated defaults. Options via environment:
#   TRIALS=3  PROFILE=fast|balanced|highQuality  FIXTURES=sentence,paragraph,longForm
#   MODES=narration,stream  DEVICE=<devicectl name or udid>  TEAM=<DEVELOPMENT_TEAM>
# Reports land in Benchmarks/results/<model>-<device>-<timestamp>.json plus
# Benchmarks/results/audio/*.wav for the first trial of each fixture.
# Tools/render-benchmarks.py turns the JSON into Docs/benchmarks.md.
set -euo pipefail
cd "$(dirname "$0")/.."

command=${1:-mac}
shift || true
models=${(j:,:)@}
out=$PWD/Benchmarks/results
mkdir -p "$out"
bundle=com.filtechnology.ttsmlx.demo.ios

case $command in
  mac)
    env TEST_RUNNER_TTS_BENCH=1 \
        ${models:+TEST_RUNNER_TTS_BENCH_MODELS=$models} \
        ${TRIALS:+TEST_RUNNER_TTS_BENCH_TRIALS=$TRIALS} \
        ${PROFILE:+TEST_RUNNER_TTS_BENCH_PROFILE=$PROFILE} \
        ${FIXTURES:+TEST_RUNNER_TTS_BENCH_FIXTURES=$FIXTURES} \
        ${MODES:+TEST_RUNNER_TTS_BENCH_MODES=$MODES} \
        TEST_RUNNER_TTS_BENCH_OUT="$out" \
        xcodebuild test -scheme TTSMLX -destination 'platform=macOS' \
          -only-testing:TTSMLXTests/TTSBenchmarkTests 2>&1 | grep -E '^\[bench\]|error:|Test Suite|\*\* TEST'
    ;;
  device)
    device=${DEVICE:?set DEVICE to the devicectl device name or udid}
    xcodebuild -project DemoApp/TTSMLXDemo.xcodeproj -scheme TTSMLXDemo-iOS \
      -configuration Release -destination "generic/platform=iOS" \
      -allowProvisioningUpdates ${TEAM:+DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic} \
      build 2>&1 | grep -E 'error:|BUILD'
    app=$(ls -d ~/Library/Developer/Xcode/DerivedData/TTSMLXDemo-*/Build/Products/Release-iphoneos/TTSMLXDemo.app | head -1)
    xcrun devicectl device install app --device "$device" "$app"
    xcrun devicectl device process launch --device "$device" --console --terminate-existing "$bundle" \
      --benchmark ${models:+--models $models} ${TRIALS:+--trials $TRIALS} ${PROFILE:+--profile $PROFILE} \
      ${FIXTURES:+--fixtures $FIXTURES} ${MODES:+--modes $MODES} | grep -E '^\[bench\]'
    ;;
  pull)
    device=${DEVICE:?set DEVICE to the devicectl device name or udid}
    tmp=$(mktemp -d)
    xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
      --domain-identifier "$bundle" --source Documents/benchmarks --destination "$tmp"
    # devicectl copies the directory's contents straight into the destination.
    cp "$tmp"/*.json "$out"/ 2>/dev/null || true
    dev=$(ls "$tmp"/*.json 2>/dev/null | head -1 | sed -E 's/.*-(iPhone[0-9]+,[0-9]+|iPad[0-9]+,[0-9]+)-.*/\1/')
    [ -n "$dev" ] || dev=device
    mkdir -p "$out/audio/$dev" && cp "$tmp"/audio/*.wav "$out/audio/$dev/" 2>/dev/null || true
    cp "$tmp"/benchmark.log "$out/device-benchmark.log" 2>/dev/null || true
    ls "$out"
    ;;
  *)
    echo "usage: Tools/bench.sh mac|device|pull [models...]" >&2
    exit 64
    ;;
esac
