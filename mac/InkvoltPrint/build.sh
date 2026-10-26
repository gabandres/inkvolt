#!/bin/sh
# Builds "Inkvolt Print.app", signs it sandboxed with its entitlements, and installs it in /Applications.
#   ./build.sh          release build
#   ./build.sh debug    debug build
# SIGN_IDENTITY overrides the first "Apple Development" identity in the keychain ("-": ad-hoc, which may make macOS ask
# for Local Network access again after each build).
set -eu
cd "$(dirname "$0")"

config="${1:-release}"
case "$config" in
  release|debug) ;;
  *) echo "usage: build.sh [release|debug]" >&2; exit 2 ;;
esac

swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/InkvoltPrint"

app="build/Inkvolt Print.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Demo"
cp "$bin" "$app/Contents/MacOS/InkvoltPrint"
cp Info.plist "$app/Contents/Info.plist"
cp PrivacyInfo.xcprivacy "$app/Contents/Resources/"
# Demo mode's made-up printers: the scrubbed test fixtures, as the Windows app embeds them.
fixtures=../../print/tests/InkvoltPrint.Tests/Fixtures
for set in m234dw hp-demo inkjet-demo cdm-laser snmp-demo; do
  cp -R "$fixtures/$set" "$app/Contents/Resources/Demo/$set"
done

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [ -z "$identity" ]; then
  echo "No Apple Development identity in the keychain; set SIGN_IDENTITY (- for ad-hoc)." >&2
  exit 1
fi
codesign --force --options runtime --entitlements InkvoltPrint.entitlements --sign "$identity" "$app"
codesign --verify --strict "$app"

pkill -x InkvoltPrint 2>/dev/null || true
rm -rf "/Applications/Inkvolt Print.app"
ditto "$app" "/Applications/Inkvolt Print.app"
echo "Installed /Applications/Inkvolt Print.app ($config), signed by $identity"
