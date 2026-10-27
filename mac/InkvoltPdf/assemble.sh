#!/bin/sh
# Builds Inkvolt PDF (release, warnings as errors) and makes an unsigned "Inkvolt PDF.app" at the path given: the binary,
# Info.plist, PkgInfo, the icons (assets/*.iconset turned into .icns with iconutil) and Sparkle.framework in
# Contents/Frameworks (found through the rpath @executable_path/../Frameworks), without its XPC services: those are for
# sandboxed apps only. build.sh and release.sh sign it with sign.sh.
#   sh mac/InkvoltPdf/assemble.sh <path/Inkvolt PDF.app>
set -eu
cd "$(dirname "$0")"
app="${1:?usage: assemble.sh <path/Inkvolt PDF.app>}"

swift build -c release -Xswiftc -warnings-as-errors \
    -Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=150
bins="$(swift build -c release --show-bin-path)"
bin="$bins/InkvoltPdf"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Inkvolt PDF"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Inkvolt PDF"
mkdir -p "$app/Contents/Frameworks"
ditto "$bins/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
cp Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
iconutil -c icns assets/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"         # CFBundleIconFile
iconutil -c icns assets/PdfDocument.iconset -o "$app/Contents/Resources/PdfDocument.icns" # CFBundleTypeIconFile
