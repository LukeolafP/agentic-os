#!/bin/sh
# Builds Agentic OS (our fork of OpenClicky) and installs it to /Applications (GTD, 7 Nov 2026).
#   scripts/build-agentic-os.sh          build, install, reopen
# Signed ad-hoc for this Mac, without the hardened runtime: the bundled Sparkle and PostHog
# frameworks carry their makers' signatures, and a self-signed app may only load them once the
# whole bundle is signed the same way. A rebuild changes the signature, so macOS asks again for
# Microphone, Accessibility and Screen Recording (an Apple ID in Xcode → Settings → Accounts
# would give a stable "Apple Development" certificate and stop that).
set -e
cd "$(dirname "$0")/../macos/OpenClicky"
xcodebuild -project OpenClicky.xcodeproj -scheme OpenClicky -configuration Release \
  -derivedDataPath ../../build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="/Applications/Agentic OS.app"
osascript -e 'tell application "Agentic OS" to quit' 2>/dev/null || true
sleep 2
rm -rf "$APP"
ditto "../../build/Build/Products/Release/Agentic OS.app" "$APP"
codesign --force --deep --sign - --preserve-metadata=entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo "installed $APP"
open "$APP"
