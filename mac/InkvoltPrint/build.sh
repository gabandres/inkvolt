#!/bin/sh
# Builds "Inkvolt Print.app" from the Xcode project, signs it sandboxed with its entitlements, and installs it in
# /Applications. For development on the Mac; release.sh makes App Store builds.
#   ./build.sh          Release configuration
#   ./build.sh debug    Debug configuration
# SIGN_IDENTITY: "-" (the default) signs ad-hoc, which may make macOS ask for Local Network access again after a build;
# an "Apple Development" identity's name signs with it.
set -eu
cd "$(dirname "$0")"

case "${1:-release}" in
  release) config=Release ;;
  debug) config=Debug ;;
  *) echo "usage: build.sh [release|debug]" >&2; exit 2 ;;
esac
identity="${SIGN_IDENTITY:--}"

xcodebuild -project InkvoltPrint.xcodeproj -scheme InkvoltPrint -configuration "$config" -derivedDataPath build/DerivedData -destination generic/platform=macOS \
  -quiet build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
app="build/DerivedData/Build/Products/$config/Inkvolt Print.app"
codesign --verify --strict "$app"

pkill -x "Inkvolt Print" 2>/dev/null || true
rm -rf "/Applications/Inkvolt Print.app"
ditto "$app" "/Applications/Inkvolt Print.app"
echo "Installed /Applications/Inkvolt Print.app ($config), signed by $identity"
