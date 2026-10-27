#!/bin/sh
# Gives the Mac an Apple Development identity for development builds, so macOS keeps their Screen Recording and Local
# Network permissions from one build to the next (an ad-hoc build is a new app to it each time). Run once on the Mac:
#   sh mac/InkvoltPrint/dev-cert.sh
# Makes a key and a signing request, has App Store Connect create the certificate (asc-dev-cert.mjs, the API key in
# .env.local), and keeps both in a keychain of their own, ~/Library/Keychains/inkvolt-dev.keychain-db, whose random
# password goes into .env.local as DEV_KEYCHAIN_PASSWORD (not in git): build.sh unlocks it and signs with it, also over
# SSH, where the login keychain can't be used. Refuses to run when the keychain already exists.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
keychain="$HOME/Library/Keychains/inkvolt-dev.keychain-db"
env="$here/.env.local"
[ -f "$keychain" ] && { echo "$keychain already exists"; exit 1; }
grep -q '^DEV_KEYCHAIN_PASSWORD=' "$env" && { echo "DEV_KEYCHAIN_PASSWORD is already in .env.local"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
openssl genrsa -out "$work/key.pem" 2048 2>/dev/null
openssl req -new -key "$work/key.pem" -out "$work/request.csr" -subj "/CN=Inkvolt development ($(scutil --get ComputerName))"
node "$here/asc-dev-cert.mjs" "$work/request.csr" "$work/dev.cer"

password="$(openssl rand -hex 24)"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain" # no lock timeout
security unlock-keychain -p "$password" "$keychain"
# The key travels into the keychain as a PKCS#12 with a throwaway password, beside its certificate.
openssl x509 -inform DER -in "$work/dev.cer" -out "$work/dev.pem"
p12="$(openssl rand -hex 12)"
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/dev.pem" -out "$work/dev.p12" -passout "pass:$p12"
security import "$work/dev.p12" -k "$keychain" -P "$p12" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
# The intermediate that issues development certificates, from Apple, so the identity validates.
curl -fsS https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$work/wwdr.cer"
security import "$work/wwdr.cer" -k "$keychain" >/dev/null 2>&1 || true
# Searched beside the login keychain, so codesign finds it.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$keychain"
printf '\nDEV_KEYCHAIN_PASSWORD=%s\n' "$password" >> "$env"
security find-identity -v -p codesigning "$keychain"
