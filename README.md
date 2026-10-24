# Inkvolt Print

Inkvolt Print (formerly PrintDesk) is a lean Windows app for HP network printers, replacing HP Smart. No HP account, no cloud, no telemetry,
no background services, no driver download.

| Feature | How |
|---|---|
| Find printers | Windows' own mDNS/WSD discovery (`DeviceWatcher`): DNS-SD `_ipp`/`_ipps`/`_uscan`/`_uscans` services joined to Windows association endpoints by printer UUID. Remembered printers connect at startup without waiting for discovery. Manual add by IP or host name. |
| Set up in Windows | One click: pairs the printer's IPP association endpoint, exactly like Settings → *Add device*. Windows creates an IPP Class Driver queue (and a WIA scanner from the eSCL endpoint). No admin prompt. |
| Status, toner, usage | HP LEDM (`/DevMgmt/*.xml`, URIs from `DiscoveryTree.xml`), IPP `Get-Printer-Attributes` as fallback for non-LEDM printers. |
| Live updates | LEDM event table long poll: `GET /EventMgmt/EventTable.xml?timeout=600` + `If-None-Match` (device holds the request up to 60 s). An idle printer costs one request a minute; HP Smart polls. |
| Scan | eSCL direct: JPEG pages, multi-page from the glass or feeder, fixes HP's zero-height ADF JPEGs (DNL). Saves JPEG or PDF; PDF gets an invisible OCR text layer from inbox `Windows.Media.Ocr`. |
| Print a PDF | Windows' built-in PDF engine renders pages (300 dpi, auto-rotate, fit); spooled to the printer's Windows queue with copies, page ranges, two-sided. Password-protected PDFs prompt. Drag-and-drop, "Open with", or a second launch hands the file to the running window. |
| Print queue | Overview card: this printer's Windows queue jobs (System.Printing `GetPrintJobInfoCollection`: name, pages, status, time, owner), re-read every 3 s only while the card is on screen. Cancel your own jobs, or all of them (confirmed); others' jobs need an administrator and say so. No elevation. |
| HP clean-up | Detects HP Smart, HP's Print Support App and the services/virtual queue it leaves behind; removes them (one UAC prompt), blocks Windows from re-installing it, and re-creates affected queues (a queue created while HP's app was attached cancels every job once the app is gone). Not in the Microsoft Store package (see packaging/README.md). |
| Device settings | LEDM `*Dyn` + `*Cap`: only writable settings, only allowed values. Saves a minimal partial document over HTTPS; asks for the EWS admin password on 401 and can keep it in Windows Credential Manager. |

## Inkvolt suite (with Inkvolt PDF)

Inkvolt Print and Inkvolt PDF (the PDF viewer/organizer, in its own repo) are separate apps that share code and install together.
Inkvolt Print stays lean (software rendering, no PDF engine); Inkvolt PDF references `InkvoltPrint.Core` and `InkvoltPrint.Windows`
by project reference for scanning (File › Scan…, Insert from Scanner…) and printer status before printing.

- **Open in Inkvolt PDF**: after a scan is saved as PDF, the status line offers "Open in Inkvolt PDF"; the Scan settings have
  "Open scans in Inkvolt PDF" (open every saved PDF there automatically). Both show only when Inkvolt PDF is installed.
  A running Inkvolt PDF receives the file through its own single-instance pipe.
- Inkvolt PDF's File › "Printer Settings (Inkvolt Print)" opens Inkvolt Print when it is installed.
- Each app finds the other via its MSIX app execution alias (`%LOCALAPPDATA%\Microsoft\WindowsApps\inkvoltpdf.exe` /
  `inkvoltprint.exe`), App Paths (`HKCU\…\App Paths\InkvoltPdf.exe` / `InkvoltPrint.exe`), else the default install folders
  (`%LOCALAPPDATA%\Programs\Inkvolt\<app>`, `%LOCALAPPDATA%\Programs\<app>`): `InkvoltPrint.Windows/Suite/InkvoltApps.cs`,
  paths in `InkvoltPrint.Core/Suite/InkvoltPaths.cs`. A packaged Inkvolt Print's `state.json` lives in its package folder;
  `InkvoltPrinters.Load` reads whichever copy was written last.
- Shared, UI-free pieces in `InkvoltPrint.Core/Suite`: `InkvoltPrinters` (read-only view of `state.json`'s remembered
  printers and queue associations), `QueueMatch` (Windows queue → printer: stored association, device container, address
  in the port, unambiguous name), `PrinterHealth` (ready/sleeping/error/offline, toner, paper problems), `ScanChoices`
  (sources, colors, resolutions, page sizes → `ScanRequest`; Inkvolt Print's Scan tab uses its page sizes).
- One installer for both: `install-suite.ps1` in the Inkvolt PDF repo (`%LOCALAPPDATA%\Programs\Inkvolt\InkvoltPdf` and
  `\InkvoltPrint`, Start Menu folder "Inkvolt", App Paths; `-Uninstall` removes only what it added).

## Layout

```
src/InkvoltPrint.Core      protocols, no Windows dependency (net10.0) — LEDM, eSCL, IPP, probe, PDF writer, Suite (shared with Inkvolt PDF)
src/InkvoltPrint.Windows   WinRT bits — discovery, queue install (pairing), OCR, credential store, Suite/InkvoltApps
src/InkvoltPrint.App       WPF (.NET 10, Fluent theme) — MVVM with CommunityToolkit.Mvvm
src/InkvoltPrint.Cli       developer CLI over the same code (inkvoltprint discover|probe|status|watch|settings|scan)
tests/InkvoltPrint.Tests   parser/encoder tests against fixtures captured from an HP LaserJet MFP M234dw
```

## Build / run

```
dotnet build
dotnet test
dotnet run --project src/InkvoltPrint.App
dotnet run --project src/InkvoltPrint.Cli -- status 192.0.2.10
```

Standalone executable (self-contained, no .NET install needed, ~170 MB; uncompressed on purpose: compression costs ~80 MB of RAM):

```
dotnet publish src/InkvoltPrint.App -p:PublishProfile=win-arm64   # or win-x64
# → publish/win-arm64/InkvoltPrint.exe
```

Dev aid: `InkvoltPrint.exe --snapshot out.png --tab Scan` renders the window to a PNG after connecting, then exits
(`--size 1366 860` window size in DIPs, `--theme Dark`, `--scan` runs one scan first).

Demo mode: `InkvoltPrint.exe --demo` shows one made-up printer at 192.0.2.10 served from the scrubbed test fixtures
(embedded in the exe; `FixtureHandler` replaces the network). No network access, no discovery, no Windows queue, and
the remembered-printers state is neither read nor written; scanning returns a generated page and the print queue card
shows made-up jobs. Screenshots:
`InkvoltPrint.exe --demo --snapshot overview.png --tab Overview --size 1366 860`.

Microsoft Store (MSIX, x64 + ARM64): `pwsh -File packaging/pack-msix.ps1` builds both packages, the bundle and the
`.msixupload`; no Windows SDK install needed. Partner Center values, elevation notes, Store policy, listing text and
trademark guidance: [packaging/README.md](packaging/README.md). Icons and MSIX images: `python -I assets/make-icon.py`.

## Design notes (vs. HP Smart's problems)

- One `HttpClient` per printer, per-request timeouts (5 s default; scan pages 3 min). No shared mutable port/scheme/timeout.
- No HTTP→HTTPS retry multiplication, no nested retry loops. Offline printers are retried every 20 s or when mDNS sees them again.
- Self-signed printer certificates are accepted only for that printer's host, never process-wide.
- Admin credentials are only ever sent over HTTPS.
- No sync-over-async, no busy-wait polling, no custom multicast sockets.

## Robustness

- One instance per user (named mutex + current-user-only pipe). Software rendering (the UI is static; GPU rendering cost ~200 MB on ARM64).
- Unhandled errors are logged to `%LOCALAPPDATA%\InkvoltPrint\logs\inkvoltprint.log` and shown; the app keeps running. Closing with unsaved scans asks first.
- TLS: printer certificates are pinned on first use (per printer UUID); a changed certificate blocks password-bearing writes until the user trusts it (which also forgets the saved password). Inherent to trust-on-first-use: the very first encrypted connection is trusted as-is, so set the admin password up on a network you trust; the password dialog shows the pinned fingerprint.
- Elevated actions (add printer by IP, HP clean-up) run a constant PowerShell script; every value is passed Base64-encoded and results return as exit codes (no temp files).
- Printers added by IP get a Windows queue via `Add-Printer -IppURL` (Windows requires admin: one UAC prompt).

## Not done / known limits

- Printing itself goes through the Windows queue (any app's Print dialog). The M234dw's IPP formats are PCLm / PWG raster / URF (no PDF), so a direct-IPP "print file" feature would need a rasteriser.
- CDM-only printers (newer HP models with no LEDM) get IPP status/supplies but no settings page yet.
- OCR text layer uses WinAnsi; non-Latin scripts degrade to `?` in the hidden text.
- USB-only printers: not handled (Windows' USB class driver + WIA covers them).

## License

Copyright (c) 2026 [Bermudez Systems LLC](https://bermudezsystems.com). MIT License, see [LICENSE](LICENSE).
Third-party components: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). "About Inkvolt Print" (bottom of the sidebar)
shows the version, both texts and the source code link.

Inkvolt Print is an independent project, not affiliated with or endorsed by HP Inc. HP, LaserJet and HP Smart are
trademarks of HP Inc., used here only to describe the printers Inkvolt Print works with.

Part of the Inkvolt suite with [Inkvolt PDF](https://github.com/gabandres/inkvolt-pdf) (AGPL-3.0), which uses Inkvolt Print's
libraries for scanning and printer status.
