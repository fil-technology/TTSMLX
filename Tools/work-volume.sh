#!/bin/zsh
# Mounts the APFS sparse image that keeps TTSMLX's heavy, regenerable data
# off the internal disk (builds, Xcode DerivedData, model weights, reference
# fixtures) and prints the environment to use it:
#
#   eval "$(Tools/work-volume.sh)"          # mount if needed, export variables
#   Tools/work-volume.sh eject              # detach when done
#
# The image lives on the external SSD and grows as needed (created with
# `hdiutil create -size 120g -type SPARSE -fs APFS`). Exports:
#   TTSMLX_WORK   the mount point; Tools/bench.sh puts DerivedData there
#   HF_HOME       model downloads (TTSModelStore and the runtime honour it)
#   SWIFTPM_SCRATCH  pass as `swift build --scratch-path "$SWIFTPM_SCRATCH"`
set -euo pipefail
image=${TTSMLX_WORK_IMAGE:-"/Volumes/Sviat SSD/TTSMLX-work.sparseimage"}
mount=/Volumes/TTSMLX-work

if [[ ${1:-} == eject ]]; then
  hdiutil detach "$mount" >&2
  exit 0
fi
if [[ ! -d $mount ]]; then
  [[ -f $image ]] || { echo "work-volume: $image is missing; is the SSD plugged in?" >&2; exit 1; }
  hdiutil attach "$image" -mountpoint "$mount" >/dev/null
fi
mkdir -p "$mount"/{hf,build,DerivedData,ref}
echo "export TTSMLX_WORK='$mount'"
echo "export HF_HOME='$mount/hf'"
echo "export SWIFTPM_SCRATCH='$mount/build/TTSMLX'"
