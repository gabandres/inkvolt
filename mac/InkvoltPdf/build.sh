#!/bin/sh
# Builds Inkvolt PDF (release), makes "Inkvolt PDF.app" (assemble.sh: the binary, Info.plist and icons), signs it and
# installs it in /Applications. For development on the Mac; release.sh makes the notarized DMG.
#   sh mac/InkvoltPdf/build.sh
# Signs with the Apple Development identity in ~/Library/Keychains/inkvolt-dev.keychain-db (mac/InkvoltPrint/dev-cert.sh),
# unlocked with DEV_KEYCHAIN_PASSWORD from mac/InkvoltPrint/.env.local (INKVOLT_ENV names another file); ad hoc without
# it. Not sandboxed (the app opens whatever file the user picks); hardened runtime on.
set -eu
cd "$(dirname "$0")"

app="build/Inkvolt PDF.app"
sh ./assemble.sh "$app"

env="${INKVOLT_ENV:-../InkvoltPrint/.env.local}"
[ -f "$env" ] || env="$HOME/Repos/inkvolt/mac/InkvoltPrint/.env.local"
keychain="$HOME/Library/Keychains/inkvolt-dev.keychain-db"
password="$(sed -n 's/^DEV_KEYCHAIN_PASSWORD=//p' "$env" 2>/dev/null | tail -1)"
identity=-
flags=
if [ -f "$keychain" ] && [ -n "$password" ]; then
    security unlock-keychain -p "$password" "$keychain"
    identity="$(security find-identity -v -p codesigning "$keychain" | awk '/^ *1\)/ { print $2; exit }')"
    flags="--keychain $keychain"
fi
# shellcheck disable=SC2086
sh ./sign.sh "$app" --timestamp=none $flags --sign "${identity:--}"

pkill -x "Inkvolt PDF" 2>/dev/null || true
rm -rf "/Applications/Inkvolt PDF.app"
ditto "$app" "/Applications/Inkvolt PDF.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Inkvolt PDF.app"
signer="$(codesign -dvv "/Applications/Inkvolt PDF.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "Installed /Applications/Inkvolt PDF.app, signed by ${signer:-ad hoc}"
