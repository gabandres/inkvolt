# Releasing the Mac apps from a new Mac

ignia-mac (MacBook Air M1) was sold in November 2026. Everything the release scripts need that isn't in git was saved
first; this says where each piece goes on the next Mac, what to install, and how to prove the setup works without
publishing anything. No secret is in this file: secrets are named by file or key name only.

## The backup

`Z:\backups\ignia-mac\inkvolt-release-2026-11-12\inkvolt-release-2026-11-12.tgz` on the Windows PC (a local NTFS volume,
not synced), 21,175 bytes, SHA-256 `4cc341f17fa5b7616d7e0679fdf3b0cd4bd0e23ad8366390f56092fdd28bbac7`. Paths inside are
relative to the old home folder. The older `mac-backup.tgz` beside it (2026-10-27) predates the Developer ID and
Sparkle setup: don't restore secrets from it.

Copy it over (scp, or a USB stick; never a cloud folder), check the SHA-256 with `shasum -a 256`, then:

| In the tarball | Goes to | Mode | Used by |
|---|---|---|---|
| `Library/Keychains/inkvolt-devid.keychain-db` | `~/Library/Keychains/` | 600 | Developer ID Application identity (Bermudez Systems LLC, team AE6TTXW92K): `InkvoltPdf/release.sh` signs the notarized DMG. Unlocked with `DEVID_KEYCHAIN_PASSWORD` from `.env.local`. |
| `Library/Keychains/inkvolt-dev.keychain-db` | `~/Library/Keychains/` | 600 | Apple Development identity: both apps' `build.sh` (dev builds keep their Screen Recording and Local Network permissions). Unlocked with `DEV_KEYCHAIN_PASSWORD`. |
| `.inkvolt-sparkle/ed25519.key`, `ed25519.pub` | `~/.inkvolt-sparkle/` (folder 700) | 600 | Sparkle EdDSA key: `release.sh --appcast` signs each DMG for the update feed. The `.pub` equals `SUPublicEDKey` in `InkvoltPdf/Info.plist` (checked 2026-11-12). **Without the private key no installed copy of Inkvolt PDF for Mac can be updated.** |
| `Repos/inkvolt/mac/InkvoltPrint/.env.local` | `~/Repos/inkvolt/mac/InkvoltPrint/.env.local` | 600 | Keys `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` (App Store Connect API: Print's `release.sh`, `asc*.mjs`, PDF's notarytool), `DEV_KEYCHAIN_PASSWORD`, `DEVID_KEYCHAIN_PASSWORD`. Both apps' scripts read this one file (`INKVOLT_ENV` names another). |
| `.appstoreconnect/private_keys/AuthKey_*.p8` (two) | `~/.appstoreconnect/private_keys/` (folder 700) | 600 | The one `ASC_KEY_PATH` names is Inkvolt's (altool also looks for it here by name). The other was in the same folder and isn't named by `.env.local`; kept in case another app's scripts use it. |
| `Library/Developer/Xcode/UserData/Provisioning Profiles/48308f5b-….provisionprofile` | same path under `~` | 644 | Mac Team Store profile for `com.bermudezsystems.InkvoltPrint` (expires 2027-10-25). Optional: `release.sh` lets Xcode fetch profiles (`-allowProvisioningUpdates`). |

Then:

- `ASC_KEY_PATH` in `.env.local` is an absolute path under the old home folder. If the new user name differs, change that one line to the new path (or `~/.appstoreconnect/private_keys/<file>`; the scripts
  expand `~`). Edit it in an editor; don't print the file.
- Add both keychains to the search list (the old Mac had them there):
  `security list-keychains -d user -s login.keychain-db inkvolt-dev.keychain-db inkvolt-devid.keychain-db`
- notarytool has no stored keychain profile: `release.sh` passes the API key each time. Nothing to restore.

Not in the backup, set up fresh: `gh auth login` (GitHub releases, the appcast branch, the Homebrew tap and website
pushes), git's HTTPS credentials, Tailscale, SSH keys (new ones; the old Mac's were revoked at the erase). No Apple ID
is needed in Xcode: App Store builds sign with the team's cloud-managed certificates through the API key. The Inkvolt
Pro signing key lives only on the PC and never goes to a Mac.

**Expiry to watch:** the Apple Development certificate (made 2026-10-27) lasts a year: rerun `dev-cert.sh` after moving
the old keychain aside. The Developer ID certificate lasts five; only the Account Holder can make a new one
(`devid-cert.sh request` / `import`).

## Tools

The old Mac, last release (2026-11-12): macOS 27.2, Xcode 27.1 (Swift 6.4), Homebrew 7.0, gh 2.103, Node 24.12,
Python 3.14 (`appcast.py`, `assemble.sh`, `check-strings.sh`).

1. Xcode from the App Store (a release Xcode, not a beta: Print's preflight refuses one), opened once to accept the
   license; `sudo xcode-select -s <its path>` (the old Mac had `/Applications/Xcode-27.1.0.app`).
2. Homebrew, then `brew install gh node python`. `asc*.mjs` use only Node's own crypto: no `npm install`.
3. `git clone https://github.com/gabandres/inkvolt.git ~/Repos/inkvolt` (the release clone; the scripts fall back to its
   `.env.local` from a worktree).
4. MuPDF: `sh mac/Vendor/mupdf/build.sh` (1.25.2, cloned into `~/build-artifacts/mupdf`, the XCFramework into
   `mac/InkvoltPdfKit/Frameworks`, not in git). Then `swift test --package-path mac/InkvoltPdfKit` should pass.
5. Sparkle 2.10.1 comes through SwiftPM (`InkvoltPdf/Package.resolved`): `swift package resolve --package-path
   mac/InkvoltPdf` puts `sign_update` in `mac/InkvoltPdf/.build/artifacts/sparkle/Sparkle/bin/`.
6. From the PC: point `mac/tools/mac.sh` at the new Mac with `INKVOLT_MAC_HOST=<ssh host>` (default `ignia-mac`), and
   make `~/Repos/inkvolt-pc` a worktree of the release clone as before.

## Dry check: proves the setup, publishes nothing

Run on the Mac, from `~/Repos/inkvolt`. None of these uploads, submits or pushes.

1. **Keychains and identities.** `sh mac/InkvoltPdf/build.sh` unlocks `inkvolt-dev` and installs a dev build;
   `codesign -dv --verbose=2 "/Applications/Inkvolt PDF.app" 2>&1 | grep Authority` names "Apple Development", not
   ad hoc. `security find-identity -v -p codesigning ~/Library/Keychains/inkvolt-devid.keychain-db` (after
   `release.sh` has unlocked it, or unlock it yourself without echoing the password) lists "Developer ID Application:
   Bermudez Systems LLC (AE6TTXW92K)".
2. **Sign and notarize.** `INKVOLT_OUT=~/build-artifacts/dry nohup zsh mac/InkvoltPdf/release.sh 0.0.1 > ~/build-artifacts/dry.log 2>&1 &`
   (no `--appcast`, no `--publish`): Developer ID signing, notarization and stapling of the app and the DMG, and the
   Gatekeeper checks. `~/build-artifacts/dry/status` ends `DONE 0`. Notarizing sends the DMG to Apple; nothing is
   released. Delete `~/build-artifacts/dry` after.
3. **Sparkle.** `mac/InkvoltPdf/.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file ~/.inkvolt-sparkle/ed25519.key -p ~/build-artifacts/dry/Inkvolt-PDF-0.0.1.dmg`
   prints a signature; the same tool with `--verify <dmg> <signature>` and the key file says it's valid. And
   `plutil -extract SUPublicEDKey raw mac/InkvoltPdf/Info.plist` equals `~/.inkvolt-sparkle/ed25519.pub`.
4. **App Store Connect.** `node mac/InkvoltPrint/asc-builds.mjs` lists Inkvolt Print's builds (the API key works).
   `nohup zsh -l mac/InkvoltPrint/release.sh <next build> > ~/build-artifacts/inkvolt-print-mac.log 2>&1 &` **without
   `--upload`** archives, exports the signed .pkg and runs `pkg-preflight.sh`; a build number is only spent by an upload.

When all four pass, the Mac can release both apps: `mac/README.md` and the HANDOFF entries for the last releases have
the full steps.
