#!/bin/sh
# Signs "Inkvolt PDF.app" from the inside out, as Sparkle's documentation says for apps signed outside Xcode (never
# --deep): Sparkle's Autoupdate and Updater.app, then Sparkle.framework, then the app; hardened runtime on each, no
# entitlements (not sandboxed). The codesign options after the app (identity, keychain, timestamp) apply to every one.
#   sh mac/InkvoltPdf/sign.sh <path/Inkvolt PDF.app> --sign <identity> [--keychain k] [--timestamp | --timestamp=none]
set -eu
app="${1:?usage: sign.sh <path/Inkvolt PDF.app> <codesign options>}"
shift
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for code in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" "$app"; do
    codesign --force --options runtime "$@" "$code"
done
codesign --verify --strict --deep "$app"
