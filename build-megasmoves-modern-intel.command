#!/bin/bash
set -Eeuo pipefail

BRANCH="mac-dmg-build-intel-20261006"
REPO="abhinavmusrif/megasmoves"
WORK="$HOME/Downloads/MegasMoves-modern-build"
SRC="$WORK/repo"
OUT_DIR="$HOME/Downloads"
CURRENT_STAGE="startup"

on_error() {
  local rc=$?
  echo
  echo "BUILD FAILED"
  echo "Stage: $CURRENT_STAGE"
  echo "Exit code: $rc"
  echo "Command: $BASH_COMMAND"
  exit "$rc"
}
trap on_error ERR

echo "Megas Moves — Modern Intel macOS local rebuild"
echo "=============================================="

if [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: This build lane is intentionally Intel-only."
  echo "Detected architecture: $(uname -m)"
  exit 2
fi

for tool in git swiftc swift hdiutil codesign iconutil sips; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' is missing."
    echo "Install Apple's Command Line Tools with: xcode-select --install"
    exit 3
  fi
done

mkdir -p "$WORK"

CURRENT_STAGE="obtaining private Megas source"
echo "[1/10] Syncing private Megas source..."
if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh repo clone "$REPO" "$SRC" -- --branch "$BRANCH" --single-branch
  else
    set +e
    git clone --branch "$BRANCH" --single-branch "https://github.com/$REPO.git" "$SRC"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo
      echo "ERROR: The Megas repository is private and this Terminal is not authenticated to GitHub."
      echo "Authenticate GitHub in Terminal, then run this same command again."
      echo "If GitHub CLI is installed: gh auth login"
      exit 4
    fi
  fi
else
  git -C "$SRC" fetch origin "$BRANCH"
  git -C "$SRC" checkout "$BRANCH"
  git -C "$SRC" reset --hard "origin/$BRANCH"
fi

echo "      Source: $(git -C "$SRC" rev-parse --short HEAD)"

CURRENT_STAGE="compiling SwiftUI shell"
echo "[2/10] Compiling redesigned native SwiftUI shell..."
(
  cd "$SRC/worker/macos/MegasMoves.MacApp"
  swift build -c release
  test -x .build/release/MegasMoves
)
UI_BIN="$SRC/worker/macos/MegasMoves.MacApp/.build/release/MegasMoves"
file "$UI_BIN"
file "$UI_BIN" | grep -q "x86_64"
echo "      Native Intel UI verified."

CURRENT_STAGE="selecting Python"
echo "[3/10] Preparing Megas core build..."
PY=""
for candidate in python3.12 python3.11 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" - <<'PYVER' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PYVER
    then
      PY="$(command -v "$candidate")"
      break
    fi
  fi
done

FULL_CORE=0
CORE_BIN=""
BROWSERS=""

if [ -n "$PY" ]; then
  echo "      Python: $($PY --version)"
  CURRENT_STAGE="building current Megas core"
  echo "[4/10] Building current embedded Megas core..."
  VENV="$WORK/venv"
  if [ ! -x "$VENV/bin/python" ]; then
    "$PY" -m venv "$VENV"
  fi
  VPY="$VENV/bin/python"
  "$VPY" -m pip install --upgrade pip setuptools wheel pyinstaller
  "$VPY" -m pip install -e "$SRC/worker[test]"
  if [ -f "$SRC/backend/requirements.txt" ]; then
    "$VPY" -m pip install -r "$SRC/backend/requirements.txt"
  fi
  "$VPY" -m pip install pydantic-settings psutil 'cryptography>=46,<48'
  "$VPY" -m pip check

  echo "      Running focused operator tests..."
  (
    cd "$SRC"
    "$VPY" -m pytest -q       worker/tests/test_native_desktop_bridge.py       worker/tests/test_native_core_mcp_stdio.py       worker/tests/test_shared_context.py       worker/tests/test_actions.py       worker/tests/local/test_peer_mesh_auth.py       worker/tests/local/test_peer_pairing_gate.py
  )

  BROWSERS="$WORK/ms-playwright"
  mkdir -p "$BROWSERS"
  PLAYWRIGHT_BROWSERS_PATH="$BROWSERS" "$VPY" -m playwright install chromium

  (
    cd "$SRC"
    "$VPY" -m PyInstaller       --noconfirm --clean --onefile       --name 'MegasMoves.Core'       --paths worker       --paths backend       --collect-all playwright       --collect-submodules megas       worker/megas_native_core.py
  )
  CORE_BIN="$SRC/dist/MegasMoves.Core"
  test -x "$CORE_BIN"
  file "$CORE_BIN" | grep -q "x86_64"

  echo "      Smoke-testing embedded core..."
  "$VPY" - "$CORE_BIN" <<'PY'
import json, subprocess, sys
core = sys.argv[1]
p = subprocess.Popen([core], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
request = json.dumps({"method":"system.snapshot","params":{},"id":"local-intel-smoke"}) + "\n"
out, err = p.communicate(request, timeout=30)
line = next((line for line in out.splitlines() if line.strip()), "")
if not line:
    raise SystemExit("Core produced no response: " + err[-2000:])
json.loads(line)
print("      Core smoke test passed.")
PY
  FULL_CORE=1
else
  echo "      Python 3.11+ is not installed. Using installed Megas core safely."
  EXISTING="/Applications/Megas Moves.app"
  CORE_BIN="$EXISTING/Contents/MacOS/MegasMoves.Core"
  BROWSERS="$EXISTING/Contents/Resources/ms-playwright"
  if [ ! -x "$CORE_BIN" ]; then
    echo "ERROR: No reusable installed Megas core was found."
    echo "Install Python 3.11+ or keep the existing Megas Moves app in /Applications."
    exit 5
  fi
  echo "      The new UI will capability-gate native Mac actions against this older core."
fi

CURRENT_STAGE="rendering app icon"
echo "[5/10] Rendering Megas macOS icon..."
LOGO="$SRC/app/src/main/res/drawable/app_logo.png"
test -s "$LOGO"
ICON_WORK="$WORK/icon"
rm -rf "$ICON_WORK"
mkdir -p "$ICON_WORK/MegasMoves.iconset"

cat > "$ICON_WORK/round_icon.swift" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else { exit(2) }
guard let source = NSImage(contentsOfFile: CommandLine.arguments[1]) else { exit(3) }
let pixels = 1024
let side = CGFloat(pixels)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(4) }
bitmap.size = NSSize(width: side, height: side)
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(5) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let canvas = NSRect(x: 0, y: 0, width: side, height: side)
NSColor.clear.setFill()
canvas.fill(using: .copy)
let inset: CGFloat = 64
let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205).addClip()
source.draw(in: rect, from: NSRect(origin: .zero, size: source.size), operation: .sourceOver, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
for point in [(0,0),(pixels-1,0),(0,pixels-1),(pixels-1,pixels-1)] {
    guard let c = bitmap.colorAt(x: point.0, y: point.1), c.alphaComponent < 0.01 else { exit(6) }
}
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(7) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
SWIFT

swiftc "$ICON_WORK/round_icon.swift" -framework AppKit -o "$ICON_WORK/round_icon"
"$ICON_WORK/round_icon" "$LOGO" "$ICON_WORK/icon.png"

for spec in   "16 16 icon_16x16.png"   "32 32 icon_16x16@2x.png"   "32 32 icon_32x32.png"   "64 64 icon_32x32@2x.png"   "128 128 icon_128x128.png"   "256 256 icon_128x128@2x.png"   "256 256 icon_256x256.png"   "512 512 icon_256x256@2x.png"   "512 512 icon_512x512.png"   "1024 1024 icon_512x512@2x.png"; do
  set -- $spec
  sips -z "$1" "$2" "$ICON_WORK/icon.png" --out "$ICON_WORK/MegasMoves.iconset/$3" >/dev/null
done

iconutil -c icns "$ICON_WORK/MegasMoves.iconset" -o "$ICON_WORK/MegasMoves.icns"
test -s "$ICON_WORK/MegasMoves.icns"

CURRENT_STAGE="assembling app bundle"
echo "[6/10] Assembling native app bundle..."
APP="$WORK/Megas Moves.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$UI_BIN" "$APP/Contents/MacOS/MegasMoves"
cp "$CORE_BIN" "$APP/Contents/MacOS/MegasMoves.Core"
if [ -d "$BROWSERS" ]; then
  cp -R "$BROWSERS" "$APP/Contents/Resources/ms-playwright"
fi
cp "$ICON_WORK/MegasMoves.icns" "$APP/Contents/Resources/MegasMoves.icns"
chmod +x "$APP/Contents/MacOS/MegasMoves" "$APP/Contents/MacOS/MegasMoves.Core"

BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Megas Moves</string>
  <key>CFBundleDisplayName</key><string>Megas Moves</string>
  <key>CFBundleIdentifier</key><string>com.amretra.megasmoves</string>
  <key>CFBundleExecutable</key><string>MegasMoves</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>MegasMoves.icns</string>
  <key>CFBundleShortVersionString</key><string>0.5.0</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

CURRENT_STAGE="verifying Intel architecture"
echo "[7/10] Verifying Intel-native binaries..."
file "$APP/Contents/MacOS/MegasMoves" | grep -q "x86_64"
file "$APP/Contents/MacOS/MegasMoves.Core" | grep -q "x86_64"
echo "      UI + core are x86_64."

CURRENT_STAGE="ad-hoc signing"
echo "[8/10] Ad-hoc signing app..."
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

CURRENT_STAGE="creating DMG"
echo "[9/10] Creating verified DMG..."
STAGE="$WORK/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Megas Moves.app"
ln -s /Applications "$STAGE/Applications"

OUT="$OUT_DIR/MegasMoves-modern-macOS-Intel-$BUILD_NUMBER.dmg"
rm -f "$OUT" "$OUT.sha256"
hdiutil create -volname "Megas Moves Modern Intel" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
shasum -a 256 "$OUT" > "$OUT.sha256"

CURRENT_STAGE="mounting result"
echo "[10/10] Mounting finished DMG..."
for volume in /Volumes/"Megas Moves Modern Intel"*; do
  [ -d "$volume" ] && hdiutil detach "$volume" >/dev/null 2>&1 || true
done
hdiutil attach -nobrowse "$OUT" >/dev/null
open "/Volumes/Megas Moves Modern Intel"

echo
echo "SUCCESS"
echo "DMG: $OUT"
echo "SHA: $OUT.sha256"
if [ "$FULL_CORE" = "1" ]; then
  echo "Build mode: current redesigned UI + current rebuilt Megas core"
else
  echo "Build mode: current redesigned UI + safely capability-gated installed core"
fi
