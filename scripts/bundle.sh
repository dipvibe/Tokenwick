#!/usr/bin/env bash
# Builds a release QuotaGoblin.app and a zip of it into ./build.
#
#   VERSION=1.2.0 ./scripts/bundle.sh   # set the app version (default 0.1.0)
#   UNIVERSAL=0 ./scripts/bundle.sh     # this Mac's architecture only (faster)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swiftpm-flags.sh

APP_NAME="QuotaGoblin"
VERSION="${VERSION:-0.1.0}"
BUNDLE_ID="${BUNDLE_ID:-dev.quotagoblin.QuotaGoblin}"
UNIVERSAL="${UNIVERSAL:-1}"
OUT="build"
APP="$OUT/$APP_NAME.app"

# These end up inside Info.plist (XML), so only allow safe characters.
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Invalid VERSION '$VERSION' (expected e.g. 1.2.3)" >&2; exit 1; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "Invalid BUNDLE_ID '$BUNDLE_ID'" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "$UNIVERSAL" == "1" ]]; then
  # One binary for Apple Silicon and Intel Macs.
  BINS=()
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx14.0"
    swift build -c release "${SWIFTPM_FLAGS[@]}" --triple "$triple"
    BINS+=("$(swift build -c release "${SWIFTPM_FLAGS[@]}" --triple "$triple" --show-bin-path)/$APP_NAME")
  done
  lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
  swift build -c release "${SWIFTPM_FLAGS[@]}"
  cp "$(swift build -c release "${SWIFTPM_FLAGS[@]}" --show-bin-path)/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
fi

# Menu bar icon shipped with the app (assets/). Users can still override it with their
# own file in ~/Library/Application Support/QuotaGoblin/ (see README).
shopt -s nullglob
for icon in assets/MenuBarIcon*.{pdf,svg,png}; do
  cp "$icon" "$APP/Contents/Resources/"
  echo "Bundling icon: $icon"
done
shopt -u nullglob

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Quota Goblin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

# Ad-hoc signature with the hardened runtime (blocks code injection via DYLD_* variables
# and unsigned libraries). Releases aren't notarized; see README.
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"

rm -f "$OUT/$APP_NAME.zip" "$OUT/$APP_NAME.zip.sha256"
# --norsrc/--noextattr/--noacl: no hidden ._ metadata files (or quarantine/provenance
# attributes) in the release. The bundle's signature doesn't depend on them.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$OUT/$APP_NAME.zip"
# Checksum published next to the zip; scripts/install.sh verifies downloads against it.
(cd "$OUT" && shasum -a 256 "$APP_NAME.zip" > "$APP_NAME.zip.sha256")
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME")), $OUT/$APP_NAME.zip and its .sha256"
