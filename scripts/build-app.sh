#!/bin/bash
# Builds neoless.app. Usage:
#   scripts/build-app.sh            build into ./build/neoless.app
#   scripts/build-app.sh --install  also replace /Applications/neoless.app and relaunch it
#
# Signing: uses the identity in $NEOLESS_SIGN_IDENTITY if set (a stable identity keeps
# macOS permissions across rebuilds); otherwise ad-hoc, which makes macOS ask again
# for Accessibility/Microphone after every rebuild.
#
# Bundle identifier: scripts/app-id.sh. A neoless that is already installed keeps its identifier (so an
# update is the same app to macOS); a first install gets the one in Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="$(scripts/app-id.sh)"

# Only the app: the hub (neoless-hub, Hummingbird) is built and deployed on its own.
swift build -c release --arch arm64 --product neoless
BIN="$(swift build -c release --arch arm64 --show-bin-path)/neoless"

APP=build/neoless.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/neoless"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID.pair" "$APP/Contents/Info.plist"
cp Resources/neoless.icns "$APP/Contents/Resources/neoless.icns"

IDENTITY="${NEOLESS_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-certificate -c "neoless Local Signing" >/dev/null 2>&1; then
    IDENTITY="neoless Local Signing"   # created by scripts/make-signing-identity.sh
  else
    IDENTITY="-"
  fi
fi
if ! codesign --force --timestamp=none --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"; then
  echo "warning: signing with '$IDENTITY' failed, falling back to ad-hoc" >&2
  IDENTITY="-"
  codesign --force --timestamp=none --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"
echo "built $APP ($BUNDLE_ID, signed with: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x neoless >/dev/null || break; sleep 0.3; done
  pkill -x neoless 2>/dev/null || true
  rm -rf /Applications/neoless.app
  cp -R "$APP" /Applications/neoless.app
  open /Applications/neoless.app --args --show
  echo "installed /Applications/neoless.app"
fi
