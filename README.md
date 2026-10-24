# Inkvolt Print

Inkvolt Print (formerly PrintDesk) is a lean Windows app for network printers, replacing HP Smart. Made for HP printers, it also
works with Canon, Epson, Brother and any other IPP Everywhere / AirPrint / Mopria printer (status, ink or toner, scanning, copying,
printing). No account, no cloud, no telemetry, no background services, no driver download.

| Feature | How |
|---|---|
| Find printers | Windows' own mDNS/WSD discovery (`DeviceWatcher`): DNS-SD `_ipp`/`_ipps`/`_uscan`/`_uscans` services joined to Windows association endpoints by printer UUID; a service without a `UUID` TXT key joins its host's other services (`Core/Discovery/DnssdJoin`); a printer publishing no UUID at all is added by address. Any brand: nothing filters on HP. The IPP URL comes from the `rp` TXT key and port (IPPS for `_ipps`), the eSCL root from `rs`. Remembered printers connect at startup without waiting for discovery. Manual add by IP or host name. |
| Set up in Windows | One click: pairs the printer's IPP association endpoint, exactly like Settings → *Add device*. Windows creates an IPP Class Driver queue (and a WIA scanner from the eSCL endpoint). No admin prompt. |
| Status, toner, usage | HP LEDM (`/DevMgmt/*.xml`, URIs from `DiscoveryTree.xml`), IPP `Get-Printer-Attributes` as fallback for non-LEDM printers. |
| Other brands (Canon, Epson, Brother…) | IPP (RFC 8011, PWG 5100.13/5100.9) at the DNS-SD `rp` path, else `ipp/print` on 631 (IPPS on 631 when plain HTTP is refused). Status from `printer-state`/`printer-state-reasons` in plain words (paper, jams, covers, ink, toner, drum, waste box), plus `printer-alert` entries no reason covers; a matching alert lends the reason its `printer-alert-description` ("Yellow ink is low."). Supplies from `marker-names/levels/low-levels/types/colors` (color swatch per ink, "Ink" / "Toner" / "Supplies" card title); waste and maintenance boxes show OK / Almost full / Full from the waste reasons, no percentage. About: model, location, firmware (`printer-firmware-string-version`), the printer's web page (`printer-more-info`, only on the printer's own address) and its picture (`printer-icons`). Settings, firmware updates and page counts say they're HP only (they need LEDM). Brand from make-and-model (`PrinterBrands`). `printer-uuid` is never logged. |
| Live updates | LEDM event table long poll: `GET /EventMgmt/EventTable.xml?timeout=600` + `If-None-Match` (device holds the request up to 60 s). An idle printer costs one request a minute; HP Smart polls. |
| Scan | eSCL direct: JPEG pages, multi-page from the glass or feeder, fixes HP's zero-height ADF JPEGs (DNL). Saves JPEG or PDF; PDF gets an invisible OCR text layer from inbox `Windows.Media.Ocr`. Capabilities from any Mopria scanner: inline or named (`ref`) setting profiles, discrete resolutions (X = Y only) or a resolution range (usual values the step reaches), glass / feeder / two-sided feeder; color falls back to grey before black-and-white, "Document" intent to "TextAndGraphic"; `DocumentFormatExt` sent only to scanners that list it. Feeder states in plain words (empty, jam, cover open, mispick…); "Testing" (warming up) waits like "Processing". Maker quirks from sane-airscan: Epson gets the port in the `Host` header, Brother feeders get a short pause between pages. |
| Scan review | Large thumbnails before saving: turn, crop (drag a box on an enlarged page), delete, reorder by dragging or Alt+Shift+arrows (announced to screen readers), scan more onto the end. **Skip blank pages** (on by default): ink coverage inside a margin against the page's own paper level, specks ignored, conservative (a short word isn't blank); skipped pages stay listed, dimmed, with Keep. **Straighten pages** (on by default): projection-profile skew detection on a ~100 dpi greyscale copy, ±10°, only when the text lines give a clear answer (`InkvoltPrint.Core/Imaging`). Unedited pages keep the scanner's JPEG; edited ones are encoded once and OCR'd again. |
| Scan presets (one click) | Named sets of scan settings plus where the file goes: source (feeder when it holds pages, else the glass; glass; feeder, optionally both sides), color or grey, resolution, page size, PDF / searchable PDF (OCR) / JPEG, review step on or off, skip blank pages, straighten. One click on the Scan tab's **One-click scans** strip or the Overview's **Scan** card (Ctrl+1…Ctrl+9 for the first nine; buttons named "Scan with …" for screen readers) scans with the preset, matched to each scanner (closest resolution, a size that fits, a fallback source, each said in the status line), and saves by itself; with the review step it stops on the pages and **Save (preset)** saves. Saves to Documents, Pictures, a OneDrive or Dropbox folder on this PC (found locally: the `OneDrive*` environment variables and `HKCU\Software\Microsoft\OneDrive\Accounts\*\UserFolder`, Dropbox's `info.json`; no API, no network) or any folder, with a subfolder and file-name template: `{date}` / `{date:yyyy-MM}`, `{time}`, `{preset}`, `{printer}`, `{n}` / `{n:000}` (the preset's counter), `{pages}`; names are made safe for Windows and never overwrite (`-2`, `-3`…; a scan's images move on together). Then, optionally: open it in Inkvolt PDF, print a copy (the Windows queue, actual size), or **email it**: no account or mail server; a registered Simple MAPI mail app (`Software\Clients\Mail`) gets a new message with the files attached (`MAPISendMailW`), otherwise the folder opens with the file selected plus a `mailto:` message. Built-in starters "Document to PDF", "Photo", "Receipt"; **Manage presets…** creates, renames, duplicates, deletes and reorders them (Alt+Up / Alt+Down) with a preview of the next file name. Stored in `state.json` with a version number (repaired on load; presets from a newer version are used but not changed, and fields this version doesn't know are kept). `{n}` is reserved when a save starts, so two printers saving with one preset never share a number; JPEG sets and PDFs are written under temporary names and then named as one set. Installed unpackaged copies also put the first five in the taskbar / Start jump list (`InkvoltPrint.exe --preset <id>`, handed to a running copy). Logic in `Core/Presets` (`FileNameTemplate`, `ScanPresets`, `PresetPlan`, `SyncFolders`). |
| Notification area and alerts | **Off by default** (sidebar › *Notification area and alerts*): nothing changes until it's turned on, and closing the window doesn't ask, so Inkvolt Print never lingers unasked (the less intrusive choice than asking on first close). Turned on: an icon in the notification area shows the worst state across the remembered printers (an error such as a jam outranks a low supply, which outranks a printer that's off; badge icons from `assets/make-icon.py --tray`, one frame per small-icon size so it's sharp at 100–400%), its tooltip a line per printer, its menu (right-click, or Win+B then Shift+F10) the printers and their state, *Scan with* (the scan presets), *Pause alerts* (1 hour, 8 hours, until tomorrow morning), *Alert settings…* and *Quit*. Closing the window leaves it running there: the printers' live connections stop and each printer is read every 5 minutes (15 on battery or a metered network, backing off to an hour from one that doesn't answer; nothing without printers or network) with the same read-only status calls. **Alerts** as Windows notifications, once per problem: a supply at or under 15% (5–50%, configurable) or empty, a waste box almost full or full, a paper jam, no paper, an open cover or another printer error lasting a minute, a printer not answering for 15 minutes (can be turned off). A problem is told again only after it has been gone 10 minutes and comes back (no repeats from a flapping cover or a level wobbling at the threshold, which must rise 5 points above it to clear); alerts already shown are remembered across restarts; the PC sleeping doesn't count toward "offline". Optional quiet hours hold alerts until they end (dropped if the problem cleared). Clicking one opens that printer. No ads, no shop links: the text names the cartridge number the supplies card already shows. **Start with Windows** (straight into the notification area, `--background`): HKCU `Run` key, installed unpackaged copies only; Task Manager turning it off is shown; turning the icon off removes the entry. Turning alerts (or the icon) on starts afresh, so a problem already there is told then. Rules in `Core/Alerts` (`AlertTracker`, `AlertConditions`, `AlertPolling`, `TrayText`; tested); `Shell_NotifyIcon` by P/Invoke in `App/Tray` (no Windows Forms). |
| Print a PDF | Windows' built-in PDF engine renders pages (300 dpi, auto-rotate, fit); spooled to the printer's Windows queue with copies, page ranges, two-sided. Password-protected PDFs prompt. Drag-and-drop, "Open with", or a second launch hands the file to the running window. |
| Firmware | Version from LEDM `ProductConfigDyn` (an HP LaserJet's version is its release date) or IPP `printer-firmware-string-version`. Automatic updates (install automatically / check only / off) from LEDM's FirmwareUpdate interface (manifest in `DiscoveryTree.xml` → `FirmwareUpdateDyn`/`Cap`, PUT to `/FirmwareUpdate/WebFWUpdate/Config`), saved like the other device settings; explains HP's "dynamic security" cartridge blocking. Printers that don't expose it show the version and a link to their web page. |
| Copy | Scan (eSCL) and print (Windows queue) in one step: copies, color or grey scan, glass or feeder, two-sided output when the queue can; actual size. **ID card copy**: scans the front from the glass's corner (4.5 × 3 in), asks to turn the card over, scans the back, prints both on one sheet (top and bottom halves, actual size; `CopyLayout`). Disabled, with the reason, when the printer has no scanner or no Windows queue. |
| Print photos | **Photos** tab (also the printer's right-click menu): add pictures with **Add photos…**, drag-and-drop or "Open with" (JPEG, PNG, BMP, GIF's first frame, every page of a TIFF; HEIC and WebP when Windows has their codecs, checked with WIC's `CreateDecoder`, and said otherwise); EXIF orientation respected. Layouts: **full page** (fit the whole photo, or fill and crop), **standard sizes** (4 × 6, 5 × 7, 8 × 10 in, 10 × 15, 13 × 18 cm, wallet 2.5 × 3.5 in: as many as fit at their real size, in the orientation that fits more, ⅛ in apart for cutting; optionally a whole sheet of one photo), and a **contact sheet** (6–48 whole photos per sheet with their file names). Each photo is turned to its print's orientation; per photo: turn left / right, copies, and the crop (drag it on a sheet or in the enlarged crop view, arrow keys, zoom 100–400%). Paper size, paper type, quality and color are the ones the queue's driver offers (`PrintCapabilities`), the printable area its imageable area; **Borderless** only when the queue offers it for that paper (`PageBorderlessCapability`), else it says it prints with margins. Every sheet is previewed as it prints (grey for black-only printing), with the resolution each photo prints at and a warning under 150 dpi. Printed through the Windows queue's XPS path like PDFs and copies; pictures are sent at up to 300 dpi as JPEG, transparent areas on white. Layout arithmetic in `Core/Photos` (`PhotoLayout`, `ExifOrientation`, `PhotoPaperText`; tested). |
| Print queue | Overview card: this printer's Windows queue jobs (System.Printing `GetPrintJobInfoCollection`: name, pages, status, time, owner), re-read every 3 s only while the card is on screen. Cancel your own jobs, or all of them (confirmed); others' jobs need an administrator and say so. No elevation. |
| Printer offline fixer | **Fix it…** on an unreachable printer's status card (also the printer's right-click menu and the print queue card when a job is stuck or the queue can't be read). Checks step by step, each result shown as it comes in: the Print Spooler service; the printer on the network by a fresh mDNS look-up of its UUID (DHCP often hands it a new address; Inkvolt Print switches to it, but asks first when more than one device announces that UUID or something still answers at the old address, since the UUID is public; only IP addresses and plain `.local` names are taken); whether it answers there (ping, and TCP 631 / 9100 / 80 / 443, connect only); which Windows queues print to it (PnP container = UUID, the stored queue, a port pointing at its current, new or earlier address, else a TCP/IP or IPP-URL queue named after its model, unless something else answers at that queue's address) and what each port is (Standard TCP/IP host, WSD/IPP by device ID, IPP URL); whether those queues are paused, set to "Use Printer Offline" or hold stuck jobs. Repairs, one button each: resume, turn off Use Printer Offline, point a TCP/IP queue at the new address (or the printer's `.local` name, which follows it), add an IPP-URL queue again at the new URL under the same name, set a discovered queue up again (pairing), cancel or reprint stuck jobs, start or restart the Print Spooler (asks first when it cancels or interrupts anything); SNMP status that marks a reachable printer offline gets the steps to turn it off. Port repairs name the address they'll use before Windows' permission prompt. First as the signed-in user (spooler API: the person who set a printer up may pause, resume and take it offline; anyone may cancel their own jobs), then one UAC prompt per repair in unpackaged copies (only for the jobs Windows refused the user; scripts find queues, ports and jobs by exact name, never by PowerShell's wildcard `-Name`; a prompt still running after 2 minutes is reported as "not known yet" and the fixer checks again); the Microsoft Store version never elevates and shows the steps in Windows instead. Logic in `Core/Offline` (probes and repairs behind interfaces, tested with fakes); Windows parts in `Windows/Offline`. |
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
- `InkvoltPrint.exe --unregister` (no window; exit code 0, or 1 when the registry refused) removes what the app itself writes
  to HKCU: the "Open with" ProgIds for PDFs and pictures, their `OpenWithProgids` entries, `Applications\InkvoltPrint.exe`
  and the Start-with-Windows `Run` value, each only when it points at that exe (another copy's entries stay;
  `Core/Suite/ShellRegistration`, tested). It's a GUI exe, so wait for it: `Start-Process -Wait`.

## Layout

```
src/InkvoltPrint.Core      protocols, no Windows dependency (net10.0) — LEDM, eSCL, IPP, probe, PDF writer, Offline (fixer), Presets (scan presets, file-name templates), Alerts (tray alert rules), Photos (photo layouts), Suite (shared with Inkvolt PDF)
src/InkvoltPrint.Windows   WinRT bits — discovery, queue install (pairing), OCR, credential store, Offline (spooler probes, repairs), Suite/InkvoltApps
src/InkvoltPrint.App       WPF (.NET 10, Fluent theme) — MVVM with CommunityToolkit.Mvvm
src/InkvoltPrint.Cli       developer CLI over the same code (inkvoltprint discover|probe|status|watch|settings|scan|spooler|offline)
tests/InkvoltPrint.Tests   parser/encoder tests against fixtures captured from an HP LaserJet MFP M234dw (Fixtures/m234dw) and
                           a made-up inkjet written from the IPP and eSCL specs (Fixtures/inkjet-demo; IPP in IppText form)
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
(`--size 1366 860` window size in DIPs, `--fix` opens the offline fixer, `--fix all` also applies its repairs (demo printers only), `--theme Dark`, `--scan [n]` runs one scan (or n) first, `--crop n` then opens the crop view on page n, `--scroll-end` scrolls the tab to its end, `--copy document|idcard-front|idcard` runs a copy first, `--printer n` shows the n-th printer, `--preset id|name` runs a scan preset (`--then print|email|pdf` sets its after-saving step first, demo only), `--presets [n]` renders the presets editor on its n-th preset instead of the window; `--photos [layout]` fills the Photos tab with generated sample pictures (layouts `full`, `4x6in`, `5x7in`, `8x10in`, `10x15cm`, `13x18cm`, `wallet`, `contact`; also `--paper key`, `--borderless`, `--fit`, `--one-per-sheet`, `--per-sheet n`, `--photo-zoom n`, and `--photo-sheets folder`, which renders each sheet with the print job's own paginator to PNGs there instead of printing); with `--tray` (the notification-area icon, on in demo mode) `--simulate-alerts` feeds a toner drop on the first demo printer and a jam on the second through the alert rules, and `--tray-shot menu|hidden|alert|settings` renders the icon's menu (hidden: after closing to the tray and one background check), a preview of the last alert or the alert settings instead of the window). `--demo --tray --simulate-alerts` without `--snapshot` shows the real notification.

Demo mode: `InkvoltPrint.exe --demo` shows three made-up printers: the HP laser at 192.0.2.10 served from the scrubbed test
fixtures, an Epson-style inkjet at 192.0.2.11 (IPP and eSCL only, no HP interfaces; low yellow ink, maintenance box,
two-sided feeder) written from the public specs (both embedded in the exe; `FixtureHandler` per printer behind a
`HostRouter` replaces the network; `FixtureHandler` answers IPP Get-Printer-Attributes from `*.ipp.txt`). Snapshot the
inkjet with `--printer 2`. The third, "Demo office laser", is remembered at 192.0.2.12, where nothing answers: its offline
fixer runs against a made-up PC (`DemoOfflinePc`: a Windows queue whose TCP/IP port still points at .12, "Use Printer Offline"
on, a stuck job) and finds the printer at 192.0.2.23, so the whole flow works without touching this PC's queues
(`--demo --printer 3 --fix all --snapshot fixed.png`). No network access, no discovery, no Windows queue, and
the remembered-printers state is neither read nor written; scanning returns generated pages in turn (straight, crooked,
blank, for the scan review; a made-up ID card for card-sized regions), the print queue card shows made-up jobs and copies "print" into it. Scan presets save under
`%TEMP%\Inkvolt Print demo scans` (never the real Documents or Pictures), offer made-up OneDrive and Dropbox folders, "print"
to the made-up queue and open neither Inkvolt PDF nor a mail app. The Photos tab offers each demo printer's made-up paper sizes and types (the inkjet: photo paper, borderless except on Legal; the lasers: plain paper in black) and "prints" to the made-up queue; `--photos` draws its sample pictures (a landscape JPEG, a portrait JPEG stored on its side with EXIF orientation 6, a PNG, a two-page TIFF, a small BMP) into `%TEMP%\Inkvolt Print demo photos`: no photos ship with the app. Screenshots:
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
- TLS: printer certificates are pinned on first use (per printer UUID and port; pins from before ports were told apart stay the 443 pin); a changed certificate blocks password-bearing writes until the user trusts it (which also forgets the saved password). Inherent to trust-on-first-use: the very first encrypted connection is trusted as-is, so set the admin password up on a network you trust; the password dialog shows the pinned fingerprint.
- Elevated actions (add printer by IP, HP clean-up) run a constant PowerShell script; every value is passed Base64-encoded and results return as exit codes (no temp files).
- Printers added by IP get a Windows queue via `Add-Printer -IppURL` (Windows requires admin: one UAC prompt).

## Not done / known limits

- Printing itself goes through the Windows queue (any app's Print dialog). The M234dw's IPP formats are PCLm / PWG raster / URF (no PDF), so a direct-IPP "print file" feature would need a rasteriser.
- CDM-only printers (newer HP models with no LEDM) get IPP status/supplies but no settings page yet.
- Canon, Epson, Brother and other non-HP printers: built and tested against fixtures written from the specs (PWG 5100.x IPP,
  Mopria eSCL) and the quirks sane-airscan documents, not against real devices. To confirm on hardware: marker names, colors
  and levels as each maker reports them (some send -3 "some left", or one entry per tri-color cartridge); whether a
  printer sends `printer-alert`; waste / maintenance box levels (shown without a percentage because makers disagree on the
  direction); IPPS-only printers (self-signed certificate, pinned on first use per port, so IPPS on 631 and the web server on 443 keep separate pins; the admin password goes only to 443); Epson's `Host` header and Brother's
  between-page pause; two-sided feeder scanning; services published with different UUIDs for printing and scanning show
  up as two entries. Usage counters, settings and firmware updates stay HP only (no standard IPP equivalent is read).
- Scanners that only offer PDF (no JPEG) from a source say so instead of scanning (no PDF-page path yet).
- OCR text layer uses WinAnsi; non-Latin scripts degrade to `?` in the hidden text.
- Copy uses the PC: the printer's own copy function (LEDM `CopyConfig`) isn't driven, so a copy needs a Windows queue. ID card copy expects the card in the glass's reference corner.
- Firmware: the app doesn't start an update check or install (the printer's web page does). The IPP firmware attributes are untested on a real printer (the M234dw reports its firmware over LEDM).
- Printer offline fixer: built and tested against fakes (the diagnosis and repair order in Core tests, the whole flow in
  demo mode); the Windows side was only run read-only (`inkvoltprint spooler`, `inkvoltprint offline <uuid>`). Never run
  on real queues during development, so these need a try on real hardware: pointing a TCP/IP queue at a new address
  (`Add-PrinterPort` + `Set-Printer`), re-adding an IPP-URL queue (`Add-Printer -IppURL`, then remove and rename), resume
  and Use Printer Offline as the user (winspool) and elevated (CIM `Win32_Printer` Resume / `WorkOffline`), cancelling and
  restarting jobs (winspool, then `Remove-PrintJob` / `Restart-PrintJob`), starting and restarting the Print Spooler, and
  Set up again from the fixer. The SNMP check reads the port's `SNMP Enabled` registry value. Network-name ports rely on
  Windows resolving `.local` names for the spooler. LPR ports and the SNMP switch are steps only. Queues on a print
  server (connections) aren't looked at.
- Scan presets: "Email it" was built from the Simple MAPI documentation and never run against a mail app during development
  (to try: classic Outlook, Thunderbird, and a PC with only the new Outlook or no mail app, which should get the folder plus
  `mailto:` fallback). The jump list is set only by installed unpackaged copies (not the Microsoft Store package, where it
  wasn't tested, nor dev builds), and its tasks weren't tried on a real taskbar. Print a copy uses Copy's printing path
  (untested on hardware). "Feeder if it has pages" relies on the scanner reporting `AdfState`; one that doesn't scans from
  the glass. Presets don't remember a printer: they run on the printer shown.
- Notification area and alerts: notifications are the icon's balloons (`NIF_INFO`), which Windows 10 and 11 show as ordinary
  notifications under the app's name. WinRT toasts weren't used: an unpackaged app needs an AppUserModelID on its Start menu
  shortcut (the suite installer's shortcuts have none) or a registered COM activator to handle clicks, and the Store package's
  toast clicks couldn't be tried without packing. One notification shows at a time, so alerts read together are one
  notification ("2 printer alerts"). During development the notification was sent (Windows accepted it) and its content
  checked as a rendered preview, but its look on screen and clicking it (opens the printer) weren't watched: to try on a real
  PC, with the Microsoft Store package too. Start with Windows isn't offered in the Microsoft Store package (it would need
  the manifest's `StartupTask` extension, not built or tried yet; listed under the backlog) and wasn't tried at a real
  sign-in. The keyboard-opened menu's position is approximate on a PC whose screens use different scales. The printer's own
  low-supply warnings aren't alerts (the threshold is ours); a printer that reports no level gets alerts from its low / empty
  state only.
- Print photos: never printed on a real printer during development. The layouts were checked in demo mode, including each sheet rendered by the print job's own paginator (`--photos … --photo-sheets <folder>`), and the print-capability calls were only tried read-only on Microsoft Print to PDF (no photo paper or borderless there). To try on hardware: borderless on photo paper (drivers expand the picture past the edges themselves), the paper type and quality choices with an inkjet's driver, the IPP Class Driver's printable area, and 4 × 6 paper from a photo tray. HEIC and WebP were decoded on the development PC (Windows' HEIF, HEVC and WebP extensions installed) from small generated files, not camera photos; a PC with the HEIF but not the HEVC extension gets a message naming it, untested. Pictures with a color profile print without color management; very large PNG / TIFF files are decoded whole for their thumbnail. One photo job at a time per printer; layouts and paper aren't remembered per printer (the last layout is). No `--print-images` switch: picture paths on the command line (`InkvoltPrint.exe a.jpg b.png`) open in Photos, like PDFs open in Print.
- Backlog: Start with Windows for the Microsoft Store package (`uap5:StartupTask`, disabled by default, `StartupTask.RequestEnableAsync`); photos: color management (ICC profiles), text or date on prints, saving a photo layout as a preset, a sheet of mixed sizes.
- USB-only printers: not handled (Windows' USB class driver + WIA covers them).

## License

Copyright (c) 2026 [Bermudez Systems LLC](https://bermudezsystems.com). MIT License, see [LICENSE](LICENSE).
Third-party components: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). "About Inkvolt Print" (bottom of the sidebar)
shows the version, both texts and the source code link.

Inkvolt Print is an independent project, not affiliated with or endorsed by HP Inc., Canon Inc., Seiko Epson Corporation
or Brother Industries, Ltd. HP, LaserJet and HP Smart are trademarks of HP Inc.; Canon, Epson and Brother are trademarks
of their owners. They are used here only to describe the printers Inkvolt Print works with.

Part of the Inkvolt suite with [Inkvolt PDF](https://github.com/gabandres/inkvolt-pdf) (AGPL-3.0), which uses Inkvolt Print's
libraries for scanning and printer status.
