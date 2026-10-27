#!/bin/sh
# Builds Inkvolt PDF (release, warnings as errors) and makes an unsigned "Inkvolt PDF.app" at the path given: the binary,
# Info.plist, PkgInfo and the icons (assets/*.iconset turned into .icns with iconutil). build.sh and release.sh sign it.
#   sh mac/InkvoltPdf/assemble.sh <path/Inkvolt PDF.app>
set -eu
cd "$(dirname "$0")"
app="${1:?usage: assemble.sh <path/Inkvolt PDF.app>}"

swift build -c release -Xswiftc -warnings-as-errors \
    -Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=150
bin="$(swift build -c release --show-bin-path)/InkvoltPdf"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Inkvolt PDF"
cp Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
iconutil -c icns assets/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"         # CFBundleIconFile
iconutil -c icns assets/PdfDocument.iconset -o "$app/Contents/Resources/PdfDocument.icns" # CFBundleTypeIconFile
