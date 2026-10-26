# Inkvolt for macOS

Native Swift versions of the Inkvolt apps, in progress. Inkvolt Print comes first (Mac App Store, MIT); Inkvolt PDF
follows (notarized download, AGPL because of MuPDF). Plan and status: [`docs/PLAN.md`](docs/PLAN.md).

| Folder | What |
|---|---|
| [`docs/`](docs) | The plan, and platform research with sources |
| [`Probe/`](Probe/README.md) | InkvoltProbe: a throwaway sandboxed app that checks what the App Store sandbox allows (CUPS, SNMP broadcast, Bonjour, ImageCaptureCore, Local Network privacy) |
| `InkvoltPrintKit/` | Swift package. **PrintCore**: Inkvolt Print's protocols and rules, ported from `shared/InkvoltPrint.Core` with its tests; Foundation only. **PrintMac**: the adapters to Apple's frameworks (URLSession, UDP SNMP, Bonjour, Local Network access); Mac only |
| `InkvoltPrint/` | The app (SwiftUI; `InkvoltPrint.xcodeproj` over the package): printer list, printer pane, menu bar item, demo mode. `build.sh` installs a development build; `release.sh` makes and uploads App Store builds |
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
analytics SDK), then validates and uploads with `altool`. The icon comes from `assets/make-icon.py` (the Windows
artwork on a macOS tile).

The `mac` CI job (`.github/workflows/mac.yml`) builds the probe and the Xcode project and tests the package on macOS 15,
warnings as errors.
