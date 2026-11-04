#!/bin/bash
# Builds Notchbench and installs it to /Applications/Notchbench.app.
# Usage: ./install-local.sh
#
# Local build only: signed "ad hoc" (no Apple developer account), so hardened
# runtime is off. Otherwise macOS refuses to load the app's own frameworks.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building (Release)…"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" \
  ENABLE_HARDENED_RUNTIME=NO \
  build > build-release.log 2>&1 || { grep -E "error:" build-release.log | head -20; echo "Build failed, see build-release.log"; exit 1; }

echo "Installing…"
osascript -e 'quit app id "dev.edincokic.notchbench"' 2>/dev/null || true
sleep 2
rm -rf /Applications/Notchbench.app
ditto "build/Build/Products/Release/Notchbench.app" /Applications/Notchbench.app
open /Applications/Notchbench.app
echo "Done: /Applications/Notchbench.app is running."
