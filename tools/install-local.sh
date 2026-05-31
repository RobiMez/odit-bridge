#!/bin/bash
# Build OditBridge in Debug and install it to /Applications/OditBridge.app
# with the embedded code signature intact. Use this instead of dragging the
# .app -- macOS will refuse to launch an unsigned bundle.
#
# This used to live as a post-build script in project.yml, but Xcode's late
# build phases (RegisterWithLaunchServices in particular) intermittently
# strip the signature off /Applications copies when the install runs inside
# a build. Doing it as a separate step after xcodebuild finishes avoids that.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED:-build}"

echo "[build] $CONFIG"
xcodebuild \
  -project OditBridge.xcodeproj \
  -scheme OditBridge \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  > /tmp/odit-build.log 2>&1 || {
    tail -40 /tmp/odit-build.log
    echo "[fail] xcodebuild failed; full log at /tmp/odit-build.log"
    exit 1
  }

BUILT="$ROOT/$DERIVED/Build/Products/$CONFIG/OditBridge.app"
DEST="/Applications/OditBridge.app"

if [ ! -d "$BUILT" ]; then
  echo "[fail] build output not found at $BUILT"
  exit 1
fi

echo "[verify] build signature"
if ! codesign --verify --verbose=1 "$BUILT" > /dev/null 2>&1; then
  echo "[fail] build output is not signed -- check Configs/Local.xcconfig"
  exit 1
fi

echo "[install] $DEST"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

echo "[verify] installed signature"
if codesign --verify --verbose=1 "$DEST" > /dev/null 2>&1; then
  echo "[ok] installed and signed at $DEST"
else
  echo "[fail] installed copy lost its signature -- environment quirk"
  exit 1
fi
