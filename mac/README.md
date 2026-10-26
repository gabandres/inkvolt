# Inkvolt for macOS

Native Swift versions of the Inkvolt apps, in progress. Inkvolt Print comes first (Mac App Store, MIT); Inkvolt PDF
follows (notarized download, AGPL because of MuPDF). Plan and status: [`docs/PLAN.md`](docs/PLAN.md).

| Folder | What |
|---|---|
| [`docs/`](docs) | The plan, and platform research with sources |
| [`Probe/`](Probe/README.md) | InkvoltProbe: a throwaway sandboxed app that checks what the App Store sandbox allows (CUPS, SNMP broadcast, Bonjour, ImageCaptureCore, Local Network privacy) |
| `InkvoltPrintKit/` | Swift package. **PrintCore**: Inkvolt Print's protocols and rules, ported from `shared/InkvoltPrint.Core` with its tests; Foundation only. **PrintMac**: the adapters to Apple's frameworks (URLSession, UDP SNMP, Bonjour, Local Network access); Mac only |
| `InkvoltPrint/` | The app (SwiftUI): printer list, printer pane, menu bar item, demo mode. `build.sh` makes and installs `Inkvolt Print.app` |
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

The app builds on a Mac only, into a sandboxed `.app` signed with the first Apple Development identity (`SIGN_IDENTITY=-`
for ad-hoc) and installed in /Applications:

```sh
sh mac/InkvoltPrint/build.sh
open "/Applications/Inkvolt Print.app" --args --demo                        # the made-up printers
open "/Applications/Inkvolt Print.app" --args --report real --wait 25 --stay # writes what it shows to its container
```

The report lands in `~/Library/Containers/com.bermudezsystems.InkvoltPrint/Data/Library/Application Support/InkvoltPrint/`.

The `mac` CI job (`.github/workflows/mac.yml`) builds the probe and the app and tests the package on macOS 15, warnings as
errors.
