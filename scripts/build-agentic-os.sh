#!/bin/sh
# Builds Agentic OS (our fork of OpenClicky) and installs it to /Applications (GTD, 7 Nov 2026).
#   scripts/build-agentic-os.sh          build, install, reopen
# Signed with the local "Agentic OS Signing" certificate (made 10 Nov 2026 in the login keychain;
# falls back to ad-hoc if it is missing), without the hardened runtime: the bundled Sparkle and
# PostHog frameworks carry their makers' signatures and only load once the whole bundle is signed
# the same way. With the stable certificate, macOS keeps the app's Microphone, Accessibility and
# Screen Recording permissions across rebuilds; an ad-hoc build asks for them again every time.
set -e
set -o pipefail          # a failed xcodebuild stops the script: never install the previous build
cd "$(dirname "$0")/../macos/OpenClicky"
xcodebuild -project OpenClicky.xcodeproj -scheme OpenClicky -configuration Release \
  -derivedDataPath ../../build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="/Applications/Agentic OS.app"
osascript -e 'tell application "Agentic OS" to quit' 2>/dev/null || true
sleep 2
rm -rf "$APP"
ditto "../../build/Build/Products/Release/Agentic OS.app" "$APP"
# a stable identity keeps the macOS permissions across rebuilds: the local certificate, else an
# Apple Development one from Xcode → Settings → Accounts, else ad-hoc (asks again every build)
IDENTITY="Agentic OS Signing"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
  [ -n "$IDENTITY" ] || { echo "no signing certificate: signing ad-hoc (permissions will be asked again)"; IDENTITY="-"; }
fi
echo "signing as: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" --preserve-metadata=entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo "installed $APP"
open "$APP"
