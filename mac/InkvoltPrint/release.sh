#!/bin/zsh -l
# Builds Inkvolt Print for the Mac App Store and, with --upload, sends it to App Store Connect (TestFlight).
#   mac/InkvoltPrint/release.sh <build number> [--upload]
# As Inkvolt mobile's scripts/ios-release.sh: no Apple ID and no certificate in the keychain. Xcode signs the export with
# the team's cloud-managed distribution certificates, authenticated by the App Store Connect API key named in .env.local
# beside this file (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH; not in git); altool uploads with the same key (it looks for
# AuthKey_<id>.p8 in ~/.appstoreconnect/private_keys). The build number must be new: App Store Connect refuses one it
# has seen. Run detached (nohup), never in a foreground SSH session. ~/build-artifacts/inkvolt-print-mac/status says
# RUNNING <start> <args>, then DONE or FAILED <exit code> <end>: a session that restarted while this ran reads it instead
# of running the upload again.
set -u
cd "$(dirname "$0")" || exit 90
source ./.env.local
BUILD=${1:?usage: release.sh <build number> [--upload]}
OUT=~/build-artifacts/inkvolt-print-mac
mkdir -p $OUT
echo "RUNNING $(date -u +%FT%TZ) $*" > $OUT/status
trap 'code=$?; if [ $code -eq 0 ]; then echo "DONE 0 $(date -u +%FT%TZ)"; else echo "FAILED $code $(date -u +%FT%TZ)"; fi > $OUT/status' EXIT
rm -rf $OUT/InkvoltPrint.xcarchive $OUT/export
export DEVELOPER_DIR=/Applications/Xcode-27.1.0.app/Contents/Developer # a release Xcode: a beta's builds can't be submitted

xcodebuild -project InkvoltPrint.xcodeproj -scheme InkvoltPrint -configuration Release -destination generic/platform=macOS \
  -archivePath $OUT/InkvoltPrint.xcarchive archive CURRENT_PROJECT_VERSION=$BUILD \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO || exit 92 # ad-hoc: the export signs it for real

cat > $OUT/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>AE6TTXW92K</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath $OUT/InkvoltPrint.xcarchive -exportPath $OUT/export \
  -exportOptionsPlist $OUT/ExportOptions.plist -allowProvisioningUpdates \
  -authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID || exit 93

PKG="$OUT/export/Inkvolt Print.pkg"
zsh ./pkg-preflight.sh "$PKG" $BUILD || exit 96
if [ "${2:-}" = "--upload" ]; then
  xcrun altool --validate-app -f "$PKG" --type macos --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID || exit 94
  xcrun altool --upload-app -f "$PKG" --type macos --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID || exit 95
fi
echo "RELEASE_DONE $PKG"
