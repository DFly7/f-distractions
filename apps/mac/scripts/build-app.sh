#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# A hash-based ad-hoc signature invalidates TCC grants on every code change.
# Use one stable development identity for every local build.
gatekeeper_signing_identity="${GATEKEEPER_SIGNING_IDENTITY:-}"
if [ -z "$gatekeeper_signing_identity" ]; then
    gatekeeper_signing_identity="$(security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/{print $2; exit}')"
fi
if [ -z "$gatekeeper_signing_identity" ]; then
    printf '%s\n' 'No Apple Development signing identity found. Add your developer account in Xcode, or set GATEKEEPER_SIGNING_IDENTITY to a valid signing identity.' >&2
    exit 1
fi
if pgrep -x Gatekeeper >/dev/null; then
    printf '%s\n' 'Quit Gatekeeper before rebuilding so the running app and its on-disk signature stay in sync.' >&2
    exit 1
fi
swift build -c release --product Gatekeeper
app_path="$PWD/dist/F Distractions.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/Gatekeeper "$app_path/Contents/MacOS/Gatekeeper"
icon_dir="$PWD/.build/Gatekeeper.iconset"
swift scripts/make-icon.swift "$icon_dir"
iconutil -c icns "$icon_dir" -o "$app_path/Contents/Resources/Gatekeeper.icns"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>Gatekeeper</string>
    <key>CFBundleIdentifier</key><string>dev.gatekeeper.poc</string>
    <key>CFBundleName</key><string>F Distractions</string>
    <key>CFBundleDisplayName</key><string>F Distractions</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>Gatekeeper.icns</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>F Distractions captures all connected displays during a focus session or a one-off check, to compare them with your stated goal. Pause or end a session to stop automatic captures.</string>
</dict></plist>
PLIST
codesign --force --sign "$gatekeeper_signing_identity" --timestamp=none "$app_path"
codesign --verify --strict "$app_path"
# Certificate-based designated requirements must remain stable across rebuilds.
gatekeeper_requirement="$(codesign -d -r- "$app_path" 2>&1)"
if [[ "$gatekeeper_requirement" == *'designated => cdhash'* ]]; then
    printf '%s\n' 'Build has an unstable ad-hoc signing requirement; refusing to ship it.' >&2
    exit 1
fi
# Keep existing local shortcuts working while exposing the new product name.
python3 - <<'PYLINK'
from pathlib import Path
import shutil
legacy = Path('dist/Gatekeeper.app')
if legacy.is_symlink():
    legacy.unlink()
elif legacy.is_dir():
    shutil.rmtree(legacy)
legacy.symlink_to('F Distractions.app', target_is_directory=True)
PYLINK
printf 'Built: %s\n' "$app_path"
