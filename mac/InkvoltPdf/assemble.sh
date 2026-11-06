#!/bin/sh
# Builds Inkvolt PDF (release, warnings as errors) and makes an unsigned "Inkvolt PDF.app" at the path given: the binary,
# Info.plist, PkgInfo, the icons (assets/*.iconset turned into .icns with iconutil), Sparkle.framework in
# Contents/Frameworks (found through the rpath @executable_path/../Frameworks), without its XPC services: those are for
# sandboxed apps only; and in Resources what Help and About show: WHATS-NEW.md (and its Spanish, WHATS-NEW.es.md),
# THIRD-PARTY-NOTICES.md, Sparkle's license text as it ships (Sparkle-LICENSE.txt, from the package checkout) and the AGPL
# (LICENSE.txt, pdf/LICENSE); the interface's English and Spanish (es.lproj, from the String Catalogs in Resources/).
# build.sh and release.sh sign it with sign.sh.
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
cp WHATS-NEW.md WHATS-NEW.es.md THIRD-PARTY-NOTICES.md "$app/Contents/Resources/"
# The interface in English and Spanish (AppLanguage): the String Catalogs compiled into en.lproj and es.lproj (the app's
# own text, PdfCore's, Inkvolt Print's CoreStrings for what PrintCore shows, Info.plist's), and every key of the three
# sentence catalogs for the self-test's --strings check (catalog-keys.py).
for catalog in Resources/Localizable.xcstrings Resources/PdfStrings.xcstrings Resources/InfoPlist.xcstrings     ../InkvoltPrint/Resources/CoreStrings.xcstrings; do
    xcrun xcstringstool compile "$catalog" --output-directory "$app/Contents/Resources"
done
/usr/bin/python3 ../InkvoltPrint/catalog-keys.py Resources "$app/Contents/Resources/CatalogKeys.json"     Resources/Localizable.xcstrings Resources/PdfStrings.xcstrings ../InkvoltPrint/Resources/CoreStrings.xcstrings
cp .build/checkouts/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE.txt"
cp ../../pdf/LICENSE "$app/Contents/Resources/LICENSE.txt"
