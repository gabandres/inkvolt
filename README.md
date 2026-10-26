# Inkvolt

Two Windows apps by [Bermudez Systems](https://bermudezsystems.com), in one repository. Each is its own app with its own
Microsoft Store listing; they share code and install together.

| Folder | What | License |
|---|---|---|
| [`pdf/`](pdf/README.md) | **Inkvolt PDF**: a fast PDF viewer, editor and page organizer (.NET 10 WPF + MuPDF) | AGPL-3.0 (MuPDF requires it) |
| [`print/`](print/README.md) | **Inkvolt Print**: a lean, private app for your printers and scanners (status, ink or toner, scan, copy, print) | MIT |
| `shared/` | `InkvoltPrint.Core` (protocols: eSCL, IPP, LEDM, CDM, SNMP, scan options, remembered printers) and `InkvoltPrint.Windows` (discovery, Windows queues, WIA): used by both apps; tested by `print/tests` | MIT |
| `packaging/` | `pack-msix.ps1`: MSIX packages and Store upload files for either app (`-App Pdf` or `-App Print`) | MIT |
| [`mac/`](mac/README.md) | **Inkvolt for macOS**, in planning: native Swift, Inkvolt Print first (Mac App Store), then Inkvolt PDF | MIT (Inkvolt PDF's Mac app will be AGPL) |

The license of each folder is in its `LICENSE`; the top-level scripts are MIT (see [LICENSE](LICENSE)). Inkvolt PDF's
AGPL applies to Inkvolt PDF as distributed (the MIT libraries in it stay MIT on their own); Inkvolt Print ships no AGPL
code.

## Build

```powershell
git clone https://github.com/gabandres/inkvolt.git
cd inkvolt
dotnet build Inkvolt.slnx    # both apps, the shared libraries and the tests
dotnet test Inkvolt.slnx
```

Needs the .NET 10 SDK on Windows 10 (19041) or later, x64 or ARM64. Each app also builds on its own from its folder
(`pdf/InkvoltPdf.slnx`, `print/InkvoltPrint.slnx`). Settings shared by every project are in `Directory.Build.props`;
`pdf/Directory.Build.props` adds Inkvolt PDF's own (embedded PDBs, ARM64 by default).

## Install both

```powershell
pwsh -File install-suite.ps1             # publishes both, installs to %LOCALAPPDATA%\Programs\Inkvolt\InkvoltPdf and \InkvoltPrint
pwsh -File install-suite.ps1 -NoBuild    # install the existing publish outputs (pdf/publish, print/publish)
pwsh -File install-suite.ps1 -Uninstall  # removes only what it added, and puts back registry values it replaced
```

It adds a Start Menu folder "Inkvolt" with both apps ("Inkvolt PDF", "Inkvolt Print"), App Paths entries (`InkvoltPdf.exe`,
`InkvoltPrint.exe`: how each app finds the other) and Inkvolt PDF's "Open with" entries. Registry keys are only created
when missing (never re-created, which would wipe their values); each value set is recorded, with the value it replaced,
in `Inkvolt\inkvolt-suite.json` for `-Uninstall`. `pdf/install.ps1` still installs Inkvolt PDF on its own.

Both apps keep their settings in `%LOCALAPPDATA%\InkvoltPdf` and `\InkvoltPrint`. On first start each moves its folder
over from the name it had before the rename, once; Inkvolt Print also moves its saved printer passwords in Credential
Manager. The installers don't remove an install made under the old names: uninstall that with the old scripts first.

## Microsoft Store

```powershell
pwsh -File packaging/pack-msix.ps1 -App Pdf      # → pdf/publish/msix
pwsh -File packaging/pack-msix.ps1 -App Print    # → print/publish/msix
```

Partner Center values, Store policy notes and listing drafts: [`pdf/packaging/README.md`](pdf/packaging/README.md),
[`print/packaging/README.md`](print/packaging/README.md).

## History

Inkvolt PDF (formerly PdfDesk, `github.com/gabandres/inkvolt-pdf`) and Inkvolt Print (formerly PrintDesk,
`github.com/gabandres/inkvolt-print`) were separate repositories until October 2026; both histories are kept here
(`git log -- pdf/…`, `git log -- print/…`; `--follow` for files that moved to `shared/`).
