#!/bin/zsh
# Encode the paragraph/narration clip of every benchmark run to a small AAC
# file for listening comparisons: Benchmarks/samples/<device>/<model>.m4a.
# The float32 WAVs in Benchmarks/results/audio are not committed.
set -euo pipefail
cd "$(dirname "$0")/.."
for dir in Benchmarks/results/audio/*/; do
  device=$(basename "$dir")
  mkdir -p "Benchmarks/samples/$device"
  for wav in "$dir"/*-paragraph-narration.wav; do
    [ -f "$wav" ] || continue
    name=$(basename "$wav" -paragraph-narration.wav)
    afconvert -f m4af -d aac -b 64000 "$wav" "Benchmarks/samples/$device/$name.m4a"
  done
done
du -sh Benchmarks/samples
