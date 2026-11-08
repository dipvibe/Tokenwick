#!/usr/bin/env bash
# Tokenwick installer.
# Downloads the latest release, verifies it, installs it and opens it.
#
#   Install or update:
#     curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/dipvibe/tokenwick/main/scripts/install.sh | bash
#   Uninstall (also removes the app's saved data):
#     curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/dipvibe/tokenwick/main/scripts/install.sh | bash -s -- --uninstall
#
# Options (environment variables):
#   TOKENWICK_INSTALL_DIR=~/Applications   install somewhere else (default: /Applications, or ~/Applications if not writable)
#   TOKENWICK_NO_LAUNCH=1                  don't open the app after installing
#
# Everything runs inside main(), called on the last line. If the download of this script
# is cut off halfway, bash only sees an unfinished function and runs nothing.
set -euo pipefail

REPO="${TOKENWICK_REPO:-dipvibe/tokenwick}"
BASE="${TOKENWICK_DOWNLOAD_BASE:-https://github.com/$REPO/releases/latest/download}"
APP="Tokenwick.app"
ZIP="Tokenwick.zip"
BUNDLE_ID="io.github.dipvibe.Tokenwick"
# HTTPS only (TLS 1.2+), including redirects. `file` is allowed solely for local testing
# through TOKENWICK_DOWNLOAD_BASE; a redirect can never switch to it.
CURL=(curl --proto '=https,file' --proto-redir '=https' --tlsv1.2 -fL --retry 3)

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

quit_running() {
  if pgrep -x Tokenwick >/dev/null 2>&1; then
    say "Quitting the running copy…"
    pkill -x Tokenwick || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x Tokenwick >/dev/null 2>&1 || return 0
      sleep 0.5
    done
  fi
}

uninstall() {
  local dest="$1" dir
  quit_running
  for dir in "$dest" /Applications "$HOME/Applications"; do
    if [[ -d "$dir/$APP" ]]; then
      rm -rf "${dir:?}/$APP"
      say "Removed $dir/$APP"
    fi
  done
  rm -rf "${HOME:?}/Library/Application Support/Tokenwick" \
         "${HOME:?}/Library/Caches/$BUNDLE_ID" \
         "${HOME:?}/Library/HTTPStorages/$BUNDLE_ID"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  say "Tokenwick is uninstalled. (Your Claude Code logs weren't touched.)"
}

# Every entry must sit inside Tokenwick.app/, with no absolute paths, ".." or symlinks.
check_zip_contents() {
  local entries entry
  entries="$(zipinfo -1 "$1" 2>/dev/null)" || fail "The download isn't a valid zip file. Nothing was installed."
  while IFS= read -r entry; do
    case "$entry" in
      "$APP"/*) ;;
      *) fail "Unexpected file in the download ($entry). Nothing was installed." ;;
    esac
    case "/$entry/" in
      */../*) fail "Unsafe path in the download ($entry). Nothing was installed." ;;
    esac
  done <<< "$entries"
  # No symlinks: a link entry followed by a file "inside" it is the classic way to make an
  # unzip write outside its folder. The app bundle never contains any. (The listing is read
  # into a variable first: with pipefail, `zipinfo | grep -q` can fail when grep exits early.)
  local listing
  listing="$(zipinfo "$1" 2>/dev/null)" || fail "The download isn't a valid zip file. Nothing was installed."
  if grep -q '^l' <<< "$listing"; then
    fail "The download contains a symbolic link, which Tokenwick never ships. Nothing was installed."
  fi
}

install_app() {
  local dest="$1" tmp expected actual bundle_id

  [[ "$REPO" != OWNER/* || -n "${TOKENWICK_DOWNLOAD_BASE:-}" ]] || fail "This installer hasn't been configured with a GitHub repo yet."
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $tmp now, on purpose
  trap "rm -rf '$tmp'" EXIT

  say "Downloading Tokenwick…"
  "${CURL[@]}" --progress-bar -o "$tmp/$ZIP" "$BASE/$ZIP" \
    || fail "Download failed. Check your internet connection, or see $BASE"
  "${CURL[@]}" -sS -o "$tmp/$ZIP.sha256" "$BASE/$ZIP.sha256" \
    || fail "Couldn't download the checksum file."

  say "Verifying the download…"
  # Compare hashes directly. `shasum -c` would check whatever file name the
  # downloaded checksum file names, which isn't necessarily our zip.
  expected="$(awk 'NR==1 {print tolower($1)}' "$tmp/$ZIP.sha256")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "The checksum file is malformed. Nothing was installed."
  actual="$(shasum -a 256 "$tmp/$ZIP" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] \
    || fail "Checksum mismatch: the download is corrupted or was tampered with. Nothing was installed."

  check_zip_contents "$tmp/$ZIP"
  ditto -x -k "$tmp/$ZIP" "$tmp/unzipped"
  [[ -d "$tmp/unzipped/$APP" ]] || fail "The download doesn't contain $APP. Nothing was installed."
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$tmp/unzipped/$APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$bundle_id" == "$BUNDLE_ID" ]] || fail "The download isn't Tokenwick (bundle ID '$bundle_id'). Nothing was installed."
  codesign --verify --strict "$tmp/unzipped/$APP" >/dev/null 2>&1 \
    || fail "The app's code signature is invalid. Nothing was installed."

  quit_running
  mkdir -p "$dest"
  rm -rf "${dest:?}/$APP"
  ditto "$tmp/unzipped/$APP" "$dest/$APP"
  say "Installed to $dest/$APP"

  if [[ -z "${TOKENWICK_NO_LAUNCH:-}" ]]; then
    open "$dest/$APP"
    say "Done! Look for the icon in your menu bar. Click it for details, hover for a summary."
    say "Tip: tick \"Launch at login\" in the panel to start it automatically."
  fi
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "Tokenwick only runs on macOS."
  [[ "$(id -u)" -ne 0 ]] || fail "Don't run this with sudo. It installs for your user account and doesn't need admin rights."
  : "${HOME:?HOME is not set}"
  local macos dest
  macos="$(sw_vers -productVersion)"
  (( ${macos%%.*} >= 14 )) || fail "macOS 14 (Sonoma) or later is required. This Mac has macOS $macos."

  if [[ -n "${TOKENWICK_INSTALL_DIR:-}" ]]; then
    dest="${TOKENWICK_INSTALL_DIR/#\~/$HOME}"
  elif [[ -w /Applications ]]; then
    dest="/Applications"
  else
    dest="$HOME/Applications"
  fi

  case "${1:-}" in
    --uninstall) uninstall "$dest" ;;
    "") install_app "$dest" ;;
    *) fail "Unknown option '$1'. Use no option to install or update, or --uninstall." ;;
  esac
}

main "$@"
