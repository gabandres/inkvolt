#!/bin/sh
# Builds InkvoltProbe.app, signs it sandboxed with the entitlements of Inkvolt Print, and installs it in /Applications.
#   ./build.sh            all entitlements (the App Store set)
#   ./build.sh noserver   without network.server (do SNMP replies still arrive?)
#   ./build.sh noprint    without print (can the app still reach cupsd?)
# SIGN_IDENTITY overrides the first "Apple Development" identity in the keychain.
set -eu
cd "$(dirname "$0")"

flavor="${1:-full}"
mkdir -p build
cp InkvoltProbe.entitlements build/probe.entitlements
case "$flavor" in
  full) ;;
  noserver) /usr/libexec/PlistBuddy -c "Delete :com.apple.security.network.server" build/probe.entitlements ;;
  noprint) /usr/libexec/PlistBuddy -c "Delete :com.apple.security.print" build/probe.entitlements ;;
  *) echo "usage: build.sh [full|noserver|noprint]" >&2; exit 2 ;;
esac

swift build -c release
bin="$(swift build -c release --show-bin-path)/InkvoltProbe"

app=build/InkvoltProbe.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/InkvoltProbe"
cp Info.plist "$app/Contents/Info.plist"

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [ -z "$identity" ]; then
  echo "No Apple Development identity in the keychain; set SIGN_IDENTITY." >&2
  exit 1
fi
codesign --force --options runtime --entitlements build/probe.entitlements --sign "$identity" "$app"
codesign --verify --strict "$app"

pkill -x InkvoltProbe 2>/dev/null || true
rm -rf /Applications/InkvoltProbe.app
ditto "$app" /Applications/InkvoltProbe.app
echo "Installed /Applications/InkvoltProbe.app ($flavor), signed by $identity"
