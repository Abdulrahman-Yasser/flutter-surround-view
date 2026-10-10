#!/usr/bin/env bash
# Cross-build the app's native libraries with an installed AGL SDK, for
# copying straight to the board instead of rebuilding the image.
#
#   scripts/build-agl-sdk.sh [targets...]     default: bev_view bev_calib
#   AGL_SDK=<sdk dir> scripts/build-agl-sdk.sh
#
# Output: build-agl-sdk/libbev_view.so, build-agl-sdk/libbev_calib.so. On the
# board they live in
#   /usr/share/flutter/surround_view/<flutter version>/release/data/flutter_assets/native_assets/linux/
set -euo pipefail

SDK="${AGL_SDK:-/media/abdu/LinuxHome/Embedded_Linux/git_ignoring/AGL/sdk/21.93.0-ivi-demo-flutter}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$SRC/build-agl-sdk"
TARGETS=("${@:-bev_view bev_calib}")

# shellcheck disable=SC1090
. "$SDK"/environment-setup-*

# The SDK ships no cmake, so the host one is used. Pin every lookup to the
# target sysroot, or find_package() would happily take the host's OpenCV.
cmake -S "$SRC" -B "$OUT" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_SYSROOT="$SDKTARGETSYSROOT" \
    -DCMAKE_FIND_ROOT_PATH="$SDKTARGETSYSROOT" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DENABLE_WAYLAND_PREVIEW=OFF \
    -DENABLE_IHS_PV=ON \
    -DIHS_PROBE_SIBLING=OFF \
    -DENABLE_CALIB=ON

# shellcheck disable=SC2086
cmake --build "$OUT" --target ${TARGETS[*]}
