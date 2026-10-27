#!/bin/zsh -l
# Makes Inkvolt PDF's notarized DMG for distribution outside the App Store (Developer ID).
#   nohup zsh mac/InkvoltPdf/release.sh <version> > ~/build-artifacts/inkvolt-pdf-mac/release.log 2>&1 &
# <version> (1.0 or 1.0.1) becomes CFBundleShortVersionString and CFBundleVersion (Sparkle compares the latter).
# Steps: assemble.sh (release build, warnings as errors, icons); sign with the Developer ID Application identity in
# ~/Library/Keychains/inkvolt-devid.keychain-db (mac/InkvoltPrint/devid-cert.sh), hardened runtime, secure timestamp, no
# entitlements (not sandboxed, MuPDF linked statically, no JIT or library loading to allow); notarize the app (zipped)
# and staple it; a DMG of the app and an /Applications link; sign, notarize and staple the DMG; Gatekeeper checks on both.
# notarytool authenticates with the App Store Connect API key, as Inkvolt Print's release.sh. Keys from
# mac/InkvoltPrint/.env.local (INKVOLT_ENV names another file; not in git): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH,
# DEVID_KEYCHAIN_PASSWORD. Publishes nothing.
# Run detached (nohup), never in a foreground SSH session: ~/build-artifacts/inkvolt-pdf-mac/status says
# RUNNING <start> <args>, then DONE or FAILED <exit code> <end>. The DMG and notarytool's logs go there too.
set -u
cd "$(dirname "$0")" || exit 90
VERSION=${1:?usage: release.sh <version>}
[[ $VERSION =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { echo "version must be like 1.0 or 1.0.1"; exit 2; }
OUT=~/build-artifacts/inkvolt-pdf-mac
mkdir -p $OUT
echo "RUNNING $(date -u +%FT%TZ) $*" > $OUT/status
trap 'code=$?; if [ $code -eq 0 ]; then echo "DONE 0 $(date -u +%FT%TZ)"; else echo "FAILED $code $(date -u +%FT%TZ)"; fi > $OUT/status' EXIT
export DEVELOPER_DIR=/Applications/Xcode-27.1.0.app/Contents/Developer # a release Xcode, as Inkvolt Print's

envfile="${INKVOLT_ENV:-../InkvoltPrint/.env.local}"
[ -f "$envfile" ] || envfile="$HOME/Repos/inkvolt/mac/InkvoltPrint/.env.local" # a worktree has no .env.local
setting() { sed -n "s/^$1=//p" "$envfile" | tail -1 | sed "s/^[\"']//; s/[\"']\$//"; }
ASC_KEY_ID="$(setting ASC_KEY_ID)"; ASC_ISSUER_ID="$(setting ASC_ISSUER_ID)"; ASC_KEY_PATH="$(setting ASC_KEY_PATH)"
ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
[ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -f "$ASC_KEY_PATH" ] || { echo "ASC_* missing in $envfile"; exit 91; }
KEYCHAIN="$HOME/Library/Keychains/inkvolt-devid.keychain-db"
IDENTITY="Developer ID Application: Bermudez Systems LLC (AE6TTXW92K)"
security unlock-keychain -p "$(setting DEVID_KEYCHAIN_PASSWORD)" "$KEYCHAIN" || { echo "can't unlock $KEYCHAIN (DEVID_KEYCHAIN_PASSWORD)"; exit 91; }
security find-identity -v -p codesigning "$KEYCHAIN" | grep -qF "\"$IDENTITY\"" || { echo "no $IDENTITY in $KEYCHAIN"; exit 91; }

WORK=$OUT/work-$VERSION
DMG="$OUT/Inkvolt-PDF-$VERSION.dmg"
APP="$WORK/Inkvolt PDF.app"
rm -rf $WORK "$DMG"
mkdir -p $WORK

# notarize <file> <name>: submits, waits, keeps Apple's log as $OUT/notary-<name>-$VERSION.json; fails unless Accepted.
notarize() {
  xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --output-format json > $WORK/submit-$2.json
  local id="$(plutil -extract id raw -o - $WORK/submit-$2.json 2>/dev/null)"
  local notary_status="$(plutil -extract status raw -o - $WORK/submit-$2.json 2>/dev/null)"
  echo "NOTARY $2 id=$id status=$notary_status"
  [ -n "$id" ] && xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    $OUT/notary-$2-$VERSION.json > /dev/null
  [ "$notary_status" = "Accepted" ]
}

sign() { codesign --force --timestamp --keychain "$KEYCHAIN" --sign "$IDENTITY" "$@"; }

# The app.
sh ./assemble.sh "$APP" || exit 92
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist" || exit 92
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist" || exit 92
sign --options runtime "$APP" || exit 93
codesign --verify --strict --deep "$APP" || exit 93
ditto -c -k --keepParent "$APP" $WORK/app.zip || exit 94
notarize $WORK/app.zip app || exit 94
xcrun stapler staple "$APP" && xcrun stapler validate "$APP" || exit 95

# The DMG: the app and an /Applications link in a plain window. The Finder layout needs Automation permission for
# whatever runs this; without it (an SSH session, say) the DMG keeps Finder's default window.
mkdir $WORK/dmg && ditto "$APP" "$WORK/dmg/Inkvolt PDF.app" && ln -s /Applications $WORK/dmg/Applications || exit 96
hdiutil create -volname "Inkvolt PDF" -srcfolder $WORK/dmg -fs HFS+ -format UDRW -ov $WORK/rw.dmg >/dev/null || exit 96
mount=$WORK/mnt
mkdir $mount && hdiutil attach $WORK/rw.dmg -readwrite -noverify -noautoopen -mountpoint $mount >/dev/null || exit 96
osascript > /dev/null 2>&1 <<'APPLESCRIPT' &
tell application "Finder"
  tell disk "Inkvolt PDF"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 760, 460}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set position of item "Inkvolt PDF.app" of container window to {150, 160}
    set position of item "Applications" of container window to {410, 160}
    close
  end tell
end tell
APPLESCRIPT
layout=$!
( sleep 60; kill $layout 2>/dev/null ) &
wait $layout 2>/dev/null && echo "DMG window laid out" || echo "DMG window: Finder's default (no Automation permission)"
rm -rf $mount/.fseventsd
sync
hdiutil detach $mount -quiet || hdiutil detach $mount -force -quiet || exit 96
hdiutil convert $WORK/rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null || exit 96
sign "$DMG" || exit 97
notarize "$DMG" dmg || exit 98
xcrun stapler staple "$DMG" && xcrun stapler validate "$DMG" || exit 99

# Gatekeeper, as a downloaded copy would meet it: the DMG, then the app inside it.
spctl -a -t open --context context:primary-signature -v "$DMG" || exit 100
mkdir $WORK/check && hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint $WORK/check >/dev/null || exit 100
spctl -a -vv "$WORK/check/Inkvolt PDF.app"; ok=$?
hdiutil detach $WORK/check -quiet
[ $ok -eq 0 ] || exit 100
rm -rf $WORK
echo "RELEASE_DONE $DMG $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
