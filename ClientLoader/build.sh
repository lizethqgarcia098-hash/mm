#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path)
SNAPSHOT_ROOT=${SNAPSHOT_ROOT:-"$ROOT/../Minecraft-iOS-MITM"}

if [ ! -f "$SNAPSHOT_ROOT/core/include/CLSnapshot.h" ] ||
   [ ! -f "$SNAPSHOT_ROOT/core/src/CLSnapshot.c" ]; then
  printf 'Snapshot contract source not found under %s\n' "$SNAPSHOT_ROOT" >&2
  exit 1
fi

xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDKROOT" \
  -miphoneos-version-min=15.0 \
  -I "$SNAPSHOT_ROOT/core/include" \
  -fobjc-arc \
  -dynamiclib \
  "$ROOT/ClientLoader.m" \
  "$ROOT/providers/CLSnapshotBridge.m" \
  "$SNAPSHOT_ROOT/core/src/CLSnapshot.c" \
  "$ROOT/providers/CLProjection.c" \
  "$ROOT/providers/CLEntityProvider.m" \
  "$ROOT/providers/CLEntityTypeRegistry.m" \
  "$ROOT/providers/CLCameraProvider.m" \
  "$ROOT/providers/CLESPOverlay.m" \
  "$ROOT/providers/CLDiagnostics.m" \
  -framework Foundation \
  -framework CoreGraphics \
  -framework QuartzCore \
  -framework UIKit \
  -framework JavaScriptCore \
  -Wl,-install_name,@executable_path/Frameworks/ClientLoader.dylib \
  -o "$ROOT/ClientLoader.dylib"

printf 'Built %s\n' "$ROOT/ClientLoader.dylib"
