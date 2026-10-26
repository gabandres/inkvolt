# Inkvolt for macOS

Native Swift versions of the Inkvolt apps, in progress. Inkvolt Print comes first (Mac App Store, MIT); Inkvolt PDF
follows (notarized download, AGPL because of MuPDF). Plan and status: [`docs/PLAN.md`](docs/PLAN.md).

| Folder | What |
|---|---|
| [`docs/`](docs) | The plan, and platform research with sources |
| [`Probe/`](Probe/README.md) | InkvoltProbe: a throwaway sandboxed app that checks what the App Store sandbox allows (CUPS, SNMP broadcast, Bonjour, ImageCaptureCore, Local Network privacy) |
| `InkvoltPrintKit/` | Swift package. **PrintCore**: Inkvolt Print's protocols and rules, ported from `shared/InkvoltPrint.Core` with its tests (so far the model and SNMP); Foundation only |
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

The `mac` CI job (`.github/workflows/mac.yml`) builds the probe and tests the package on macOS 15, warnings as errors.
