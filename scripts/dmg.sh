#!/usr/bin/env bash
# Packs build/Tokenwick.app (made by scripts/bundle.sh) into a disk image:
# open it, drag Tokenwick onto the Applications shortcut, done.
#
#   ./scripts/bundle.sh && ./scripts/dmg.sh
#
# Writes build/Tokenwick.dmg and build/Tokenwick.dmg.sha256.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tokenwick"
OUT="build"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$APP_NAME.dmg"
VOLUME="Tokenwick"

[[ -d "$APP" ]] || { echo "No $APP yet. Run ./scripts/bundle.sh first." >&2; exit 1; }
codesign --verify --strict "$APP" || { echo "$APP has an invalid signature. Rebuild it." >&2; exit 1; }

stage="$(mktemp -d)"
# shellcheck disable=SC2064  # expand $stage now, on purpose
trap "rm -rf '$stage'" EXIT
# --norsrc/--noextattr: no hidden metadata or quarantine attributes in the image.
ditto --norsrc --noextattr --noacl "$APP" "$stage/$APP_NAME.app"
ln -s /Applications "$stage/Applications"

rm -f "$DMG" "$DMG.sha256"
# Compressed, read-only image. hdiutil occasionally fails with "Resource busy" right after
# a build (Spotlight or the disk arbitrator still looking at it), so retry a few times.
for attempt in 1 2 3; do
  if hdiutil create -quiet -volname "$VOLUME" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"; then
    break
  fi
  [[ $attempt == 3 ]] && { echo "hdiutil couldn't create the disk image." >&2; exit 1; }
  sleep 3
done
hdiutil verify -quiet "$DMG"

(cd "$OUT" && shasum -a 256 "$APP_NAME.dmg" > "$APP_NAME.dmg.sha256")
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' ')) and its .sha256"
