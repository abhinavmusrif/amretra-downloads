#!/bin/bash
set -Eeuo pipefail

# Fast branding-only rebuild for the already-built Intel Megas app.
# Reuses the installed/tested embedded core and verified browser runtime.
# Compiles the new SwiftUI shell and packages the ORIGINAL logo as both
# Finder/Dock .icns and the native sidebar bitmap. Does not alter the
# currently installed /Applications/Megas Moves.app.

BRANCH="mac-intel-current-main-20261008"
REQUIRED_SOURCE_COMMIT="beff2acbc49b6d3fb8c1a5742a00277f69a7c6f3"
BASE="$HOME/Downloads/MegasMoves-modern-build"
SRC="$BASE/repo"
PREVIOUS_APP="$BASE/Megas Moves.app"
WORK="$HOME/Downloads/MegasMoves-original-brand-rebuild"
STAGE="startup"

on_error() {
  local rc=$?
  echo
  echo "ERROR during $STAGE (exit $rc)"
  echo "Command: $BASH_COMMAND"
  echo "The existing installed Megas Moves app was not changed."
  exit "$rc"
}
trap on_error ERR

echo "Megas Moves • Original logo restoration (Intel)"
echo "================================================"

if [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: this build is for native Intel Macs only."
  exit 2
fi

if [ ! -d "$SRC/.git" ]; then
  echo "ERROR: previous Megas source checkout is missing at: $SRC"
  echo "Use the full Intel Megas rebuild script instead."
  exit 3
fi
if [ ! -x "$PREVIOUS_APP/Contents/MacOS/MegasMoves.Core" ]; then
  echo "ERROR: verified previous embedded core is missing: $PREVIOUS_APP"
  echo "Use the full Intel Megas rebuild script instead."
  exit 4
fi
for tool in git swiftc swift iconutil sips ditto codesign hdiutil shasum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: missing required tool: $tool"
    exit 5
  }
done

STAGE="updating the source revision"
echo "[1/6] Updating the original Megas artwork source..."
if ! git -C "$SRC" diff --quiet || ! git -C "$SRC" diff --cached --quiet; then
  echo "ERROR: source checkout contains uncommitted changes; refusing to overwrite them."
  exit 6
fi

if git -C "$SRC" fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"; then
  REF="refs/remotes/origin/$BRANCH"
else
  echo "      GitHub not available; checking exact cached source commit..."
  git -C "$SRC" cat-file -e "${REQUIRED_SOURCE_COMMIT}^{commit}" 2>/dev/null || {
    echo "ERROR: latest branding source is not cached. Restore internet and retry."
    exit 7
  }
  REF="$REQUIRED_SOURCE_COMMIT"
fi
git -C "$SRC" merge-base --is-ancestor "$REQUIRED_SOURCE_COMMIT" "$REF" || {
  echo "ERROR: source does not include the original-logo restoration."
  exit 8
}
git -C "$SRC" checkout -B "$BRANCH" "$REF"
echo "      Source: $(git -C "$SRC" rev-parse --short HEAD)"

ORIGINAL="$SRC/app/src/main/res/drawable/app_logo.png"
RENDERER="$SRC/worker/scripts/macos_brand_icon.swift"
MARK_VIEW="$SRC/worker/macos/MegasMoves.MacApp/Sources/MegasMoves/MegasBrandMark.swift"
test -s "$ORIGINAL"
test -s "$RENDERER"
test -s "$MARK_VIEW"
if grep -q 'MegasMarkArtwork' "$MARK_VIEW"; then
  echo "ERROR: experimental generated logo code is still present."
  exit 9
fi

STAGE="compiling modern Intel SwiftUI"
echo "[2/6] Compiling modern SwiftUI with your original logo..."
(
  cd "$SRC/worker/macos/MegasMoves.MacApp"
  swift build -c release
)
UI="$SRC/worker/macos/MegasMoves.MacApp/.build/release/MegasMoves"
test -x "$UI"
file "$UI" | grep -q 'x86_64'

STAGE="rendering original macOS logo"
echo "[3/6] Creating Dock/DMG icon from original app_logo.png..."
mkdir -p "$WORK/icon/MegasMoves.iconset"
swiftc -parse-as-library "$RENDERER" -framework AppKit -o "$WORK/icon/render-original-logo"
"$WORK/icon/render-original-logo" "$ORIGINAL" "$WORK/icon/MegasMovesBrand.png"

for spec in \
  "16 16 icon_16x16.png" \
  "32 32 icon_16x16@2x.png" \
  "32 32 icon_32x32.png" \
  "64 64 icon_32x32@2x.png" \
  "128 128 icon_128x128.png" \
  "256 256 icon_128x128@2x.png" \
  "256 256 icon_256x256.png" \
  "512 512 icon_256x256@2x.png" \
  "512 512 icon_512x512.png" \
  "1024 1024 icon_512x512@2x.png"; do
  set -- $spec
  sips -z "$1" "$2" "$WORK/icon/MegasMovesBrand.png" --out "$WORK/icon/MegasMoves.iconset/$3" >/dev/null
done
iconutil -c icns "$WORK/icon/MegasMoves.iconset" -o "$WORK/icon/MegasMoves.icns"
test -s "$WORK/icon/MegasMoves.icns"

STAGE="assembling and signing branded Intel app"
echo "[4/6] Updating UI and artwork, keeping existing core/browser..."
APP="$WORK/Megas Moves.app"
rm -rf "$APP"
ditto "$PREVIOUS_APP" "$APP"
cp "$UI" "$APP/Contents/MacOS/MegasMoves"
cp "$WORK/icon/MegasMoves.icns" "$APP/Contents/Resources/MegasMoves.icns"
cp "$WORK/icon/MegasMovesBrand.png" "$APP/Contents/Resources/MegasMovesBrand.png"
cp "$ORIGINAL" "$APP/Contents/Resources/MegasOriginalLogo.png"
test -s "$APP/Contents/Resources/MegasMovesBrand.png"
test -s "$APP/Contents/Resources/MegasOriginalLogo.png"
test -x "$APP/Contents/MacOS/MegasMoves.Core"
file "$APP/Contents/MacOS/MegasMoves.Core" | grep -q 'x86_64'
file "$APP/Contents/MacOS/MegasMoves" | grep -q 'x86_64'
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

STAGE="creating and verifying the Intel DMG"
echo "[5/6] Creating updated DMG..."
DMG_STAGE="$WORK/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/Megas Moves.app"
ln -s /Applications "$DMG_STAGE/Applications"
BUILD="$(date +%Y%m%d%H%M%S)"
OUT="$HOME/Downloads/MegasMoves-original-logo-macOS-Intel-$BUILD.dmg"
hdiutil create -volname "Megas Moves Original Intel" -srcfolder "$DMG_STAGE" -ov -format UDZO "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
shasum -a 256 "$OUT" > "$OUT.sha256"

STAGE="mounting original-logo DMG"
echo "[6/6] Mounting the completed app..."
for volume in /Volumes/"Megas Moves Original Intel"*; do
  if [ -d "$volume" ]; then
    hdiutil detach "$volume" >/dev/null 2>&1 || true
  fi
done
hdiutil attach -nobrowse "$OUT" >/dev/null
open "/Volumes/Megas Moves Original Intel"
echo
echo "SUCCESS: original Megas logo restored in the sidebar and Dock."
echo "DMG: $OUT"
echo "SHA256: $OUT.sha256"
echo "Your installed /Applications app was not changed."
