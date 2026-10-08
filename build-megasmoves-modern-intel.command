#!/bin/bash
set -Eeuo pipefail

BRANCH="mac-intel-current-main-20261008"
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

CURRENT_STAGE="authenticating GitHub"
echo "[1/10] Preparing authenticated GitHub access..."

GH_BIN="$(command -v gh || true)"
if [ -z "$GH_BIN" ]; then
  if command -v brew >/dev/null 2>&1; then
    echo "      Installing GitHub CLI with Homebrew..."
    brew install gh
    GH_BIN="$(command -v gh || true)"
  else
    echo "      GitHub CLI not found; installing a portable Intel copy..."
    GH_ROOT="$WORK/github-cli"
    rm -rf "$GH_ROOT"
    mkdir -p "$GH_ROOT"

    RELEASE_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' https://api.github.com/repos/cli/cli/releases/latest)"
    GH_URL="$(printf '%s' "$RELEASE_JSON" | tr ',' '\n' | grep -Eo 'https://[^"]+gh_[^"]+_macOS_amd64\.(zip|tar\.gz)' | head -n 1 || true)"
    if [ -z "$GH_URL" ]; then
      echo "ERROR: Could not locate the current Intel macOS GitHub CLI package."
      exit 4
    fi

    GH_ARCHIVE="$GH_ROOT/gh-download"
    curl -fL "$GH_URL" -o "$GH_ARCHIVE"

    case "$GH_URL" in
      *.zip)
        ditto -x -k "$GH_ARCHIVE" "$GH_ROOT/unpacked"
        ;;
      *.tar.gz)
        mkdir -p "$GH_ROOT/unpacked"
        tar -xzf "$GH_ARCHIVE" -C "$GH_ROOT/unpacked"
        ;;
      *)
        echo "ERROR: Unsupported GitHub CLI archive."
        exit 4
        ;;
    esac

    GH_BIN="$(find "$GH_ROOT/unpacked" -type f -path '*/bin/gh' -perm +111 | head -n 1 || true)"
    if [ -z "$GH_BIN" ]; then
      echo "ERROR: GitHub CLI binary was not found after extraction."
      exit 4
    fi
  fi
fi

echo "      GitHub CLI: $GH_BIN"

if ! "$GH_BIN" auth status --hostname github.com >/dev/null 2>&1; then
  echo
  echo "GitHub authentication is required once because MegasMoves is private."
  echo "A browser/device login will open. Sign into the GitHub account that owns MegasMoves."
  echo
  "$GH_BIN" auth login --hostname github.com --git-protocol https --web
fi

"$GH_BIN" auth status --hostname github.com
"$GH_BIN" auth setup-git

CURRENT_STAGE="obtaining private Megas source"
echo "      Preparing private Megas source..."
# The exact product-source integration commit, independent of later CI edits.
# It is safe to use this verified commit from the existing clone when GitHub DNS
# cannot resolve. Never fall back to an arbitrary or unverified FETCH_HEAD.
REQUIRED_SOURCE_COMMIT="9c0aedddc2792bdcf986617648ef70ec4178e150"
if [ ! -d "$SRC/.git" ]; then
  echo "      No cached checkout found; cloning authenticated private repo..."
  "$GH_BIN" repo clone "$REPO" "$SRC" -- --branch "$BRANCH" --single-branch
else
  echo "      Resuming existing Megas source clone..."
  if ! git -C "$SRC" diff --quiet || ! git -C "$SRC" diff --cached --quiet; then
    echo "ERROR: Existing source clone has uncommitted changes; refusing to discard them."
    echo "Review the clone at: $SRC"
    exit 7
  fi

  SOURCE_REF=""
  echo "      Checking GitHub for updated source..."
  if git -C "$SRC" fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"; then
    SOURCE_REF="refs/remotes/origin/$BRANCH"
    if ! git -C "$SRC" merge-base --is-ancestor "$REQUIRED_SOURCE_COMMIT" "$SOURCE_REF"; then
      echo "ERROR: Fetched source is missing the required native Mac integration commit."
      exit 8
    fi
  else
    echo "      GitHub could not be reached. Checking exact previously downloaded source commit..."
    if git -C "$SRC" cat-file -e "${REQUIRED_SOURCE_COMMIT}^{commit}" 2>/dev/null; then
      SOURCE_REF="$REQUIRED_SOURCE_COMMIT"
      echo "      Verified exact cached Megas Mac integration commit. Proceeding offline."
    else
      echo "ERROR: GitHub DNS/network is unavailable and the required source commit is not cached."
      echo "Fix your Mac's internet/DNS connection, then rerun this command."
      exit 8
    fi
  fi
  git -C "$SRC" checkout -B "$BRANCH" "$SOURCE_REF"
fi

if ! git -C "$SRC" merge-base --is-ancestor "$REQUIRED_SOURCE_COMMIT" HEAD; then
  echo "ERROR: Source verification failed: required native Mac integration commit is missing."
  exit 8
fi
echo "      Source: $(git -C "$SRC" rev-parse --short HEAD) (verified)"

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

CURRENT_STAGE="selecting compatible Python"
echo "[3/10] Preparing Python 3.12 for the pinned Megas backend..."
# backend/requirements.txt currently pins psycopg2-binary==2.9.9 and
# tree-sitter-languages==1.10.2. They ship Intel macOS wheels for CPython 3.12,
# but not 3.13. Keep the user's Python 3.13 and Apple system Python untouched.
VENV="$WORK/venv"
PY=""
for candidate in python3.12 /usr/local/bin/python3.12 /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12; do
  if command -v "$candidate" >/dev/null 2>&1; then
    candidate_bin="$(command -v "$candidate")"
    if "$candidate_bin" - <<'PYVER' >/dev/null 2>&1
import platform, sys
raise SystemExit(0 if sys.version_info[:2] == (3, 12) and platform.machine() == "x86_64" else 1)
PYVER
    then
      PY="$candidate_bin"
      break
    fi
  fi
done

if [ -z "$PY" ]; then
  echo "      Python 3.12 is not installed. Preparing isolated managed Python 3.12..."
  UV_BIN="$(command -v uv || true)"
  if [ -z "$UV_BIN" ]; then
    BOOTSTRAP_PY=""
    for candidate in python3.13 /usr/local/bin/python3.13 python3; do
      if command -v "$candidate" >/dev/null 2>&1; then
        if "$candidate" - <<'PYVER' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PYVER
        then
          BOOTSTRAP_PY="$(command -v "$candidate")"
          break
        fi
      fi
    done
    if [ -z "$BOOTSTRAP_PY" ]; then
      echo "ERROR: Python 3.11+ is needed once to bootstrap uv. No system Python was modified."
      exit 5
    fi
    BOOTSTRAP_VENV="$WORK/uv-bootstrap"
    if [ ! -x "$BOOTSTRAP_VENV/bin/python" ]; then
      "$BOOTSTRAP_PY" -m venv "$BOOTSTRAP_VENV"
    fi
    "$BOOTSTRAP_VENV/bin/python" -m pip install --only-binary=:all: 'uv>=0.8,<1'
    UV_BIN="$BOOTSTRAP_VENV/bin/uv"
  fi
  export UV_PYTHON_INSTALL_DIR="$WORK/managed-python"
  if [ -e "$VENV/bin/python" ] && ! "$VENV/bin/python" -c 'import sys; assert sys.version_info[:2] == (3, 12)' >/dev/null 2>&1; then
    echo "      Replacing only the previous Megas build virtualenv (Python 3.13)."
    rm -rf "$VENV"
  fi
  if [ ! -x "$VENV/bin/python" ]; then
    "$UV_BIN" venv --python 3.12 --seed "$VENV"
  fi
  PY="$VENV/bin/python"
else
  if [ -x "$VENV/bin/python" ]; then
    if ! "$VENV/bin/python" -c 'import sys; assert sys.version_info[:2] == (3, 12)' >/dev/null 2>&1; then
      echo "      Replacing only the previous Megas build virtualenv (Python 3.13)."
      rm -rf "$VENV"
    fi
  fi
  if [ ! -x "$VENV/bin/python" ]; then
    "$PY" -m venv "$VENV"
  fi
fi

VPY="$VENV/bin/python"
"$VPY" - <<'PYVER'
import platform, sys
print("      Selected build Python: " + sys.version)
print("      Architecture: " + platform.machine())
assert sys.version_info[:2] == (3, 12), "Backend wheel pins require CPython 3.12"
assert platform.machine() == "x86_64", "Intel x86_64 Python required"
PYVER

FULL_CORE=0
CORE_BIN=""
BROWSER_RUNTIME=""

if [ -x "$VPY" ]; then
  echo "      Python: $($VPY --version)"
  CURRENT_STAGE="building current Megas core"
  echo "[4/10] Building current embedded Megas core..."
  "$VPY" -m pip install --upgrade pip setuptools wheel pyinstaller
  "$VPY" -m pip install -e "$SRC/worker[test]"
  if [ -f "$SRC/backend/requirements.txt" ]; then
    # This desktop build shares an environment with pyOpenSSL, which requires
    # cryptography>=46,<48. The backend's exact 45.0.5 pin is intentionally
    # preserved in Git; omit that one incompatible line only from an ephemeral
    # Mac build requirements copy, and resolve the compatible driver once.
    "$VPY" - "$SRC/backend/requirements.txt" "$WORK/backend-intel-requirements.txt" <<'PYREQ'
from pathlib import Path
import sys
source, target = map(Path, sys.argv[1:])
rows = source.read_text(encoding="utf-8").splitlines()
out = [row for row in rows if row.strip() != "cryptography==45.0.5"]
if len(rows) - len(out) != 1:
    raise SystemExit("Expected one backend cryptography==45.0.5 pin; review backend dependencies before building")
target.write_text("\n".join(out) + "\n", encoding="utf-8")
PYREQ
    "$VPY" -m pip install --only-binary=:all: -r "$WORK/backend-intel-requirements.txt" 'cryptography>=46,<48'
  else
    "$VPY" -m pip install 'cryptography>=46,<48'
  fi
  "$VPY" -m pip install pydantic-settings psutil
  "$VPY" -m pip check
  "$VPY" - <<'PYCRYPTO'
from importlib.metadata import version
from packaging.version import Version
installed = Version(version("cryptography"))
assert Version("46.0.0") <= installed < Version("48.0.0"), installed
print(f"      Verified compatible cryptography {installed} for Mac core")
PYCRYPTO

  echo "      Running focused native operator and browser security tests..."
  (
    cd "$SRC"
    "$VPY" -m pytest -q --basetemp "$WORK/pytest-intel" \
      worker/tests/test_native_desktop_bridge.py \
      worker/tests/test_native_desktop_peer_mesh.py \
      worker/tests/test_firebase_account.py \
      worker/tests/test_browser_operator_contract.py \
      worker/tests/test_browser_desktop_packaging.py \
      worker/tests/test_browser_runtime_manifest_symlinks.py \
      worker/tests/local/test_peer_mesh_auth.py \
      worker/tests/local/test_peer_pairing_gate.py
  )

  echo "      Building verified Megas Browser runtime..."
  (
    cd "$SRC"
    "$VPY" worker/scripts/browser_runtime_build.py "$WORK/browser-runtime"
  )
  BROWSER_RUNTIME="$WORK/browser-runtime"
  test -s "$BROWSER_RUNTIME/megas-browser-runtime.json"

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
data = json.loads(line)
if data.get("ok") is not True or "result" not in data:
    raise SystemExit("Core returned an invalid desktop envelope: " + line[:2000])
result = data["result"]
for key in ("local_testing", "account", "agents", "tasks", "actions", "terminals", "activity"):
    if key not in result:
        raise SystemExit("Core snapshot is missing " + key)
print("      Core snapshot envelope + product surfaces verified.")
PY
  FULL_CORE=1
else
  echo "      Python 3.11+ is not installed. Using installed Megas core safely."
  EXISTING="/Applications/Megas Moves.app"
  CORE_BIN="$EXISTING/Contents/MacOS/MegasMoves.Core"
  if [ -d "$EXISTING/Contents/Resources/browser-runtime" ]; then
    BROWSER_RUNTIME="$EXISTING/Contents/Resources/browser-runtime"
  elif [ -d "$EXISTING/Contents/Resources/ms-playwright" ]; then
    BROWSER_RUNTIME="$EXISTING/Contents/Resources/ms-playwright"
  fi
  if [ ! -x "$CORE_BIN" ]; then
    echo "ERROR: No reusable installed Megas core was found."
    echo "Install Python 3.11+ or keep the existing Megas Moves app in /Applications."
    exit 5
  fi
  echo "      The new UI will capability-gate native Mac actions against this older core."
fi

CURRENT_STAGE="rendering Megas vector app icon"
echo "[5/10] Rendering the same Megas mark used by the SwiftUI sidebar..."
ICON_WORK="$WORK/icon"
mkdir -p "$ICON_WORK/MegasMoves.iconset"

MARK_SOURCE="$SRC/worker/macos/MegasMoves.MacApp/Sources/MegasMoves/MegasBrandMark.swift"
RENDER_SOURCE="$SRC/worker/scripts/macos_brand_icon.swift"
test -s "$MARK_SOURCE"
test -s "$RENDER_SOURCE"
swiftc -parse-as-library "$MARK_SOURCE" "$RENDER_SOURCE" -framework AppKit -framework SwiftUI -o "$ICON_WORK/render-megas-brand"
"$ICON_WORK/render-megas-brand" "$ICON_WORK/icon.png"

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
if [ -n "$BROWSER_RUNTIME" ] && [ -d "$BROWSER_RUNTIME" ]; then
  cp -R "$BROWSER_RUNTIME" "$APP/Contents/Resources/browser-runtime"
  if [ "$FULL_CORE" = "1" ]; then
    echo "      Verifying packaged browser runtime manifest..."
    PYTHONPATH="$SRC/worker" "$VPY" - "$APP/Contents/Resources/browser-runtime" <<'PYRUNTIME'
import sys
from pathlib import Path
from megas.browser_runtime_manifest import verify_runtime_manifest
root = Path(sys.argv[1])
result = verify_runtime_manifest(root, expected_playwright_version="1.61.0")
print(f"      Verified browser payload: {result['file_count']} files")
PYRUNTIME
  fi
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
