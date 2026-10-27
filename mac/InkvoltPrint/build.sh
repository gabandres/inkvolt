#!/bin/sh
# Builds "Inkvolt Print.app" from the Xcode project, signs it sandboxed with its entitlements, and installs it in
# /Applications. For development on the Mac; release.sh makes App Store builds.
#   ./build.sh          Release configuration
#   ./build.sh debug    Debug configuration
# Signs with the Apple Development identity in ~/Library/Keychains/inkvolt-dev.keychain-db (dev-cert.sh), unlocked with
# DEV_KEYCHAIN_PASSWORD from .env.local, so macOS keeps the app's Screen Recording and Local Network permissions from one
# build to the next. Without it, or with SIGN_IDENTITY=-, signs ad-hoc: a new app to macOS each time, which asks again.
set -eu
cd "$(dirname "$0")"

case "${1:-release}" in
  release) config=Release ;;
  debug) config=Debug ;;
  *) echo "usage: build.sh [release|debug]" >&2; exit 2 ;;
esac
identity="${SIGN_IDENTITY:-}"
team=
flags=
keychain="$HOME/Library/Keychains/inkvolt-dev.keychain-db"
password="$(sed -n 's/^DEV_KEYCHAIN_PASSWORD=//p' .env.local 2>/dev/null | tail -1)"
if [ -z "$identity" ] && [ -f "$keychain" ] && [ -n "$password" ]; then
  security unlock-keychain -p "$password" "$keychain"
  identity="$(security find-identity -v -p codesigning "$keychain" | awk '/^ *1\)/ { print $2; exit }')"
  team=AE6TTXW92K
  flags="--keychain $keychain"
fi
identity="${identity:--}"

xcodebuild -project InkvoltPrint.xcodeproj -scheme InkvoltPrint -configuration "$config" -derivedDataPath build/DerivedData -destination generic/platform=macOS \
  -quiet build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" PROVISIONING_PROFILE_SPECIFIER= \
  OTHER_CODE_SIGN_FLAGS="$flags"
app="build/DerivedData/Build/Products/$config/Inkvolt Print.app"
codesign --verify --strict "$app"

pkill -x "Inkvolt Print" 2>/dev/null || true
rm -rf "/Applications/Inkvolt Print.app"
ditto "$app" "/Applications/Inkvolt Print.app"
signer="$(codesign -dvv "/Applications/Inkvolt Print.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "Installed /Applications/Inkvolt Print.app ($config), signed by ${signer:-ad hoc}"
