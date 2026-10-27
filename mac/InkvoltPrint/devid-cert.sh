#!/bin/sh
# Gives the Mac a Developer ID Application identity, for apps distributed outside the App Store (Inkvolt PDF's notarized
# DMG). Apple lets only the team's Account Holder create one (the App Store Connect API refuses: 403), so it takes two
# steps on the Mac:
#   sh mac/InkvoltPrint/devid-cert.sh request
#       makes the private key (kept in ~/.inkvolt-devid, mode 700, never leaving the Mac) and a certificate signing
#       request, copied to ~/Desktop/Inkvolt Developer ID.certSigningRequest. The Account Holder uploads it at
#       developer.apple.com › Certificates › + › Developer ID Application (G2 Sub-CA) and downloads the certificate.
#   sh mac/InkvoltPrint/devid-cert.sh import ~/Downloads/developerID_application.cer
#       puts key and certificate in a keychain of their own, ~/Library/Keychains/inkvolt-devid.keychain-db (its random
#       password in .env.local as DEVID_KEYCHAIN_PASSWORD, not in git), with Apple's Developer ID intermediate, and
#       deletes the loose key. Kept apart from the development identity: this one signs software as the team for
#       anyone's Mac.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
keychain="$HOME/Library/Keychains/inkvolt-devid.keychain-db"
env="$here/.env.local"
dir="$HOME/.inkvolt-devid"

case "${1:-}" in
request)
    [ -f "$keychain" ] && { echo "$keychain already exists"; exit 1; }
    mkdir -p "$dir"
    chmod 700 "$dir"
    [ -f "$dir/key.pem" ] || openssl genrsa -out "$dir/key.pem" 2048 2>/dev/null
    chmod 600 "$dir/key.pem"
    openssl req -new -key "$dir/key.pem" -out "$dir/request.csr" -subj "/CN=Inkvolt Developer ID/O=Bermudez Systems LLC"
    cp "$dir/request.csr" "$HOME/Desktop/Inkvolt Developer ID.certSigningRequest"
    echo "Upload ~/Desktop/Inkvolt Developer ID.certSigningRequest as a Developer ID Application (G2 Sub-CA) certificate,"
    echo "then: sh mac/InkvoltPrint/devid-cert.sh import <the downloaded .cer>"
    ;;
import)
    cer="${2:?usage: devid-cert.sh import <certificate.cer>}"
    [ -f "$dir/key.pem" ] || { echo "No key: run devid-cert.sh request first"; exit 1; }
    [ -f "$keychain" ] && { echo "$keychain already exists"; exit 1; }
    grep -q '^DEVID_KEYCHAIN_PASSWORD=' "$env" && { echo "DEVID_KEYCHAIN_PASSWORD is already in .env.local"; exit 1; }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    openssl x509 -inform DER -in "$cer" -out "$work/devid.pem" 2>/dev/null || cp "$cer" "$work/devid.pem"
    # The certificate must be the one for this key.
    [ "$(openssl x509 -noout -modulus -in "$work/devid.pem")" = "$(openssl rsa -noout -modulus -in "$dir/key.pem")" ] \
        || { echo "That certificate isn't for this Mac's key."; exit 1; }
    password="$(openssl rand -hex 24)"
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings "$keychain" # no lock timeout
    security unlock-keychain -p "$password" "$keychain"
    # Key and certificate imported each on its own (a PKCS#12 of them can fail macOS's MAC check); the keychain pairs them.
    # security reads the traditional RSA form, not the PKCS#8 one genrsa writes.
    openssl rsa -in "$dir/key.pem" -out "$work/key-rsa.pem" -traditional 2>/dev/null || openssl rsa -in "$dir/key.pem" -out "$work/key-rsa.pem" 2>/dev/null
    security import "$work/key-rsa.pem" -k "$keychain" -t priv -f openssl -T /usr/bin/codesign -T /usr/bin/productsign
    security import "$work/devid.pem" -k "$keychain"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
    # The intermediate that issues Developer ID certificates, from Apple, so the identity validates.
    curl -fsS https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "$work/devid-ca.cer"
    security import "$work/devid-ca.cer" -k "$keychain" >/dev/null 2>&1 || true
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$keychain"
    printf '\nDEVID_KEYCHAIN_PASSWORD=%s\n' "$password" >> "$env"
    rm -P "$dir/key.pem" "$dir/request.csr" 2>/dev/null || rm -f "$dir/key.pem" "$dir/request.csr"
    rm -f "$HOME/Desktop/Inkvolt Developer ID.certSigningRequest"
    security find-identity -v -p codesigning "$keychain"
    ;;
*)
    echo "usage: devid-cert.sh request | import <certificate.cer>"
    exit 2
    ;;
esac
