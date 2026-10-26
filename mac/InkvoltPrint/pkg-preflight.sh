#!/bin/zsh
# The checks every Mac App Store package of Inkvolt Print passes before upload (release.sh runs it; exit 1 on any failure):
#   pkg-preflight.sh <pkg> <build number>
# - the installer and the app are signed for the App Store, and the app carries its provisioning profile;
# - the sandbox is on, get-task-allow is off, and the entitlements are only those v1 uses (the sandbox, network client and
#   server; print, USB and user-selected files come back with the features that need them: App Review refuses unused ones);
# - Info.plist has the bundle ID, the build number, the category, the Local Network text, Bonjour types and the icon;
# - the icon, the privacy manifest and demo mode's fixtures are in the bundle (App Review has no printer);
# - it was built by the release Xcode at DEVELOPER_DIR (a beta's builds reach TestFlight but never review);
# - no crash reporter or analytics SDK is linked (the app collects no data: privacy label "Data Not Collected").
set -u
PKG=${1:?usage: pkg-preflight.sh <pkg> <build number>}
BUILD=${2:?usage: pkg-preflight.sh <pkg> <build number>}
fail=0
bad() { echo "PREFLIGHT FAIL: $*"; fail=1; }

work=$(mktemp -d)
trap 'rm -rf $work' EXIT
pkgutil --expand-full "$PKG" $work/x >/dev/null || { echo "PREFLIGHT FAIL: can't expand $PKG"; exit 1; }
APP=$(find $work/x -maxdepth 3 -name "*.app" -type d | head -1)
[ -n "$APP" ] || { echo "PREFLIGHT FAIL: no app in $PKG"; exit 1; }
plist="$APP/Contents/Info.plist"
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null; }

pkgutil --check-signature "$PKG" | grep -qE "3rd Party Mac Developer Installer|Mac Installer Distribution" || bad "installer not signed for the App Store"
codesign -dvv "$APP" 2>&1 | grep -qE "Authority=(Apple Distribution|3rd Party Mac Developer Application)" || bad "app not signed for the App Store"
codesign --verify --strict --deep "$APP" 2>/dev/null || bad "app signature doesn't verify"
[ -f "$APP/Contents/embedded.provisionprofile" ] || bad "no embedded.provisionprofile"

ents=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
echo "$ents" | grep -q "com.apple.security.app-sandbox" || bad "sandbox entitlement missing"
echo "$ents" | grep -q "get-task-allow" && bad "get-task-allow is on (a development build)"
for e in network.client network.server; do
  echo "$ents" | grep -q "com.apple.security.$e" || bad "entitlement com.apple.security.$e missing"
done
extra=$(echo "$ents" | grep -oE "com\.apple\.security\.[a-z.-]+" | grep -vE "app-sandbox|network\.client|network\.server|application-groups" | sort -u)
[ -z "$extra" ] || bad "entitlements beyond the App Store set: $extra"

[ "$(value CFBundleIdentifier)" = "com.bermudezsystems.InkvoltPrint" ] || bad "bundle ID is $(value CFBundleIdentifier)"
[ "$(value CFBundleVersion)" = "$BUILD" ] || bad "build number is $(value CFBundleVersion), not $BUILD"
[ "$(value LSApplicationCategoryType)" = "public.app-category.utilities" ] || bad "category missing"
[ -n "$(value NSLocalNetworkUsageDescription)" ] || bad "NSLocalNetworkUsageDescription missing"
[ "$(value NSBonjourServices | grep -c _tcp)" -eq 6 ] || bad "NSBonjourServices doesn't list the six types"
[ "$(value NSAppTransportSecurity:NSAllowsLocalNetworking)" = "true" ] || bad "NSAllowsLocalNetworking missing"
[ "$(value CFBundleIconName)" = "AppIcon" ] || bad "CFBundleIconName missing"
[ -f "$APP/Contents/Resources/Assets.car" ] || bad "no compiled asset catalog (icon)"
[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ] || bad "no privacy manifest"
for set in m234dw inkjet-demo cdm-laser snmp-demo; do
  [ -d "$APP/Contents/Resources/Demo/$set" ] || bad "demo fixtures $set missing"
done

want=$(xcodebuild -version | awk '/Build version/ { print $3 }')
[ "$(value DTXcodeBuild)" = "$want" ] || bad "built by Xcode $(value DTXcodeBuild), not the release Xcode ($want)"

exe="$APP/Contents/MacOS/$(value CFBundleExecutable)"
if strings "$exe" | grep -qiE "sentry|crashlytics|firebase|bugsnag|appcenter"; then bad "a crash or analytics SDK is linked"; fi
[ -d "$APP/Contents/Frameworks" ] && bad "unexpected Frameworks folder: $(ls "$APP/Contents/Frameworks" | tr '\n' ' ')"

[ $fail -eq 0 ] && echo "PREFLIGHT OK: $(value CFBundleShortVersionString) ($BUILD)"
exit $fail
