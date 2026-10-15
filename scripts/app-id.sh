#!/bin/bash
# Prints the bundle identifier a build of neoless.app carries (scripts/build-app.sh, scripts/install-mac.sh):
#   1. $NEOLESS_BUNDLE_ID, when set.
#   2. Else the identifier of the neoless already installed (1.0 or later): an update stays the same app to
#      macOS, so the permissions you granted, your settings and the pairing in the Keychain carry over.
#   3. Else the one in Resources/Info.plist.
# It must end in ".neoless": the app derives its Keychain service from it (Hub.keychainService).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${NEOLESS_INSTALL_APP:-/Applications/neoless.app}"

value() { # plist file, key: the value, or nothing
    [[ -f "$1" ]] || return 0
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

id="${NEOLESS_BUNDLE_ID:-}"
if [[ -z "$id" ]]; then
    installed="$(value "$APP/Contents/Info.plist" CFBundleIdentifier)"
    version="$(value "$APP/Contents/Info.plist" CFBundleShortVersionString)"
    if [[ "$installed" == *.neoless && -n "$version" && "$version" != 0.* ]]; then id="$installed"; fi
fi
if [[ -z "$id" ]]; then id="$(value Resources/Info.plist CFBundleIdentifier)"; fi
if [[ ! "$id" =~ ^[A-Za-z0-9.-]+\.neoless$ ]]; then
    echo "bundle identifier must be letters, digits, dots and hyphens, ending in .neoless: '$id'" >&2
    exit 1
fi
printf '%s\n' "$id"
