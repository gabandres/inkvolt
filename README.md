# PrintDesk

A lean Windows app for HP network printers, replacing HP Smart. No HP account, no cloud, no telemetry,
no background services, no driver download.

| Feature | How |
|---|---|
| Find printers | Windows' own mDNS/WSD discovery (`DeviceWatcher`): DNS-SD `_ipp`/`_ipps`/`_uscan`/`_uscans` services joined to Windows association endpoints by printer UUID. Remembered printers connect at startup without waiting for discovery. Manual add by IP or host name. |
| Set up in Windows | One click: pairs the printer's IPP association endpoint, exactly like Settings → *Add device*. Windows creates an IPP Class Driver queue (and a WIA scanner from the eSCL endpoint). No admin prompt. |
| Status, toner, usage | HP LEDM (`/DevMgmt/*.xml`, URIs from `DiscoveryTree.xml`), IPP `Get-Printer-Attributes` as fallback for non-LEDM printers. |
| Live updates | LEDM event table long poll: `GET /EventMgmt/EventTable.xml?timeout=600` + `If-None-Match` (device holds the request up to 60 s). An idle printer costs one request a minute; HP Smart polls. |
| Scan | eSCL direct: JPEG pages, multi-page from the glass or feeder, fixes HP's zero-height ADF JPEGs (DNL). Saves JPEG or PDF; PDF gets an invisible OCR text layer from inbox `Windows.Media.Ocr`. |
| Print a PDF | Windows' built-in PDF engine renders pages (300 dpi, auto-rotate, fit); spooled to the printer's Windows queue with copies, page ranges, two-sided. Password-protected PDFs prompt. Drag-and-drop, "Open with", or a second launch hands the file to the running window. |
| HP clean-up | Detects HP Smart, HP's Print Support App and the services/virtual queue it leaves behind; removes them (one UAC prompt), blocks Windows from re-installing it, and re-creates affected queues (a queue created while HP's app was attached cancels every job once the app is gone). |
| Device settings | LEDM `*Dyn` + `*Cap`: only writable settings, only allowed values. Saves a minimal partial document over HTTPS; asks for the EWS admin password on 401 and can keep it in Windows Credential Manager. |

## Desk suite (with PdfDesk)

PrintDesk and PdfDesk (`Z:\PdfDesk`, the PDF viewer/organizer) are separate apps that share code and install together.
PrintDesk stays lean (software rendering, no PDF engine); PdfDesk references `PrintDesk.Core` and `PrintDesk.Windows`
by project reference for scanning (File › Scan…, Insert from Scanner…) and printer status before printing.

- **Open in PdfDesk**: after a scan is saved as PDF, the status line offers "Open in PdfDesk"; the Scan settings have
  "Open scans in PdfDesk" (open every saved PDF there automatically). Both show only when PdfDesk is installed.
  A running PdfDesk receives the file through its own single-instance pipe.
- PdfDesk's File › "Printer Settings (PrintDesk)" opens PrintDesk when it is installed.
- Each app finds the other via App Paths (`HKCU\…\App Paths\PdfDesk.exe` / `PrintDesk.exe`), else the default install
  folders (`%LOCALAPPDATA%\Programs\Desk\<app>`, `%LOCALAPPDATA%\Programs\<app>`): `PrintDesk.Windows/Suite/DeskApps.cs`.
- Shared, UI-free pieces in `PrintDesk.Core/Suite`: `DeskPrinters` (read-only view of `state.json`'s remembered
  printers and queue associations), `QueueMatch` (Windows queue → printer: stored association, device container, address
  in the port, unambiguous name), `PrinterHealth` (ready/sleeping/error/offline, toner, paper problems), `ScanChoices`
  (sources, colors, resolutions, page sizes → `ScanRequest`; PrintDesk's Scan tab uses its page sizes).
- One installer for both: `install-suite.ps1` in the PdfDesk repo (`%LOCALAPPDATA%\Programs\Desk\PdfDesk` and
  `\PrintDesk`, Start Menu folder "Desk", App Paths; `-Uninstall` removes only what it added).

## Layout

```
src/PrintDesk.Core      protocols, no Windows dependency (net10.0) — LEDM, eSCL, IPP, probe, PDF writer, Suite (shared with PdfDesk)
src/PrintDesk.Windows   WinRT bits — discovery, queue install (pairing), OCR, credential store, Suite/DeskApps
src/PrintDesk.App       WPF (.NET 10, Fluent theme) — MVVM with CommunityToolkit.Mvvm
src/PrintDesk.Cli       developer CLI over the same code (printdesk discover|probe|status|watch|settings|scan)
tests/PrintDesk.Tests   parser/encoder tests against fixtures captured from an HP LaserJet MFP M234dw
```

## Build / run

```
dotnet build
dotnet test
dotnet run --project src/PrintDesk.App
dotnet run --project src/PrintDesk.Cli -- status 192.0.2.10
```

Standalone executable (self-contained, no .NET install needed, ~170 MB; uncompressed on purpose: compression costs ~80 MB of RAM):

```
dotnet publish src/PrintDesk.App -p:PublishProfile=win-arm64   # or win-x64
# → publish/win-arm64/PrintDesk.exe
```

Dev aid: `PrintDesk.exe --snapshot out.png --tab Scan` renders the window to a PNG after connecting, then exits.

## Design notes (vs. HP Smart's problems)

- One `HttpClient` per printer, per-request timeouts (5 s default; scan pages 3 min). No shared mutable port/scheme/timeout.
- No HTTP→HTTPS retry multiplication, no nested retry loops. Offline printers are retried every 20 s or when mDNS sees them again.
- Self-signed printer certificates are accepted only for that printer's host, never process-wide.
- Admin credentials are only ever sent over HTTPS.
- No sync-over-async, no busy-wait polling, no custom multicast sockets.

## Robustness

- One instance per user (named mutex + current-user-only pipe). Software rendering (the UI is static; GPU rendering cost ~200 MB on ARM64).
- Unhandled errors are logged to `%LOCALAPPDATA%\PrintDesk\logs\printdesk.log` and shown; the app keeps running. Closing with unsaved scans asks first.
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

PrintDesk is an independent project, not affiliated with or endorsed by HP Inc. HP, LaserJet and HP Smart are
trademarks of HP Inc., used here only to describe the printers PrintDesk works with.

Part of the Desk suite with [PdfDesk](https://github.com/gabandres/PdfDesk) (AGPL-3.0), which uses PrintDesk's
libraries for scanning and printer status.
