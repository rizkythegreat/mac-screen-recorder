#!/bin/sh
# Builds build/Studio.app (release) and checks the core logic first.
set -eu
cd "$(dirname "$0")"

swift build -c release
.build/release/Studio --selftest

APP=build/Studio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Studio "$APP/Contents/MacOS/Studio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature: macOS asks for Screen Recording again after each rebuild.
# Sign with your Apple Development identity instead to keep the permission.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
