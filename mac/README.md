# Inkvolt for macOS

Native Swift versions of the Inkvolt apps, in progress. Inkvolt Print comes first (Mac App Store, MIT); Inkvolt PDF
follows (notarized download, AGPL because of MuPDF). Plan and status: [`docs/PLAN.md`](docs/PLAN.md).

| Folder | What |
|---|---|
| [`docs/`](docs) | The plan, and platform research with sources |
| [`Probe/`](Probe/README.md) | InkvoltProbe: a throwaway sandboxed app that checks what the App Store sandbox allows (CUPS, SNMP broadcast, Bonjour, ImageCaptureCore, Local Network privacy) |
| `InkvoltPrintKit/` | Swift package. **PrintCore**: Inkvolt Print's protocols and rules, ported from `shared/InkvoltPrint.Core` with its tests; Foundation only. **PrintMac**: the adapters to Apple's frameworks (URLSession, UDP SNMP, Bonjour, the subnet search's sockets, Local Network access, libcups, ImageCaptureCore, Core Graphics and PDFKit for scans and photo sheets, Vision for searchable PDFs, the Keychain); Mac only |
| `InkvoltPrint/` | The app (SwiftUI; `InkvoltPrint.xcodeproj` over the package): the printer list (network printers, macOS's print queues, USB scanners), the printer pane (status, supplies, print queue, maintenance, the offline fixer; Scan with presets; device Settings), Add a printer, Print a PDF, Print Photos, Settings (menu bar item, open at login, alerts), the menu bar item, demo mode. `build.sh` installs a development build; `release.sh` makes and uploads App Store builds |
| `InkvoltPdfKit/` | Swift package for Inkvolt PDF (in progress, `docs/PLAN.md` D-steps). **MuPDFShim**: C over MuPDF that catches its errors; **PdfCore**: the Windows Core's rules over MuPDF, with its tests. Needs `Frameworks/MuPDF.xcframework` from `Vendor/mupdf/build.sh`; Mac only |
| `Vendor/mupdf/` | `build.sh`: MuPDF (the Windows app's version, 1.25.2) from its source as a static XCFramework for the package. Run once on the Mac (several minutes); the source stays in `~/build-artifacts/mupdf` |
| `tools/` | `swift-dev.ps1`: runs Swift on the Windows PC with Visual Studio's build tools |

Builds need macOS 15 or later with Xcode 16 or later:

```sh
swift test --package-path mac/InkvoltPrintKit
```

PrintCore also builds and tests on Windows (Swift 6.4 from winget `Swift.Toolchain`, plus Visual Studio's C++ ARM64 tools
and Windows SDK):

```powershell
pwsh -File mac/tools/swift-dev.ps1 test --package-path mac/InkvoltPrintKit --build-system native
```

The app builds on a Mac only (Xcode 26 or later), into a sandboxed `.app` signed ad-hoc (or `SIGN_IDENTITY` names an
identity) and installed in /Applications:

```sh
sh mac/InkvoltPrint/build.sh
open "/Applications/Inkvolt Print.app" --args --demo                        # the made-up printers
open "/Applications/Inkvolt Print.app" --args --report real --wait 25 --stay # writes what it shows to its container
open "/Applications/Inkvolt Print.app" --args --report found --wait 25 --search # and what Add a printer's search found
open "/Applications/Inkvolt Print.app" --args --report dev --wait 3 --device      # the selected printer's settings (read only)
open "/Applications/Inkvolt Print.app" --args --report icc --wait 3 --icc         # ImageCaptureCore's scanners (no scan)
open "/Applications/Inkvolt Print.app" --args --report scan --wait 2 --demo --scan     # a demo scan, PDF and preset saved
open "/Applications/Inkvolt Print.app" --args --report fix --wait 3 --demo --fix all   # the offline fixer on the demo office laser
open "/Applications/Inkvolt Print.app" --args --report b --wait 2 --demo --batch      # a feeder batch split at its Patch T sheet
open "/Applications/Inkvolt Print.app" --args --report ph --wait 2 --demo --photos    # three photos on the glass, each its own JPEG
open "/Applications/Inkvolt Print.app" --args --report id --wait 2 --demo --idcard    # an ID card copy laid out (not printed)
open "/Applications/Inkvolt Print.app" --args --report st --wait 2 --demo --setup     # Set Up in macOS on a demo printer
open "/Applications/Inkvolt Print.app" --args --report pp --wait 2 --papers           # each queue's paper sizes, types, qualities, colors
open "/Applications/Inkvolt Print.app" --args --report pj --wait 2 --photo-job        # Print Photos' job sent held, read back, cancelled
open "/Applications/Inkvolt Print.app" --args --report sp --wait 2 --setup-probe      # makes a test CUPS queue, then deletes it
open "/Applications/Inkvolt Print.app" --args --report hw --wait 2 --hardware         # the selected real printer: glass, ID card, feeder, Set Up
```

The report lands in `~/Library/Containers/com.bermudezsystems.InkvoltPrint/Data/Library/Application Support/InkvoltPrint/`.

App Store builds (team AE6TTXW92K, the Inkvolt mobile team) are signed by Xcode with the team's cloud-managed certificates,
authenticated by the App Store Connect API key in `mac/InkvoltPrint/.env.local` (not in git), so the Mac needs no
certificate in its keychain. Run on the Mac, detached; each upload needs a new build number:

```sh
nohup mac/InkvoltPrint/release.sh 2 --upload > ~/build-artifacts/inkvolt-print-mac.log 2>&1 &
cat ~/build-artifacts/inkvolt-print-mac/status          # RUNNING, then DONE 0 or FAILED <step>
node mac/InkvoltPrint/asc-builds.mjs 2 --wait            # until App Store Connect says the build is VALID
```

`release.sh` archives, exports a signed `.pkg`, runs `pkg-preflight.sh` (App Store signatures, the sandbox and exactly
the App Store entitlements, Info.plist keys, icon, privacy manifest, demo fixtures, the release Xcode, no crash or
analytics SDK), then validates and uploads with `altool`. The icon and the menu bar glyph come from
`assets/make-icon.py` (the Windows artwork on a macOS tile).

The listing is `assets/store/listing.json` (texts, URLs, categories, review notes) and the screenshots beside it.
`node mac/InkvoltPrint/asc-listing.mjs apply <build>` sets all of it (and the age rating, the free price, every
territory, the review contact, the build) on the version being prepared; `asc-listing.mjs submit` sends it to App
Review. App Privacy ("Data Not Collected") can only be published on the App Store Connect website. Screenshots: a Debug
build's `--snapshot name:index[:scan|photos|print-photos]` (ScreenCaptureKit, needs Screen Recording permission, given once
in System Settings) in demo mode, then `assets/make-screenshots.py <captures folder>` (its docstring has the commands).

`build.sh` signs with the Apple Development identity that `dev-cert.sh` put in its own keychain (once per Mac: the App
Store Connect API key creates the certificate; the keychain's password goes into `.env.local`), so macOS keeps the app's
Screen Recording and Local Network permissions between builds; without it, builds are ad-hoc signed and asked again.

The `mac` CI job (`.github/workflows/mac.yml`) builds the probe and the Xcode project and tests the package on macOS 15,
warnings as errors.
