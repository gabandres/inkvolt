#!/bin/sh
# Signs "Inkvolt PDF.app" from the inside out, as Sparkle's documentation says for apps signed outside Xcode (never
# --deep): Sparkle's Autoupdate and Updater.app, then Sparkle.framework, then the app; hardened runtime on each. Not
# sandboxed: the app's one entitlement (InkvoltPdf.entitlements) is the app group it shares with Inkvolt Print, where the
# Inkvolt Pro key is kept (mac/docs/research/print-v1-platform.md, "The Pro key's shared file"); Sparkle's code has none.
# The codesign options after the app (identity, keychain, timestamp) apply to every one.
#   sh mac/InkvoltPdf/sign.sh <path/Inkvolt PDF.app> --sign <identity> [--keychain k] [--timestamp | --timestamp=none]
set -eu
app="${1:?usage: sign.sh <path/Inkvolt PDF.app> <codesign options>}"
shift
entitlements="$(cd "$(dirname "$0")" && pwd)/InkvoltPdf.entitlements"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for code in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --options runtime "$@" "$code"
done
codesign --force --options runtime --entitlements "$entitlements" "$@" "$app"
codesign --verify --strict --deep "$app"
