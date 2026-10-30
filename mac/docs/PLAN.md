# Inkvolt for macOS: plan

Decided 2026-10-26 with the owner:

| | |
|---|---|
| Apps | Inkvolt Print first; Inkvolt PDF after it ships |
| Stack | Native Swift: SwiftUI with AppKit where needed; Apple frameworks only |
| Distribution | Print: Mac App Store (sandboxed). PDF: notarized DMG with Sparkle 2, MuPDF, AGPL |
| Minimum | macOS 15 Sequoia |
| Price | Free; no account, no telemetry, no cloud |
| Signing | The Apple team that signs the Inkvolt mobile builds |
| Repo | This monorepo, `mac/`; shares fixtures and glossaries with the Windows apps |

Platform facts and their sources: [`research/print-v1-platform.md`](research/print-v1-platform.md).

## Inkvolt Print v1 scope

In:
- printer status, supplies and alerts (LEDM, CDM, IPP, SNMP; same fallback order and identity-before-data rule);
- Add a printer: Bonjour, the subnet search (TCP 631/9100/515, SNMP broadcast), a typed address;
- scanning: eSCL presets with review, crop and straighten, crash recovery; USB scanners through ImageCaptureCore;
- the offline fixer: diagnosis, cancelling the user's own stuck jobs, resuming, re-enabling and re-pointing a queue (for
  an administrator; a standard user gets a guided hand-off to Printers & Scanners);
- a menu bar item (the tray's equivalent) with alerts; launch at login only if the user turns it on;
- demo mode (the made-up environment), so App Review can use the app without a printer.

Copy, Print Photos, Print a PDF, HP maintenance, firmware update settings and LEDM settings came in 1.1. After 1.1
(2026-10-26, not in a build yet): batch scans with separator sheets and patch codes, several photos on the glass, the ID
card copy, presets' after-steps (print a copy, attach to an email) and splitting, Set Up in macOS (CUPS queue creation
from the sandbox works for an administrator), the offline fixer pointing a queue at the printer's new address, the
queue's own paper sizes and borderless in Print Photos, crop by dragging, the low-resolution warning, and firmware's
Notify left out for printers that don't keep it.

Since (2026-10-27, not in a build yet): the glass photos' boxes adjusted by hand (Photos…: move, resize, turn, draw,
keyboard), and Print Photos' paper type, quality and color, sent with the job straight to the printer's queue.

Not on the Mac: Open in Inkvolt PDF (no Mac Inkvolt PDF yet), HP clean-up (nothing like it on macOS), WIA.

## Layout

```
mac/
  CLAUDE.md, README.md
  docs/PLAN.md                   this file
  docs/research/                 platform research, one file per question set
  InkvoltPrintKit/               Swift package (from P1)
    Sources/PrintCore/           protocols and rules; Foundation only, so it also builds off the Mac
    Sources/PrintMac/            adapters: URLSession, BSD-socket SNMP, Bonjour (dns_sd), Local Network access; later
                                 the subnet scanner, libcups, ImageCaptureCore, Keychain, Core Image, PDFKit, Vision.
                                 Declared only when Package.swift is read on a Mac
    Tests/PrintCoreTests/        Swift Testing; reads print/tests/InkvoltPrint.Tests/Fixtures in place
    Tests/PrintMacTests/         the transports against loopback servers (Mac and CI only)
  InkvoltPrint/                  the app (SwiftUI): InkvoltPrint.xcodeproj (hand-made, synchronized folders, the package
                                 by relative path), Info.plist, entitlements, Resources (icon, privacy manifest);
                                 build.sh (development), release.sh + pkg-preflight.sh + asc-builds.mjs (App Store)
```

## Module map (.NET to Swift)

| `shared/InkvoltPrint.Core` | Swift | Notes |
|---|---|---|
| `Snmp/` (Ber, Oid, SnmpMessage, PrinterMib, SnmpPrinterStatus, SnmpPrinterClient) | `PrintCore/Snmp` | transport behind a protocol; `SnmpAgent` becomes the test fake |
| `Ipp/` | `PrintCore/Ipp` | the same encoder reads the local cupsd |
| `Ledm/`, `Cdm/` (parsers, status text) | `PrintCore/Ledm`, `PrintCore/Cdm` | `XMLParser` with external entities off and the same depth caps as `Net/DeviceXml` |
| `Net/` (DeviceHttp policy, FixtureHandler, HostRouter) | `PrintCore/Net` + `PrintMac/Http` | size caps, timeouts, certificate pins; `FixtureHandler` becomes a `URLProtocol` fake |
| `Model/`, `Probe/` | `PrintCore/Model`, `PrintCore/Probe` | PrinterReading, printer status, PrinterSession, connection recipe |
| `Alerts/`, `Suite/PrinterHealth`, tray text | `PrintCore/Alerts` | feeds the menu bar |
| `Discovery/` (NetworkSearch, DnssdJoin, PrinterAddress) | `PrintCore/Discovery` + `PrintMac/Discovery` | address planning stays pure; sockets and NWBrowser in PrintMac |
| `Queues/` (PrinterList, QueueKinds, SnmpQueueStatus) | `PrintCore/Queues` + `PrintMac/Cups` | Windows queues become CUPS destinations |
| `Escl/`, `Presets/` (ScanPreset, FileNameTemplate), `Imaging/ScanRecovery` | `PrintCore/Scan` | |
| `Imaging/PageImage` (rotate, deskew, crop) | `PrintMac/Imaging` | Core Image; the edit model stays in PrintCore |
| `Offline/` (diagnosis) | `PrintCore/Offline` | repairs become hand-off steps |
| `Wia/` | `PrintMac/Icc` | ImageCaptureCore; `FakeWiaSystem`'s role goes to a fake scanner protocol |
| `Pdf/PdfWriter` | `PrintMac/Pdf` | PDFKit / Core Graphics; searchable PDF with Vision |

Not ported: `Suite/ShellRegistration`, `Offline/RepairScripts`, `Queues/Spooler*`, `Wia/WorkThread`, `Presets/MailRoute`
and `Presets/SyncFolders` (macOS's share service and a folder the user picks do their work), HP clean-up.

## Steps

Each port step ports the module's .NET tests first, under the same names (in lower camel case), then the code until
they pass. PrintCore builds and tests on the Windows PC too: `pwsh -File mac/tools/swift-dev.ps1 test --package-path
mac/InkvoltPrintKit --build-system native`.

| Step | What | .NET tests to port | Status |
|---|---|---|---|
| P0 | Probe app on `ignia-mac`: answer research open items 1 to 10; record results in the research file | | Done (2026-10-26): results in the research file's "Probe results on a Mac" (items 3 and 10 settled there later; the probe was removed on 2026-10-28, its source is in git history up to 14329e3); items 3 (Printers & Scanners deep link) and 10 (SMAppService, now testable with the development certificate) still open |
| P1 | Package skeleton, CI job (`swift test` on a macOS runner), Model, SNMP | SnmpTests | Done: 42 tests. The connection and Windows queue tests wait for P4 and P7 |
| P2 | IPP | IppAndPdfTests (IPP part) | Done: 22 tests (codec, text fixtures, status, supplies, Identify-Printer, from OtherBrandsTests, RobustnessTests and MaintenanceTests too). The HTTP client waits for P4 |
| P3 | LEDM, CDM, other brands' status text | LedmTests, CdmTests, OtherBrandsTests | Done: 22 tests (LEDM documents and manifest, CDM identity, supplies and status, brands, the hardened XML and JSON readers). The connection, eSCL and web-page tests wait for P4 and P8 |
| P4 | Device HTTP, printer status, printer session, certificate pins | PrinterReadingTests, PrinterSessionTests, RobustnessTests, CertificatePinTests | Done: 78 tests (device HTTP, pins per port, the fixture transport, LEDM, CDM, IPP and eSCL clients, the connection probe, printer reader and printer session, printer ids; with the connection tests SnmpTests, CdmTests and OtherBrandsTests left for here, and eSCL from P8). The TLS handshake tests wait for PrintMac |
| P5 | Alerts, status lines | AlertTests, StatusLineTests | Done: 35 tests (conditions, the tracker's holds, quiet hours, pause, memory across restarts, polling, menu bar text, list lines) |
| P6 | Discovery: typed addresses, network search planning, DNS-SD join | NetworkSearchTests | Done: 21 tests (typed addresses, the search's addresses, SNMP question, reporting once, stopping; DNS-SD join and endpoints from OtherBrandsTests). The socket scanner is PrintMac's |
| P7 | Printer list with CUPS destinations | PrinterListTests, QueuePrinterTests (CUPS parts) | Done (2026-10-26): `CupsDestination`, `CupsQueues` (ids, virtual and temporary destinations, connection, matching a queue to a network printer), `CupsStatus`, `PrinterList` (queues part), `Demo.destinations` (30 tests); PrintMac `LibCups` (cupsGetDests2 and job counts over cupsd's socket, 1 test); the app lists queue printers, reads them every 10 s, and hides a removed network printer's own queues. `com.apple.security.print` is back. Checked on `ignia-mac`: the probe's queue for the M234dw is matched to it (not listed twice) |
| P8 | Presets, file names, scan recovery, page edits (eSCL came with P4a) | ScanPresetTests, ScanRecoveryTests, ImagingTests | Done: 52 tests (file-name templates and sets, the preset list and its JSON, the plan for a scanner, summaries; blank pages, skew, crop, rotation; scan recovery and run folders). Mail and sync-folder routes, batch separators and glass photos stay with "Later" |
| P9 | Offline diagnosis | OfflineFixerTests (diagnosis parts) | Done (2026-10-26): `OfflineModel`, `OfflineDiagnosis`, `OfflineRepairs`, `DemoOffline` (23 tests: 12 ported, 8 adapted, 3 new; the test file's header lists them); PrintMac `NetworkOfflineProbes` (Bonjour by UUID, TCP) and `LibCups` Resume-Printer / CUPS-Accept-Jobs; the app's Fix It… sheet. `--report … --demo --fix all` on `ignia-mac`: the office laser found at its new address and adopted, its queue resumed and its stuck job cancelled |
| P10 | App: main window, Add a printer, scan review, offline fixer, menu bar, settings, demo mode | DemoTests | First slice done (2026-10-26): the printer list from Bonjour and the state file, the printer pane (status, alerts, supplies, details, This is my printer), the menu bar item with alerts as notifications, the Local Network banner, demo mode, `--report`. PrintCore: `PrinterMonitor`, `DiscoveredPrinters`, `StateStore`, `SupplyText`, `Demo`, menu lines (15 tests, 287 in all); PrintMac: URLSession and UDP SNMP transports, Bonjour, Local Network signal (7 tests). Checked on `ignia-mac` with the owner's M234dw. Then (2026-10-26): the print queue card (`QueueJobs`, `RefreshGate`, 13 tests; cancelling the user's own held job checked on `ignia-mac`), the Scan tab (`ScanPages`, 5 tests; PrintMac `ScanImaging`, `ScanPdf` with Vision text, `DemoScanPage`; `--report … --demo --scan`: a blank sheet skipped, a 2.5° page straightened to 0.00°, a searchable PDF whose text is found), Settings (menu bar item, open at login through `SMAppService.mainApp`, alerts: low level, offline, quiet hours; `AlertSettings`, 4 tests), Pause Alerts in the menu, and window-closed checks (`PrinterMonitor.check`, `PollingConditions`). Later the same day: Print a PDF, Print Photos and Copy (scan → print) through the print panel on the printer's macOS queue (`Printing`; `PhotoLayout`, `CopyLayout`, `PageFit`, `PageRange` ported, 50 tests; PrintMac `PhotoSheets`); the Settings tab (LEDM settings and automatic firmware updates, the admin password in the Keychain: `PrinterPasswords`) and the maintenance card (`LedmSettings`, `FirmwareUpdate`, `Maintenance*` ported, 58 tests); USB scanners through ImageCaptureCore (`SystemScanners`, `SystemScanDevice`; `ScanDevice`, `ScannerMatch` and the printer list's scanner part, 7 tests; demo mode's `DemoScanDevice`); scan presets (one-click scans, Save (preset), Manage Presets, folders as app-scoped bookmarks). Checked on `ignia-mac`: the M234dw's 13 settings and firmware mode read (nothing written), AppKit finds its queue from the sandbox, ICC opens a session on it and reads its glass; `--report … --demo --scan` also saves a preset scan into its folder, subfolder and name. Add a printer (2026-10-26): the sheet (File › Add a Printer…, the toolbar's +, the empty list), the subnet search, removed printers put back, a typed address; PrintCore `AddPrinter` and `AddPrinterText` (9 tests), `Demo.searchNetwork`; PrintMac `SocketNetworkScanner` (2 tests); `--report … --search` found the M234dw (listed) on `ignia-mac`, and demo mode's unlisted laser. Parity with the Windows table (2026-10-26, after 1.1): batch scanning (`PatchCodes`, `Separators`, `BatchSplit`, `SeparatorSheet`, `SavedParts`, `PartNumbers` ported, BatchScanTests 21 tests; `ScanPages` files, separators and photos, 8 tests; PrintMac `SeparatorSheetPdf`), glass photos (`PhotoFinder`, `PhotoBox`, `GlassPhotoCrop`, GlassPhotoTests 12 tests; PrintMac `ScanImaging.photo`), presets' split, photos and after-steps, the ID card copy (PrintMac `IdCardSheet`), Set Up in macOS (`QueueSetup`, 7 tests; PrintMac `LibCups.addQueue`, `CupsSetupProbe`), the fixer's `.pointAt` (`setDeviceUri`), Print Photos' queue papers, borderless, crop and resolution (`QueuePapers`, 4 tests; `LibCups.media`), firmware Notify (`offered`, `noFirmwareNotify`, 2 tests); 538 PrintCore tests. Checked on `ignia-mac`: a permanent IPP Everywhere queue for the M234dw made and deleted from the sandbox (`--setup-probe`), its 25 paper sizes read; in demo mode `--batch` (2 PDFs at the Patch T sheet), `--photos` (3 photos at 4.0°, −6.0°, 2.0°, cut out straight), `--idcard`, `--setup`, `--fix all` (the queue pointed at the new address). On the real M234dw (`--hardware`, nothing printed or written to it): a glass scan with photos looked for found the one small print lying there (1.3 in) and cut it out straight; the ID card's two sides scanned from the glass's corner (4.5 × 3 in each, one Letter sheet); Set Up in macOS through the app made a permanent IPP Everywhere queue on its `.local` name, deleted again; a test queue re-pointed (`setDeviceUri`) and read back; its firmware choices left out Notify. The M234dw has no feeder, so batches and two-sided separator backs are checked in demo mode only, and printing (separator sheet, ID card, Print Photos borderless) waits for someone at the Mac. The rest of the gaps
(2026-10-27): the glass photos' boxes by hand (`PhotoBoxEditor`, 20 tests: the Windows `PhotoBoxesView`'s rules; the Photos
sheet), Print Photos' paper type, quality and color (`QueueJobOptions`, `QueueJobChoices`, 9 tests; PrintMac `jobOptions`,
`printPdf`, `sentJob`); 567 PrintCore tests. Checked on `ignia-mac`: the app builds with the 150 ms type-check limit; the
M234dw's queue offers 8 paper types, Normal and Shades of grey; `--photo-job` sent it a held job that cupsd took with
`media-col` (Letter and its margins), `media-type`, `print-quality` and `print-color-mode`, then cancelled it (nothing
printed). The Photos sheet's dragging and keys wait for someone at the Mac. Development builds are signed with an Apple
Development certificate (2026-10-27, `dev-cert.sh`: made through the App Store Connect API, in a keychain of its own that
`build.sh` unlocks, also over SSH; expires 2027-10-27), so macOS keeps Screen Recording and Local Network access from one
build to the next. The 1.1 screenshots (2026-10-27): the five status ones again, plus the Scan tab with photos on the
glass, the Photos sheet and Print Photos (`--snapshot name:index:scan|photos|print-photos`). Making them found two real
bugs, fixed: Print Photos' settings column drew blank once photos were in (each row's titled Stepper), and the Photos
sheet's buttons were cut off (it's wider now) |
| P11 | App Store: record, privacy label "Data Not Collected", review notes (demo mode, why `network.server`, the subnet search), screenshots | | Started 2026-10-26, beside P10: the App Store Connect record (macOS, "Inkvolt Print"), the Xcode project, the icon, release.sh with cloud signing and the preflight; builds 1-4 uploaded and VALID. The owner chose (2026-10-26) to submit 1.0 now with the status slice: the listing, screenshots, age rating, price and review notes go through the API (asc-listing.mjs); App Privacy on the website; the privacy policy page covers the Mac app. 1.0 requests only the sandbox and network client and server entitlements (print, USB and user-selected files come back with their features). 1.1 prepared (2026-10-26, not uploaded): `MARKETING_VERSION` 1.1, the listing's description, keywords, review notes and `whatsNew`; `asc-listing.mjs apply` creates the version when none is in preparation and sets What's New on updates; the entitlements add `print`, `files.user-selected.read-write`, `files.bookmarks.app-scope` and `device.usb` (preflight and review notes say why). The screenshots are still 1.0's; App Privacy stays "Data Not Collected" |

## Mac differences

- SNMP errors are Swift errors: `SnmpFormatError`, `SnmpTimeoutError`, `SnmpErrorStatus` (the .NET exceptions).
- IPP attribute values are an enum (`IppAttributeValue`: text, integer, boolean, bytes), not `object`.
- Device XML is read with `XMLParser` into a small tree (`XmlElement`, by local name); a document with a DTD is refused
  before parsing. CDM's JSON goes through a small reader of its own (`Json`: numbers keep their text, nesting capped at 64)
  rather than JSONSerialization, whose booleans and numbers differ between Darwin and other platforms.
- HTTP goes through PrintCore's own `HttpTransport` (request and response values; `DeviceNetworkError` for no answer),
  so PrintCore never opens a socket: PrintMac's URLSession transport and the fixture transport sit behind it.
  `CertificateCheck` holds the pin rule the TLS transport asks on each handshake; the loopback TLS tests
  (CertificatePinTests' handshakes) move to PrintMac. To check there: URLSession treats `Host` and `Authorization` as
  reserved headers, which the Epson eSCL quirk and the EWS password need.
- The IPP probe asks the DNS-SD hint and the plain endpoint at the same time, so which is asked first isn't fixed.
- A printer added by address keeps the Windows app's id (MD5 of the host as a .NET Guid; PrintCore has its own MD5 and
  SHA-256, since CryptoKit is Apple's).
- Quiet hours are minutes after midnight on a given time zone (the tracker takes one; tests pass UTC-4 as the .NET tests'
  offset). Polling backs off on battery and on a constrained network (macOS's Low Data Mode) rather than Windows' metered one.
- Network search addresses are dotted IPv4 strings; the scanner protocol is async (`NetworkScanner`), and the sweep runs
  64 addresses at a time in a task group, the SNMP question beside it and awaited when the search stops.
- Presets keep the Windows app's JSON field names and stored numbers (`StoredChoice`), so the apps read each other's
  presets; unknown fields survive a save. Paths and subfolders use "/", and the built-in Receipt preset's subfolder is
  `Scans/Receipts/{date:yyyy}`. File names stay Windows-safe (they may sync to a PC). Date and number formats are .NET's
  custom ones (`DotNetFormat`), so a template means the same on both. Page rotation runs on one thread for now.
- A run folder's lock is `flock` (the system drops it when the process dies), not a delete-on-close file; platforms
  without `flock` (the Windows PC's test runs) get an in-process lock. Recovery lists use Swift's JSON keys.
- CPU-heavy page work runs through `offPool` (an operation queue, one task fewer than the cores at a time): on Swift's
  cooperative pool, or on every core, it would stall network tasks and their timeouts, as the IPP timing tests showed.
  The image tests run one at a time for the same reason, the fixtures are read once and kept, and the two IPP timing
  tests time the IPP step alone.
- `PrinterSession` is an actor; its clock is a `now` closure, and a dropped connection simply goes (no Dispose).
- `SnmpPrinterClient` is an actor; a caller's cancellation doesn't stop waiting for a shared read (each read times out on
  its own, 1 s per request).
- The Windows app's connection loop (`PrinterViewModel.RunAsync`, `RefreshAsync`, `SetOffline`, `SetElsewhere`, the address
  move) is PrintCore's `PrinterMonitor` (an actor; events to the app), so it's tested on the fixtures. The app's printer
  model only shows what it says. For now it runs while the app runs, window or not; the Windows app's suspend-and-poll while
  hidden (`AlertPolling`) comes later.
- Queue printers are macOS's CUPS destinations (`cupsGetDests2` through libcups over cupsd's domain socket; the sandbox
  refuses `localhost:631`), not Windows queues: the queue's state, `printer-state-reasons` and `marker-*` are IPP's, so
  they're worded by the IPP readers, with macOS's own conditions first (offline, paused, not accepting jobs; CUPS's
  `cups-*` notes left out). A queue belongs to a network printer by the UUID in its device URI (`dnssd://…?uuid=`), the
  printer's address or Bonjour host name there, its Bonjour service name, or an unambiguous name or model. Bonjour's
  temporary destinations (printers macOS sees but nobody set up), faxes, classes and PDF writers are left out. Queues
  aren't renamed (renaming one in Printers & Scanners changes `printer-info`, its shown name), so there's no rename
  rule. Queue ids are `mac-queue:<name>`. Windows scanners' part of the printer list comes with ImageCaptureCore.
- The print queue card (jobs of the printer's CUPS queue, read every 3 s while on screen; Cancel for the user's own jobs,
  Cancel My Jobs) shows for a queue printer and for a network printer macOS has a queue for. Job states are IPP's
  (`JobState`), not Windows' status bits; CUPS gives no page counts through `cupsGetJobs2`, so pages show only when known.
- The offline fixer has no Print Spooler or ping step (cupsd starts on demand; TCP to 631/9100/80/443 says whether the
  printer answers) and no port types: a queue's device URI says where it prints. Resume-Printer, CUPS-Accept-Jobs and
  pointing a queue at the printer's new address (or its `.local` name: CUPS-Add-Modify-Printer with the new `device-uri`,
  `.pointAt`, the Windows app's PointPortAt) are tried from the app (they work for an administrator); refused, the fixer
  shows the steps in Printers & Scanners (remove it and add it again there). Adopting the new address is the monitor's
  `move(to:)`.
- Set Up in macOS (the Windows app's Set up in Windows) shows on a connected network printer macOS has no queue for:
  CUPS-Create-Local-Printer with the printer's IPP URL on its `.local` name (cupsd reads the printer into a driverless
  queue), then CUPS-Add-Modify-Printer with `printer-is-temporary` false keeps it (`QueueSetup`, `LibCups.addQueue`). It
  needs an administrator; refused, it points to Printers & Scanners. No scanner is added (macOS finds eSCL scanners
  itself). A printer that answers no IPP gets the hand-off.
- Scanning keeps every page in memory and in the recovery folder (`Application Support/InkvoltPrint/Scans`, the run
  folder's lock `flock`); quitting with pages not saved asks first and leaves them for the next start. Saving goes through
  the save panel (`com.apple.security.files.user-selected.read-write`): a PDF file, one JPEG, or a folder for several.
  Searchable PDFs carry Vision's words as invisible text (`ScanPdf`); straightening uses PrintCore's `PageRotate`, as the
  Windows app does. A batch or several images save into a folder the user picks (the sandbox grants only the file a save
  panel names), numbered as on Windows ("Scan (1).pdf", "Scan (2-1).jpg"). The batch's split points and separators live in
  PrintCore's `ScanPages` (the Windows app keeps them in its view model); the recovery list keeps a left-out separator as a
  skipped page and each file's first page as starting it, so a restored batch splits the same. Print a Separator Sheet
  prints a vector Patch T sheet at actual size through the print panel (which can also save it as a PDF). Photos on the
  glass are cut out with `GlassPhotoCrop` on the full-size scan's pixels; their boxes show on the thumbnail. Photos… (the
  page's menu, its button, a double-click) opens the scan as scanned with the boxes to move, resize, turn by their handle
  and draw, with Add, Remove, Turn Saved Photo and Find Again (the Windows photo view). Its rules are PrintCore's
  `PhotoBoxEditor`, tested; the Windows app keeps them in its view. Option-arrows turn a box (Windows: Ctrl-arrows, which
  macOS keeps for Spaces); the pointer shows what a press grabs; VoiceOver hears the status after each change.
- The menu bar item is on by default (the Windows tray icon starts off), with its alerts; turned off, closing the window
  quits. With it on and the window closed, network printers are checked every 5 minutes (15 on battery or in Low Data
  Mode, backing off to an hour for one that doesn't answer) instead of watched live; queues are read every minute.
  Settings are in the state file (`alertSettings`). Open at login is `SMAppService.mainApp`, off until the user turns it on.
- Printing goes through macOS's print panel (`NSPrintOperation` on a PDFKit document) with the printer's queue chosen
  when AppKit knows it (`NSPrinter(name:)` takes the queue's `printer-info`, which works from the sandbox): copies, page
  ranges, two-sided printing and paper type are the panel's and the driver's. Photos are laid out for the paper picked in
  the Photos window: the queue's own sizes and margins (`cupsCopyDestInfo`'s media list, `QueuePapers`), with Borderless
  when the queue has a borderless size of that paper (laid out edge to edge, printed with no margins; the user picks the
  panel's Borderless paper if macOS doesn't), else Letter, A4, 4 × 6 and 5 × 7 in with usual margins. Printed at actual
  size; the print panel's own paper choice doesn't move them. Each photo's crop moves by dragging it on a sheet's preview
  (`PhotoLayout.drag`), zooms with a pinch or the menu (100–400 %), and the list says the resolution each prints at,
  marked under 150 dpi. A network printer macOS has no queue for can still be chosen in the panel (macOS lists printers
  nearby).
- Print Photos sends its sheets straight to the printer's macOS queue (libcups `cupsCreateJob` over cupsd's socket, a PDF),
  as the Windows app prints with its own ticket: the paper as `media-col` (its size and margins, zero for borderless, from
  `cupsAddDestMediaOptions`, which adds nothing on libcups' default connection, so it gets its own to the socket), and
  `media-type`, `print-quality` and `print-color-mode` from the queue's `cupsCopyDestInfo` (only when the queue offers a
  choice). IPP's keywords are worded with the Windows app's Print Schema words (`QueueJobChoices`: `stationery` is plain
  paper; a maker's keyword such as `com.hp-stationery-lightweight` loses its domain and name; ones worded alike are listed
  once); quality is Draft, Normal, High (IPP has no Photographic). A printer macOS has no queue for, and demo mode, still
  print through the panel.
- The ID card copy is its own sheet (the Print menu's Copy an ID Card…; Windows: the Copy tab's ID card mode): front from
  the glass's corner, turn the card, back, then both on one Letter or A4 sheet at actual size (`CopyLayout.idCard`,
  PrintMac `IdCardSheet`) through the print panel, where copies are chosen.
- Firmware: a printer that turned on automatic installs when only the update check was written is set back, remembered
  (`noFirmwareNotify` in the state file) and no longer offered "Tell me when there's an update", as are the LaserJet MFP
  M232–M237 by model.
- Device settings and maintenance writes ask for the printer's admin password when it answers 401/403; it's kept in the
  login keychain (`PrinterPasswords`, one generic password per printer id) and sent only over HTTPS. A failed TLS
  handshake counts as "may have been sent" for a maintenance action (`DeviceNetworkError` has no TLS case). Settings PUTs
  start with an XML declaration (the .NET code's `XDocument.ToString()` leaves it out).
- USB scanners come through ImageCaptureCore (`com.apple.security.device.usb`): the browser asks for local devices only
  (network scanners are eSCL's), its list is used once it has held still for 2 s, and a scanner goes to the queue
  printer whose name or model is its own (`ScannerMatch`, simpler than WIA's matching) or is listed as a scanner of its
  own. Scanning is file-based JPEG through ICC; a session's units arrive a moment after it opens. Untested with a real
  USB scanner (none at hand); the session code ran against the network M234dw.
- Scan presets keep the Windows JSON (state file `scanPresets`); each preset's folder is an app-scoped security bookmark
  (`presetFolders`, `com.apple.security.files.bookmarks.app-scope`), asked for the first time it saves (Documents or
  Pictures suggested, as the Windows preset's folder kind says). A sync folder is any folder the user picks there (iCloud
  Drive, Dropbox: no code of its own). After saving, a preset can print a copy on its printer or attach the files to a new
  email through macOS's share service (`NSSharingService` `.composeEmail`, the user's mail app; the Windows `MailRoute`
  isn't needed). Open in Inkvolt PDF waits for a Mac Inkvolt PDF: a Windows preset with it only saves.
- Add a printer is a sheet over the main window (File › Add a Printer… ⌘N, the toolbar's +, the empty list's button). Its rules
  (what an address that answered becomes, the order, what the sheet says, a few identified at a time) are PrintCore's
  `AddPrinter`, tested, where the Windows app keeps them in its view model. The search's networks are the Ethernet and Wi-Fi
  interfaces that are up with a broadcast address (no utun, ipsec, ppp, bridge, awdl or llw), not "adapters with a gateway";
  TCP through Network framework, the SNMP question on a BSD socket with `SO_BROADCAST`. "Connected with a cable?" points at
  Printers & Scanners (USB printers join the list with P7).
- Discovery is Bonjour only (no Windows association endpoints): `dns_sd`'s browse, resolve and IPv4 lookup in PrintMac
  (`BonjourDiscovery`; Local Network denied is `kDNSServiceErr_PolicyDenied`), joined into printers by PrintCore's
  `DiscoveredPrinters` (the Windows discovery's `Merge`, services part). A printer needs an IPv4 address to be listed.
- Local Network access has no API: `LocalNetworkSignal` is told by the transports and Bonjour (denied: URLSession's -1009
  whose network path says `localNetworkDenied`, `EHOSTUNREACH` on UDP, `PolicyDenied`; allowed: any answer). Denied shows a
  banner with a link to System Settings; once allowed, discovery and the offline printers start again at once.
- The state file is `state.json` in the container's Application Support/InkvoltPrint, with Swift's JSON keys
  (`StateStore`: remembered printers, the selection, pins, accepted UUIDs, forgotten printers, alerts shown). Demo mode's
  state is in memory.
- URLSession sends `Authorization` and `Host` as given (PrintMacTests checks both against a loopback server), so the EWS
  password and the Epson eSCL quirk (`Host: host:port`) work as on Windows.
- Demo mode reads the fixtures from the app bundle (`Contents/Resources/Demo`, copied by a build phase), not embedded resources.
  "Try the Demo" opens the made-up printers in a second window of the same process (`AppModel.demo`): macOS drops the
  arguments a sandboxed app passes when it opens a second copy of itself, so the Windows app's second process can't work.
- The app icon shows where the Windows app has it: the sidebar's header, the About panel (macOS's standard one, with
  credits), plus the empty list. The menu bar item is the Inkvolt mark as a template glyph with a status badge, not the
  colour icon (menu bar items are monochrome).

Decided 2026-10-26, starting the app: Inkvolt Print's bundle ID is `com.bermudezsystems.InkvoltPrint`, on the Inkvolt
mobile apps' team (AE6TTXW92K); development builds are ad-hoc signed; App Store builds are signed by Xcode with the
team's cloud-managed certificates through the App Store Connect API key (no certificate in the Mac's keychain), as the
mobile apps are. The app is a hand-made Xcode project (no XcodeGen). Store setup and TestFlight run beside the v1
features; the app goes to review once the v1 scope is in. Print and PDF stay two apps (PDF can't be on the App Store:
AGPL MuPDF and Sparkle). The repo is cloned at `~/Repos/inkvolt` on `ignia-mac`.

## Inkvolt PDF v1

Decided 2026-10-27 with the owner, as Inkvolt Print 1.1 waits for App Review:

| | |
|---|---|
| Engine | MuPDF's C library for everything the document is: drawing, text, and the PDF objects that editing, forms and saving work on (the role PDFsharp has on Windows). One model of the document, so pages look and export as on Windows. No PDFKit for the document; the page view is our own |
| Text shaping, form scripts, signatures | Core Text (or MuPDF's own HarfBuzz) for HarfBuzzSharp, JavaScriptCore for Jint, Security.framework for System.Security.Cryptography.Pkcs: Apple frameworks, no packages beyond MuPDF and Sparkle |
| Bundle ID | `com.bermudezsystems.InkvoltPdf` |
| Distribution | Developer ID, notarized, a DMG; updates through Sparkle 2 (EdDSA-signed appcast). Not sandboxed (Sparkle's unsandboxed setup; the app opens whatever file the user picks) |
| License | AGPL-3.0 with MuPDF's notices and source offer, as `pdf/THIRD-PARTY-NOTICES.md` |

In 1.0, the reader and everyday edits:
- tabs (macOS window tabs), reading modes (continuous, single, two pages, cover), zoom, rotate view, full screen;
- the side rail: thumbnails, outline, search, comments; find with match case and whole words; select and copy text;
  links;
- comments: highlight, underline, strike out, notes, free text, drawing (pen, highlighter, shapes, lines, arrows),
  stamps, images;
- forms: fill text fields, check boxes, radios and lists, with their calculations and formats (form JavaScript); Fill &
  Sign (text, check marks, a drawn or typed signature);
- organize pages: rotate, delete, move, insert (blank, from a file, from images), extract, combine files, new PDF from
  images; bookmarks;
- passwords: open protected files, protect with a password, keep a document's protection through edits;
- saving as Windows does: incremental, so earlier signatures stay intact; undo and redo; recovery copies of unsaved
  work;
- print; Open in Inkvolt PDF from Inkvolt Print (its presets' last step);
- edit text and images (the Windows app's Edit Text & Images: the page's own text and pictures);
- OCR: an invisible text layer on scanned pages, through Apple's Vision (as Inkvolt Print's searchable scans);
- export to Word, Excel and text (`DocLayout`, `DocxWriter`, `XlsxWriter`; `pdf/tools/export-corpus` as the check);
- Sparkle updates, What's New after an update; settings.

Decided 2026-10-27 (the competitor review): text editing, OCR and export are in 1.0, so it stands against PDF Expert,
which sells exactly those. After 1.0, the E-steps of "Parity with Windows" below bring the rest, in roughly this order:
redaction (with redaction by pattern, as Windows gets it first), digital signatures (verify, sign), compare files, sanitize,
reduce file size, flatten, header and footer, watermark, measure, PDF/A, batch, layers, attachments, Read Aloud, the AI
features.

### Layout

```
mac/
  InkvoltPdfKit/                 Swift package
    Sources/CMuPDF/              MuPDF's headers as a C module (the library itself from mac/Vendor/mupdf)
    Sources/PdfCore/             the Windows Core's rules over MuPDF: engine, document session, edits, forms, pages
    Sources/PdfMac/              what touches AppKit and the system: the page view's tiles, Core Text, JavaScriptCore,
                                 printing, the recognizer later
    Tests/PdfCoreTests/          Swift Testing; reads pdf/tests fixtures and test PDFs in place
  InkvoltPdf/                    the app (SwiftUI with AppKit for the page view): Xcode project, Info.plist,
                                 entitlements (hardened runtime), build.sh, release.sh (Developer ID, notarytool, DMG,
                                 Sparkle appcast)
  Vendor/mupdf/                  build.sh: MuPDF at a pinned tag as a static XCFramework (arm64, x86_64), built from
                                 its source (not kept in the repo), with the build's notices
```

Unlike PrintCore, PdfCore needs MuPDF, so it builds and tests on the Mac and in the `mac` CI job, not on the Windows PC
(MuPDF could later be built for Windows' Swift too).

### Module map (.NET to Swift)

| `pdf/src/InkvoltPdf.Core` | Swift | Notes |
|---|---|---|
| `PdfEngine`, `PageText`, `TextLayer`, `Links`, `Geometry` | `PdfCore/Engine` | MuPDF on both; the closest port |
| `DocumentSession`, `DocumentSession.Edit`, `Incremental`, `Recovery` | `PdfCore/Session` | PDFsharp's object edits become MuPDF `pdf_obj` edits; incremental saves with `pdf_save_document` |
| `PdfSecurity`, `KeptProtection`, `PasswordStrength`, `SignedEdits` | `PdfCore/Security` | |
| `PageEditor`, `PageRange`, `ImageImport`, `Bookmarks`, `BookmarkTree` | `PdfCore/Pages` | |
| `Annotations`, `Annotations.Drawing`, `Appearances`, `DrawingGeometry`, `RubberStamps`, `TextStamps`, `PageMarks` | `PdfCore/Annotations` | appearance streams written as on Windows |
| `FormActions*`, `FormScripts`, `JsFormHost`, `JsPrelude`, `TabLabels` | `PdfCore/Forms` + `PdfMac/Scripts` | Jint becomes JavaScriptCore behind a protocol, so PdfCore tests can use a fake |
| `Shaping`, `FontKit`, `FontNames`, `FontPrograms`, `TextFonts`, `Bidi` | `PdfMac/Text` | HarfBuzzSharp becomes Core Text or MuPDF's HarfBuzz (decided at D4) |
| `PrintLayout` | `PdfCore/Printing` | printing through `NSPrintOperation` with our own page drawing |
| `Redaction`, `RedactionPatterns`, `RedactionCheck`, `Sanitizer` (with `HiddenContent`), `StructTree`, `DocumentInventory`, `InventoryReportFiles` | `PdfCore/Redaction` | E1 (the inventory: E1a); `FormEditor.ClearFields` there too |

Not in 1.0 (their modules port with their features; E1 brought `Redaction` and `Sanitizer`): `ContentEditor`, `ContentLexer`, `Redaction`, `DocLayout`,
`DocxWriter`, `XlsxWriter`, `DocumentExport`, `ExportGlyphs`, `ExportPage`, `Signatures`, `Signing`, `SigningIds`,
`SignatureChanges`, `SignatureStamps`, `DocumentCompare`, `CompareReport`, `VisualCompare`, `WordDiff`, `Sanitizer`,
`Optimizer`, `Flattener`, `HeaderFooter`, `Watermarks`, `Measurement`, `PdfA`, `Batch`, `Layers`, `Attachments`,
`ReadAloudText`, `StructTree`, `FieldDetection`, `FormDesign`, `FormEditor`, `Conversion`, `Ai*`.

### Steps

As for Print: each step ports the module's .NET tests first, under the same names, then the code until they pass.

| Step | What | .NET tests to port | Status |
|---|---|---|---|
| D0 | MuPDF for the Mac: `Vendor/mupdf/build.sh` (pinned tag, the Windows app's 1.25.2 or the current release), the XCFramework, `CMuPDF`, the package skeleton, the CI job; open a test PDF, draw a page, read its text | | Done (2026-10-27): MuPDF 1.25.2 (the Windows app's) built from its tag on `ignia-mac`, arm64 and x86_64 for macOS 15, as one static XCFramework (107 MB, not in git) with a `CMuPDF` module map; zlib's `fdopen` clash with the macOS SDK worked around (`-Dfdopen=fdopen`). The C shim `MuPDFShim` catches MuPDF's errors (fz_try) and hands Swift the message, marks them handled and keeps MuPDF quiet on stderr. `PdfEngine` opens, counts, sizes, draws and reads a page; `TestPdf` writes the tests' PDFs by hand (the Windows tests draw them with PDFsharp); 5 tests on `ignia-mac`. The `mac` CI job's `pdf` part builds MuPDF (cached until `build.sh` changes) and runs them |
| D1 | Engine: open (passwords), page geometry, rendering (regions, cancel), text and words, links, outline | EngineTests, Core1EngineTests (with Core1TextTests), PageTextTests, Core1NavigationTests (the reading parts) | Done (2026-10-27): `PdfEngine` (a render instance and a text instance with their own locks, the last 32 pages and their display lists kept loaded per instance, renders stopped midway through MuPDF's cookie, a text cache of 48 pages), `PageText`, `RotatedView`, `RenderedImage.rotated`, `CancelToken`; the shim grew page caching, abortable drawing, characters with their boxes, links, the outline, image saving and whole-file writing. 33 tests on `ignia-mac`, the timing ones measured (a cancelled render stops early; text reads while a render runs). Moved: TextLayerTests to OCR, HostileStructureTests to the steps of what they test (D3, D5, later) |
| D2 | Document session, edit transaction, undo steps, incremental save, kept protection, passwords, recovery | EditTransactionTests, RecoveryTests, KeptProtectionTests, SecurityTests, OwnerPasswordTests, SessionProtectionTests, PasswordStrengthTests, SignedEditTests | Done (2026-10-27): `DocumentSession` (byte snapshots, undo and redo with step ids, atomic saves that keep the file's creation date, read-only files refused, changes on disk noticed, reloads), the edit transaction (`edit`: one edit at a time, the owner password asked until it works, a signed file's rewrite asked first, failures and cancellations commit nothing), `PdfEdit` (PDFsharp's open and save: an encrypted file edited only with its owner password; a signed file's edit appended by MuPDF, even after junk past %%EOF; anything else written whole with `encrypt=keep`), `PdfSecurity` (protect with AES-256 or AES-128, unprotect, read the method, revision and permissions), `PasswordStrength`, `SignedEdits`, `KeptProtection` (only to drop an open password), `RecoveryStore` with its own `RunFolder`, and `PageEditor`'s rotate and delete. 48 tests (81 in the package) on `ignia-mac`: SecurityTests, PasswordStrengthTests, OwnerPasswordTests, KeptProtectionTests, SessionProtectionTests, RecoveryTests, Core1SessionTests, EditTransactionTests (9 of 11), SignedEditTests (4 of 7). Left out until their steps: what needs forms (D5), comments (D4), extraction (D3) or signature verification (later); and the tests of the Windows incremental writer's own parsing and its .NET allocations. Each test file's header lists what was adapted |
| D3 | Pages: organize, ranges, insert from files and images, bookmarks | PageEditorTests, PageRangeTests, PageStructureTests, ImageImportTests, BookmarkTests, BookmarkTreeTests | Done (2026-10-27): `PageEditor` (rotate, delete, move, insert, extract, duplicate, merge, crop, metadata), `Bookmarks` (read and write the outline), `ImageImport` (images to PDF through MuPDF), `PdfStructure` (page labels, outline, named destinations, threads, fields, stray references), `Xmp` and `InfoDict`, `PObj` and `Graft` over MuPDF's pdf_obj in the shim; with `PageRange` and `BookmarkTree`, 61 tests (168 in the package). The edits were also run on three real PDFs (copies): rotate, delete, extract, duplicate, merge, insert, bookmarks; each result opened in PdfEngine and in PDFKit with the right pages in the right order. Left for D4, D5 and later (each test file says which): the save paths of comments, stamps, attachments, redaction and forms keeping XMP, form fills after a merge, signature verification |
| D4 | Comments, drawing, stamps, images, text shaping for their appearances | DrawingAnnotationTests, DrawingGeometryTests, RubberStampTests, TextStampTests, Core2StampTests, LinkAndImageTests, ShapingTests, BidiLineTests | Done (2026-10-27): comments (highlight, underline, strike-out, notes, free text, replies, colors), drawing (ink, shapes, lines and arrows, polygons, callouts) with their appearance streams, rubber stamps, text and picture stamps, link annotations, and text shaping through Core Text (bidi, fallback fonts); 46 tests (214 in the package), every kind also added to three real PDFs (copies) and read back by PdfEngine and PDFKit. Not ported yet: PageMarks (header, footer, watermark: E4), FontPrograms and TextFonts (D5a), flattening (E4) |
| D5 | Forms: fill, appearances, actions, form JavaScript (JavaScriptCore), Fill & Sign | FormTests, Core2FormTests, FormActionTests, FormAppearanceTests, JsFormTests, Core2ScriptTests, TabLabelTests || Done (2026-10-27): forms (read, fill, appearances with check box and radio faces, calculations, formats, keystrokes, actions, FDF/XFDF/HTML submit and import) and Fill & Sign (the D4 stamps), form JavaScript on JavaScriptCore behind a `FormScriptEngine` protocol (the Windows prelude as is, one VM per document, only the standard built-ins, outward calls through the host callback as on Windows), with a time limit; 76 tests (290 in the package). The real PDFs have no form fields: forms checked on the hand-written ones |
| D5a | Edit text and images: the page's own text (ContentEditor, ContentLexer, the fonts it needs) and pictures | ContentEditorTests, ContentEditFontTests || Done (2026-10-27): `ContentEditor`, `ContentLexer`, `TextFonts`, `GlyphNames` and the TrueType, CFF and Type 1 program readers: text edited in its run's own font (only when every glyph is there; new codes get their width from the font program and a ToUnicode entry, as on Windows), pictures moved, resized, replaced and deleted; 40 tests (331 in the package); a word changed and a picture moved on four real PDFs (copies) |
| D5b | OCR: Vision's recognizer behind PdfCore's recognizer function, the invisible text layer (TextLayer) | TextLayerTests, ScanPdfTests || Done (2026-10-27): `TextLayer` (the invisible layer in an embedded glyphless TrueType with a ToUnicode per page, as Tesseract does, so nothing shows even where render mode 3 is ignored), `PageOcr` (pages drawn at 300 dpi, capped at 60 MP, pages with text skipped, cancellable) and `VisionRecognizer` (accurate, language correction, languages detected); 15 tests (346 in the package); a real scan (a copy) recognized in 0.8 s, its page unchanged, its words found by MuPDF and PDFKit. The first Vision call on a Mac loads its model (about 50 s): the app shows progress |
| D5c | Export to Word, Excel and text (DocLayout, DocxWriter, XlsxWriter, DocumentExport, ExportGlyphs, ExportPage) | ExportTests, ExportPipelineTests, ExportFormTests, ExportRealWorldTests; `pdf/tools/export-corpus` on the Mac || Done (2026-10-27): `DocLayout` (with tables and text), `DocxWriter`, `XlsxWriter`, `DocumentExport`, `ExportGlyphs`, `ExportPage` and the export page read (structured text with fonts, pictures, rules, figures) in the engine and shim; Foundation-only ZIP (Compression framework deflate, CRC-32) and XML writers, repeated pictures stored once (CryptoKit SHA-256); 47 ported tests plus a corpus check and the real files (395 in the package). Against the Windows exports of `pdf/tools/export-corpus`: text and Word bodies identical for 6 of 7 documents; nist-sp800-63-3 differs in one header row MuPDF reads as four lines (open). The Open XML SDK validator (Windows) is a well-formedness, content-type, relationship and `unzip -t` check here, plus textutil reading the .docx |
| D6 | Print layout | PrintLayoutTests | Done (2026-10-27): `PrintLayout` and `PrintPlan` (PrintLayoutTests, 13 tests); the printing itself comes with D7 |
| D7 | The app: document windows and tabs, the page view (tiled rendering, selection, find, VoiceOver), the side rail, tools, start page, settings, recovery prompt; Open in Inkvolt PDF from Inkvolt Print | | Done (2026-10-28): the reader, `mac/InkvoltPdf` (a SwiftPM app; `build.sh` makes, signs with the development identity and installs `/Applications/Inkvolt PDF.app`): open, Open Recent, Finder's Open With, window tabs; continuous scrolling, pinch and keyboard zoom with pages redrawn sharp in the background (stale renders cancelled); thumbnails and the outline in a sidebar; find with highlighted matches; selecting and copying text (word, line, all); the password prompt; damaged files refused with a message. `--self-test <report>` runs 17 checks per document in the real app: all pass on seven files (three real ones, as copies; a 300-page, a mixed-size and rotated, a navigation and a cupsfilter PDF), every page drawn at 0.5×, 1× and 2×. Editing (part b, 2026-10-27): the comment tools (highlight, underline, strike-out, note, text box, pen, highlighter pen, rectangle, ellipse, line, arrow, stamp, image, link; one key each, as on Windows), the inspector popover (color, width, opacity, text size, text, replies, link target, Delete), the sidebar's Comments list (by page, replies nested, filtered by kind and author), undo and redo per edit, Save, Save As, Revert, the "changed on disk" bar and Reload, recovery copies (offered back at launch); `--edit` drives every tool through the page view's own event handling and reads the saved file back. Fixed in the shim on the way: an edit to a signed file appended the original bytes a second time. Not yet: callout and polygon tools, moving or recoloring notes and text markups, tiles for very high zoom, selection across pages, clickable links, the icon; checked only through the self-test (no one at the screen). Part c (2026-10-27): forms filled on the page (fields outlined; check boxes, radio buttons, combo and list boxes, an editor over text fields; keystroke scripts as you type, validate, calculate and format scripts on each write; Tab order; field and button actions through `FormEditor.runAction`, every outward step asked first; File › Form Data: Reset, Import and Export as XFDF or FDF, over `FormEditor.resetForm`, `exportData` and `importData`, new in PdfCore with FormDataExchangeTests, 400 tests in the package); Fill & Sign (text, check mark, cross, date, signatures and initials drawn or typed in a sheet, moved with the hand tool); Edit Text & Images (a run's text rewritten in its own font, pictures moved, deleted, replaced); Tools › Recognize Text (all pages without text, the current page or a range) and File › Export To Word, Excel or text (pages, OCR, open when done), both with a progress sheet and Cancel from the start (Vision's first load included); a notice bar for what happened. Each change is one undo step through the edit transaction. `--edit` adds `FeatureTest` (`--synthetic` also opens a form made by the app, and the text document gained a scanned page): 163 checks (168 with `--snapshots`) on two synthetic documents and eleven real copies, all pass, every result saved and read back. Not yet: saved signatures between launches, CSV and JSON form data, fields' hover (enter, exit) actions, Sign Digitally on a signature field (E2), resizing pictures or moving them with the keys in Edit Text & Images, a form's print action (no printing yet). Part d (2026-10-28), done: Pages › Organize Pages, a grid of page cards (choose several, drag to move, Delete, a context menu), and the page commands on its cards, on the sidebar's thumbnails (several can be chosen; their context menu) or on the current page: rotate left and right, duplicate, delete, extract to a new PDF (opened in a tab), insert from a PDF or pictures and blank pages, crop and remove crop; bookmarks added (⌘D, after the one selected), renamed, deleted and dragged into order or under another in the sidebar; File › Protect with Password… (open password, permissions password and restrictions, AES-256 or AES-128) and Remove Password Protection…, the new passwords committed with the step; File › Print… and Page Setup… through `NSPrintOperation` and the standard panel, with Inkvolt's options in its accessory view (the document's page range; one page per sheet at actual size or fitted, pages per sheet, booklet, poster, laid out by `PrintPlan`), also for a form's print action; links followed on the page (a page, web and mail addresses, any other address after asking), text selected across pages, 512-pixel tiles where a page would pass 16 megapixels at the zoom shown, and the close and quit questions (NSDocument's, for several documents too); the Callout, Polygon and Polyline tools, and notes and text marks moved with the hand tool and recolored (`Annotations.move`, `Annotations.setColor`, new in PdfCore with CommentMoveTests: 405 tests in the package). Each change is one undo step through the edit transaction. `--edit` adds `PagesTest` (each feature through the window's own commands, mouse and keys, every result saved and read back, printing only to PDF files in a temporary folder) and, with `--quit`, a close-all with unsaved changes; the reader's checks gained the 800 % tiles: 260 new checks, 895 in all, on two synthetic documents and eleven real copies, all pass (selection across pages skipped on the six without two pages of text in a row). Not yet: dragging thumbnails in the sidebar to move pages (the organizer does), a file per page from Extract, vector printing. Part e (2026-10-28), the last: the start page, a window of its own shown when no document is open (at launch, after the last one closes, File › New Window, a click on the Dock icon): Open a file, the Tools cards that exist on the Mac (Fill & sign, Edit text & images, Export to Word, Combine files, Protect, Recognize text, Organize pages, and Create a PDF from pictures, the clipboard or a scanner; a card that works on a PDF asks for one and opens it straight in that tool), the recent files with page 1 of each, files dropped on it; Settings (⌘,: app theme, the zoom documents open at, reopen each file at the page where it was left, recovery copies, update checks, the author name on comments, Reset to Defaults; UserDefaults under the Windows names); the command palette (⇧⌘K: every menu command the window in front can run, searched by any words, run with Return); Help › What's New (the app's `WHATS-NEW.md` through `ReleaseNotes`, new in PrintCore with ReleaseNotesTests; shown once after an update) and About (version, copyright, the AGPL and the source link, "Nothing you open leaves this Mac", the third-party notices with Sparkle's license text as it ships); File › Scan… over Inkvolt Print's code (`InkvoltPrintKit` as a local package: eSCL scanners found by Bonjour, USB scanners through ImageCaptureCore; glass, feeder, both sides, color, resolution, page size; the pages made a PDF by PdfCore's `ImageImport` at the scan's resolution, opened as a new document, made searchable if asked); File › Combine Files… (the files in your order, a bookmark each), New PDF from Images… and from Clipboard, each a new unsaved document; View › Zoom to Page. Inkvolt Print's scan presets can end with Open in Inkvolt PDF (found by its bundle ID; Inkvolt PDF already took PDFs as a document type). `--edit --synthetic --quit` adds `AppTest`, the app's windows driven through their controls: 34 (41 with `--snapshots`) checks, all pass; with the earlier parts 929 checks on two synthetic documents and eleven real copies, all pass. Not yet: Insert from Scanner into the open document, the scanners Inkvolt Print remembers, printer status when printing and Inkvolt Print's printer settings, reading modes (single page, two pages, cover), rotate view, dark pages, Report a Problem |
| D8 | Release: Developer ID certificate, hardened runtime, notarytool with the API key, the DMG, Sparkle 2 (EdDSA key, appcast and where it's hosted), notices and the source offer | | Done, published 2026-10-28: GitHub release `pdf-mac-v1.0.0` (not Latest) with the notarized DMG, the feed on the `appcast` branch, the download on bermudezsystems.com/products/inkvolt/ and the privacy policy's "Inkvolt PDF for Mac". Before that, built and verified (2026-10-28): `release.sh 1.0.0 --appcast` on the Mac made `Inkvolt-PDF-1.0.0.dmg` and `appcast.xml` in `~/build-artifacts/inkvolt-pdf-mac` (notes from `release-notes/1.0.0.md`, the short form of WHATS-NEW's 1.0.0). Checked on the built files: app and DMG notarized (Accepted, no issues) and stapled (`stapler validate` on both), `spctl` accepts both (Notarized Developer ID, Team AE6TTXW92K), `codesign --verify --deep --strict` passes, hardened runtime on the app, Autoupdate, Updater.app and Sparkle.framework, each signed with the Developer ID and a secure timestamp, no entitlements, no XPC services; Info.plist 1.0.0, SUFeedURL the appcast branch's raw URL, SUPublicEDKey, no system profile, macOS 15.0; the appcast item's length matches the DMG and its EdDSA signature verifies with the public key alone (a CryptoKit check; a one-byte change fails). A real update, all on the Mac: a notarized 0.9.0 built with `INKVOLT_FEED_URL=http://localhost:8765/appcast.xml`, installed in a temporary folder, `--update-test <report> --install` found 1.0.0 on a local `python3 -m http.server`, downloaded, verified and installed it (the bundle read back 1.0.0 with the GitHub feed, codesign valid) and relaunched; with one byte of the served DMG changed (in its resource list, so the image still mounts and the app inside is intact) Sparkle refused it (SUSparkleErrorDomain 4005, improperly signed) and 0.9.0 stayed. The DMG mounted, the app copied out of it ran `--self-test --edit --synthetic --quit`: 137 checks, all pass. Not proven: Check for Updates… clicked in the menu (the self-test calls the same updater without a window), Sparkle's update prompt UI, the download from GitHub (the `appcast` branch doesn't exist yet: create it, an orphan branch, before `--publish`, which otherwise creates the release and then fails to put the appcast). `--publish` rebuilds and re-notarizes, so the published DMG's SHA-256 differs from the verified one |
| E1 | Redaction (with redaction by pattern), the redaction check, Sanitize Document | Core2RedactionTests, RedactionPatternTests, RedactionCheckTests, SanitizerTests | Done (2026-10-28): `PdfCore/Redaction`: `Redaction` (each page with marks drawn at 300 dpi with its comments and fields, the marks blacked out in the pixels, the page's content replaced by the picture; a field an area touches emptied on every page through `FormEditor.clearFields`; the page's annotations, widgets (out of the field tree, /CO and XFA too), thumbnail, private data, associated files and its part of the structure tree (`StructTree`) gone), `RedactionPatterns` (Social Security, phone, email, payment card with Luhn, date, ZIP, IBAN with mod 97, IP; the user's phrases and pattern; line breaks read as spaces, hyphenation joined; the stronger kind keeps text two claim; time limits), `RedactionCheck` (text under dark boxes, comments and other content or in the color behind it, pictures under dark boxes drawn again without them, unapplied Redact marks, spacing beside a box, the values in every object, decoded stream, attached file, earlier version and the raw bytes, areas that still show something or the original picture; each finding's fix, and `fix`), `Sanitizer` and `HiddenContent` (eleven kinds; hidden layers cut out of every content stream, their graphics state kept; a full rewrite, new file identifier, read back and scanned again). 58 tests (463 in the package, 0 warnings on `ignia-mac`): the four Windows files with the same names (Core2RedactionTests 5, RedactionPatternTests 26, RedactionCheckTests 11, SanitizerTests 16), Batch's two tests left out (E8) and two Mac additions (invisible text over a dark area, a just-written /ModDate); each file's header says what was adapted. The app: the Redact tool (F; drag an area, click a mark to unmark it) and Tools › Redact Selected Text (also in the selection's context menu), Redact Search Matches, Redact by Pattern… (a sheet: the kinds in two columns with examples, words and phrases, a pattern checked as it is typed, whole words, case, pages), the redaction bar over the pages (how many areas on how many pages, Mark Search Matches, Clear Marks, Apply Redactions…, Done), Apply Redactions… (asks first; one undo step: the pages become pictures, then Vision recognizes the text left on them and lays it back invisibly, Cancel skipping only that), the check after Apply in the background (a notice when nothing is left, else its report), Check Redaction… on any PDF (progress and Cancel), the report sheet (each finding, where, how it is fixed; Fix N Things redacts, sanitizes and checks again; Copy Report), Sanitize Document… (a sheet with each kind found and its count, one undo step, then what went and what is still there). `--edit` adds `RedactTest` (every command through the window's own controls: the tool from its menu item and the page view's own mouse handling, the bar's buttons, the sheets' buttons; each result saved and read back, then undone; `--only-redaction` runs it alone): 23 checks on the two synthetic documents (with `AppTest`, 160 in all, all pass) and 10 on each of seven real copies (the export corpus' public PDFs), all pass; on those copies the earlier parts' checks pass too (621 checks, all pass, with the two fixes of 2026-10-28: on census-p60.pdf a click on text lying on a picture picked the picture, so Edit Text & Images now lets text on a picture win unless that picture is selected, as on Windows, and `FeatureTest` adds a run-over-a-picture check where a page has one; on resnet.pdf the self-test drew its new links over the file's own, where the Link tool selects the link as on Windows, so `EditTest` now puts them where the page has no link and skips with a note when none is free). Not yet: Batch's Redact Patterns and Check Redaction (E8) |
| E1a | What's in This PDF (roadmap 2.5), over E1's Sanitize | DocumentInventoryTests | Done (2026-10-28): `PdfCore/Redaction`: `DocumentInventory` (scripts with their trigger and what they call, actions that run by themselves, every address, file and program reachable and whether without a click, attachments, metadata and comment authors, signatures, earlier versions and the text they still show, hidden layers, comments, fields and text, form values, covers that hide nothing; each item says whether Sanitize removes it) and `InventoryReportFiles` (the web page, no scripts; JSON with the format marker, fields in a fixed order); Sanitize's XMP reading shared (`Sanitizer.xmpProperties`). 8 tests (471 in the package, 0 warnings on `ignia-mac`): the Windows file with the same names, InventoryBatchTests left out (E8); its header says what was adapted. The app: Tools › What's in This PDF… and See What's in It… in the Sanitize sheet (progress and Cancel, then a sheet: the summary, each section with its items, Go to page, Save Report… as a web page or JSON, Copy Report, Sanitize… when there is something to remove). `RedactTest` adds 10 checks (the report as `DocumentInventory` lists it, saved as HTML and JSON and read back, Go to page, Sanitize… and See What's in It…, the report after Sanitize): 31 on the two synthetic documents with `--only-redaction`; the whole `--edit --synthetic --quit` run, 170 checks, all pass (AppTest's What's New check, failing since 1.1.0's notes came first, now reads the newest notes and 1.0.0's) |
| E2 | Digital signatures: verify (the Signatures pane, the bar), Sign Digitally | Core2SignatureTests, IncrSignatureTests, SignatureChangeTests, SigningTests | Done (2026-10-30): `PdfCore/Signatures`: `Signatures` (verify on the raw bytes: the /ByteRange, the hex-only gap, adbe.pkcs7.detached, ETSI.CAdES.detached, adbe.pkcs7.sha1, ETSI.RFC3161; embedded RFC 3161 timestamps that must belong to the signature; trust through `SecTrust` at a trusted timestamp's time, else now; key usage and EKU), `SignatureChanges` (the signed revision against the current file object by object, DocMDP and FieldMDP), `Signing` (the field and its appearance, /ByteRange and /Contents placeholders appended by MuPDF and patched, the CMS written by PdfCore and signed by the ID's `SecKey`; PKCS#7 or CAdES, certification, locks, timestamps), `DigitalIds` (Keychain identities, .p12 import, personal IDs made in the login keychain); `Der`, `Certificates` and `Cms` stand for .NET's `System.Formats.Asn1` and `Pkcs`. The edit transaction asks before an edit breaks a signature (`signedOnOpen`, `confirmBreakingEdit`, with ASignedFileAsksBeforeAnEditBreaksItsSignature), and Batch's signed files are the ones that verify as signed. The app (`DigitalSigning.swift`): the sidebar's Signatures pane (a card per field: status, details, Go to Signature, Sign This Field…), the notice bar's summary after every change, View › Show Signatures (⌥⌘4), Tools › Sign Digitally… (also in the Signature tool's menu, and a click on an empty signature field): the dialog (digital ID from the keychain, Create a Personal Digital ID…, Import a Digital ID File…, reason, location, the look, a timestamp server, certification; the choices kept in the settings under the Windows names), a box dragged on the page, the signature as one edit, then the signed copy saved as "name-signed.pdf" (not saved: undone). 34 tests and one more in EditTransactionTests (594 in the package, 0 warnings on `ignia-mac`); the app's `--edit --synthetic` self-test adds `SignTest` (10 checks, all pass: the box dragged, Sign Digitally through the window's own flow, the copy saved and verified, the pane, a comment after signing, a page deletion declined). Signing with a real Keychain identity wasn't exercised over SSH (macOS asks for the key's password on the screen): the tests and the self-test sign with IDs made in memory |
| E3 | Compare Files | CompareTests | Done (2026-10-30): `PdfCore/Compare`: `WordDiff` (patience anchors, then Myers within its edit and work budgets; `slide`, `merge`), `CompareWords` and `DocumentCompare` (words on UTF-16 offsets with NFKC keys, numbers and words hyphenated at a line break kept whole; the whole documents diffed, then pages lined up by the words they share; a removed or inserted page is one change; pages without text flagged), `VisualCompare` (the overlay: shared ink grey, only in the original red, only in the changed file blue, the regions that differ grouped) and `CompareReport` (the annotated copy). The app (`Compare.swift`): File › Compare Files… (the original and the changed version: an open document as it is now, or any PDF, its password asked; Swap), the Compare window: the summary, the list of changes (a color chip, the pages, the words; ⌘[ and ⌘], Previous and Next), rows of lined-up pages side by side under one scroll bar with the changes marked on both sides (a bar where words went missing on the other side; a click on a mark selects it), Text or Visual (the overlay per row, the regions boxed), pages without text compared by their pixels in the background and listed when they differ, Annotated Copy (a new unsaved document). 29 tests (623 in the package, 0 warnings on `ignia-mac`); the `--edit --synthetic` self-test adds `CompareTest` (7 checks, all pass: two versions made by the app compared, the list, stepping, both Visual overlays, the annotated copy). Not yet: zoom (the rows fit the window's width), the start page card |
| E4 | Reduce File Size, Flatten, Header & footer, Watermark | OptimizerTests, FlattenTests, HeaderFooterTests, WatermarkTests | Done (2026-10-30): `PdfCore/Finishing`: `PageMarks` (removable page content, q/Q balanced), `Watermarks`, `HeaderFooter`, `Flattener`, `Optimizer` (with `ContentImages`; images resampled by MuPDF through a one-image page, JPEG through `saveImage`). The app: File › Reduce File Size…, Pages › Add Header & Footer…, Remove Header & Footer, Add Watermark…, Remove Watermark, Flatten… (`Finishing.swift`), each one edit through `DocumentEditor.run`. 32 tests, all passing on `ignia-mac` |
| E5 | Prepare Form: the field kinds, placing, moving, resizing and editing fields, their properties, Tab order, Detect Fields | FormDesignTests, FieldDetectionTests | Done (2026-10-30): `PdfCore/Forms`: `FormDesign` (fields read, added, changed, moved, deleted and ordered, real appearances through `FieldAppearance` and `ButtonFaces`; `NameBook` for names picked in a row), `VectorShapes` (the rectangles and rules a page draws, over `ContentLexer`), `FieldDetection` and `RectGrid`, and `FormDesigner` and `FormDesignRules`, which keep the Windows viewer's and tab's rules in PdfCore so they are tested (FormDesignerTests, a Mac addition). All of FormDesignTests and FieldDetectionTests ported with the same names, ShapeDetectionReadsAFormDrawnManyTimesOnce added to HostileStructureTests, one Mac addition each for the list box default below and a form made on Windows (opt-in, `INKVOLTPDF_WINDOWS_FORM`): 700 tests in the package, all pass, 0 warnings on `ignia-mac`. The app (`PrepareForm.swift`): Tools › Prepare Form (⌥⌘F) and Detect Form Fields, the field tools bar over the pages, the properties panel on the right (a split view inspector), every property as on Windows, suggestions dashed on the page, each change one undo step through `DocumentEditor.run`; free, as on Windows: no `Pro.allows`. The `--edit --synthetic` self-test adds `PrepareFormTest` (`--only-prepare-form` runs it alone): 46 checks through the page view's own mouse and keys and the panel's own controls, all pass on `ignia-mac`. Crossed: a form made by the Mac's self-test read, filled and changed by the Windows code (`FormDesign.Read`, `FormEditor.SetValues`, `FormDesign.Update`, on the Windows PC) and read, filled and saved by Apple's PDFKit (on `ignia-mac`); a form made by the Windows code read, filled and moved by the Mac's. Not checked: Acrobat. See "Prepare Form (E5)" under Mac differences for what a person must look at |
| E6 | Measure: distance, perimeter, area, Calibrate, Set Measuring Scale | MeasurementTests | Done (2026-10-30): `PdfCore/Annotations/Measurement.swift`: `MeasureGeometry`, `MeasureScale` (`from`, `calibrate`, `parse` for .NET's `TryParse`, the values and their "N2" text), `Measurements` (page viewports read, looked up per point and written first on the page as "Inkvolt PDF scale", measurements added as Line, PolyLine and Polygon comments with /Measure /RL and /IT LineDimension, PolyLineDimension, PolygonDimension, read back with their values, /UserUnit applied); `Annotations.apply` draws the white-backed Helvetica label and sets /Contents, /IT and /Cap whenever a measurement is drawn or reshaped, so a measured file reads the same on both platforms (the same entries and label as Windows writes). `MeasureDraft` (a measurement under way: clicks, the pointer, Shift, double-click, Return, Delete, Esc, the value so far) and `MeasureScales` (a version's scales read once) keep the Windows viewer's and tab's rules in PdfCore, tested by MeasureDraftTests (a Mac addition). 11 tests ported with the same names and 7 added (641 in the package, 0 warnings on `ignia-mac`). The app (`Measure.swift`): Tools › Measure › Measure Distance, Measure Perimeter, Measure Area, Calibrate Scale from a Known Length (tools without a key, as on Windows) and Set Measuring Scale… (a sheet: on the page = real, decimals, this page or all pages); the page view draws the measurement under way with its value by the pointer (a tracking area follows the pointer); each measurement is one undo step at the page's scale, said in the notice bar ("Area: 0.50 sq in, perimeter 3.41 in (scale 1 in = 1 in)."); Calibrate asks the real length of the line just drawn. Free, as on Windows: no `Pro.allows`. The `--edit --synthetic` self-test adds `MeasureTest` (`--only-measure` runs it alone): 11 checks, all pass on `ignia-mac` (each tool through the page view's own clicks, pointer moves and keys, both sheets through their own completion, a reshape, undo, the label drawn and the viewport read back; it runs before `SignTest`, since a signed document declines the scale's page edits); the whole `--edit --synthetic --quit` run, 198 checks, all pass. Not checked by anyone at the screen yet: see "Measure (E6)" under Mac differences for what a person must look at |
| Pro | Inkvolt Pro: the licence key, its check, Help › Inkvolt Pro… | ProTests | Done (2026-10-30): `PdfCore/Pro`: `Pro` (the gate, off as on Windows, with the same flip trigger), `ProKeys` (the key format verified with CryptoKit `P256.Signing`; `issue` for tests), `MemoryProStore`; the app's `ProWindowController` (both copy states, Get Inkvolt Pro ($19), Enter Key, Remove Licence) with the key in the settings (`SettingsProStore`). ProTests (16) read `pdf/tools/pro-key/test-vector.json` in place |
| E8 | Batch, with presets, watched folders and the command line (roadmap 1.2) | BatchTests, BatchAutomationTests | Done (2026-10-30): `PdfCore/Batch`: `Batch` (files, names, the steps, the plan, `BatchRunner` on a task group with an `AsyncSemaphore` and the `WeightedGate`, `OutputNames`), `BatchPresets` (the Windows JSON, byte for byte, read with JSON5 comments and trailing commas allowed), `BatchCommandLine` (`--batch`, `--watch`, `--help`), `WatchedFolder` (held files and the watcher's lock through flock); `PngDecoder` for a preset's watermark picture. The app: File › Batch… (`BatchWindowController` and `ActionSheet`: the files, the actions with their sheets, the results folder and names, passwords asked per file, Stop, presets in Application Support and as files behind the Pro seam), Watched Folders… (`FolderWatches` started with the app, `WatchedFoldersWindowController`), the start page's Batch card, `InkvoltPdf --batch` and `--watch` from a terminal (`CommandLineRun`). Not on the Mac yet: the Check Accessibility and Save as PDF/A actions (1.3, E7), comment exports and summaries and form data as CSV or JSON (1.4), `--fill` (1.4). 38 tests |

### Parity with Windows

Decided 2026-10-27 with the owner: Inkvolt PDF on the Mac reaches full parity with the Windows app (and Inkvolt Print
already has it, but for HP's clean-up tool, which has no macOS counterpart), so a person, an office or a school picks
the platform, not the features. 1.0 is the first stage and goes public when D2-D8 are done (decided 2026-10-27: release at 1.0, saying that more is
coming; a notarized DMG needs no App Review, only notarization); the E-steps after it bring every other Windows feature. From the
roadmap (`pdf/ROADMAP.md`) on, a feature counts as done only when it ships on both. One Inkvolt Pro key (the same
signed format) unlocks Pro on both, and a business licence covers both.

| Windows feature (`pdf/README.md`, "Using it") | Mac |
|---|---|
| Windows 11 look, tabs, start page, reading modes, side rail, find, tools, command palette, settings | D7 (a native macOS look) |
| Bookmarks, organize pages, page edits, new PDFs from images | D3 (done in Core) |
| Comments, draw, stamps, images, links | D4 |
| Forms and Fill & Sign | D5 |
| Edit Text & Images | D5a |
| Recognize Text (OCR) | D5b (Vision) |
| Export to Word, Excel or text | D5c |
| Reload, recovery copies, password protection | D2 (done in Core) |
| Print (with pages per sheet, booklet, poster) | D6 (done in Core) and D7 |
| Scan, printer status when printing, Inkvolt Print's printer settings | Scan: D7 (Inkvolt Print's PrintCore and PrintMac: eSCL, Bonjour, ImageCaptureCore); printer status and printer settings later, with the printer reading |
| Help › What's New, updates | What's New: D7; updates: D8 (Sparkle) |
| Redaction (with redaction by pattern), Sanitize Document | E1 (done 2026-10-28; Batch's two redaction actions with E8, 2026-10-30) |
| What's in This PDF | E1a (done 2026-10-28; Batch's Report What's in Each File with E8, 2026-10-30) |
| Signatures (verify), Sign Digitally | E2 (done 2026-10-30; Security.framework; identities from the Keychain) |
| Compare Files | E3 (done 2026-10-30) |
| Reduce File Size, Flatten, Header & footer, Watermark | E4 (done 2026-10-30) |
| Prepare Form | E5 (done 2026-10-30) |
| Measure | E6 (done 2026-10-30) |
| Save as PDF/A-2b | E7 |
| Batch (with presets, watched folders, the command line) | E8 (done 2026-10-30; the Check Accessibility and Save as PDF/A actions come with 1.3 and E7, comment exports and `--fill` with 1.4) |
| Help › Inkvolt Pro… | Pro (done 2026-10-30) |
| Attachments, Layers | E9 |
| Read Aloud | E10 (AVSpeechSynthesizer) |
| AI assistant (bring your own, off by default) | E11 |
| PDF from Office files and web pages | E12 (web pages through WebKit; Office files through Word for Mac or LibreOffice when installed) |
| Split view | E13 |
| Better OCR, stage A (roadmap 2.2: cleaning before recognition, suspect words, writing the cleaned page back) | E14 (below) |
| Export to PowerPoint and HTML (roadmap 3.2) | E15 (below) |

Mac differences for the PDF app (so far):
- Errors are Swift errors: `PasswordRequired(wrongPassword:)`, `PdfEngineError` (MuPDF's message, or an image too
  large), `PdfEngineClosed` for .NET's `ObjectDisposedException` (`close()` takes `Dispose()`'s place), and
  `CancellationError` when a `CancelToken` (.NET's `CancellationToken`) fires.
- Rendered pixels are RGB, not BGR.
- `PageText` keeps .NET's UTF-16 offsets (carets, matches and boxes per UTF-16 unit); search is Foundation's
  (`NSString` with case and diacritic insensitivity, canonical equivalence) where .NET uses the invariant culture's
  `CompareInfo`, so match lengths come from Foundation.
- The engine talks to MuPDF directly (through the shim), so the Windows workarounds for MuPDFCore (finalizers that
  crashed the process, reflection for abortable renders and freeing pages) have no Mac counterpart, and their tests
  aren't ported. Text comes from the page's content without annotations, as MuPDFCore's `includeAnnotations: false`.
- `PdfEngine.isEncrypted` means "needs a password to open", as on Windows; `DocumentSession.hasEncryption` sees an
  encryption dictionary (a file that only restricts printing or copying).
- Saving an edit: MuPDF appends a signed file's edit as an incremental update (an encrypted signed file too, which the
  Windows app has to rewrite, so the "encrypted signed file" warning and its test don't apply), and writes anything else
  whole with `garbage=compact,encrypt=keep`: the encryption stays exactly as it was (method, permissions, both passwords,
  the file ID), where Windows re-encrypts with PDFsharp and upgrades RC4 to AES-128. So an edit never needs the open
  password, `OpenPasswordUnknownException` and the transaction's open-password question have no Mac counterpart, and
  `KeptProtection.run` only drops an open password on request. MuPDF's write options are comma-separated, so a password
  for Protect can't hold a comma.
- A signed file with junk after %%EOF (more than MuPDF searches for its last startxref) is read up to its last valid
  `startxref … %%EOF` (`PdfEdit.lastEnd`), and the update goes after all of the original bytes.
- Recovery copies' descriptions are Swift JSON (dates in ISO 8601), as Inkvolt Print's recovery lists.
- Page edits use MuPDF's graft map to bring pages across documents (their annotations copied after), reorder by taking
  every page out of the page tree and putting them back in order, and write XMP into the Metadata stream before saving
  (Windows patches the saved bytes). Extract writes a new, unencrypted file. Every refusal is a `PdfEditError`.
- A page number past the end throws `PdfEngineError` (Windows' engine would throw too; the app relies on it).
- Text in stamps, free text and other appearances is shaped by Core Text (one line layout gives bidi, font fallback and
  shaping, and reads AAT, CFF and font-collection fonts) and embedded as Type 3 fonts drawn from Core Text's glyph
  outlines, with a ToUnicode entry per glyph so it stays searchable; Windows embeds subset TrueType (CIDFontType2)
  through HarfBuzz. No subsetter is needed; small text may look less crisp in other viewers (no hinting). The text code
  is `PdfCore/Text`, not `PdfMac/Text` as the module map has it. MuPDF keeps numbers as 32-bit floats, so colors read
  back rounded to 4 decimals; link addresses go through our own parser (with punycode) where .NET uses `Uri`; stamp
  dates follow a given `Locale`.
- Form scripts: JavaScriptCore has no public time limit, so its watchdog (`JSContextGroupSetExecutionTimeLimit`, a
  private API declared in the `ScriptLimits` C target) stops a script after 0.5 s of CPU (2 s per run); fine for a
  Developer ID app (no App Review), but Apple may change it: the fallback is running scripts on a thread that is abandoned
  when late. No heap limit: the prelude caps arrays at 100,000 items and strings at 1 M characters. The host's submit
  answers yes or no (Windows: a task); dates are matched by our own parser (Windows: .NET's); XFDF with a DTD is
  refused. The code is `PdfCore/Forms`, not `PdfMac/Scripts`.
- The tests write their PDFs by hand (`TestPdf`, `Core1TestPdf`); encrypted ones are written by MuPDF (AES-256), where
  the Windows tests use PDFsharp.
- The app (D7 part c): Fill & Sign's signatures and initials are kept only while the app runs (Windows keeps a library
  of saved ones); form data goes in and out as XFDF and FDF only (Windows also CSV and JSON), through
  `FormEditor.resetForm`, `exportData` and `importData`, which have no .NET counterpart file (their tests:
  FormDataExchangeTests); a choice field opens as a menu under the field (Windows: a drop-down editor); messages the
  Windows app shows as notifications go to a bar over the pages.
- The app (D7 part d): the close and quit questions are AppKit's (NSDocument: Save, Don't Save, Cancel for each document;
  quitting with several changed documents first offers to review them); the self-test answers them through the same
  callback (`PdfDocument.testCloseAnswer`). Printing goes through `NSPrintOperation` and the standard panel (printer,
  copies, paper, orientation, preview) with Inkvolt's options in its accessory view (the document's page range, one page
  per sheet at actual size or fitted, pages per sheet, booklet, poster); each page is drawn as a 300 dpi picture from
  MuPDF placed by `PrintPlan` (vector printing would need MuPDF drawing into Core Graphics). Pages larger than 16
  megapixels at the zoom shown are drawn in 512-pixel tiles of the part in view over a 16-megapixel picture of the page.
  Links open as on Windows: a page or web and mail addresses at once, any other address after "Open this link?". New
  bookmarks go after the one selected and are named in a sheet (Windows edits the title in the list). Extract writes one
  PDF (opened in a tab unless unticked); Windows also offers a file per page. Mac additions (not on Windows yet): the
  Polygon and Polyline tools, and moving and recoloring sticky notes and text marks (`Annotations.move`,
  `Annotations.setColor`, CommentMoveTests). A text mark over a selection across pages is one undo step.
- The app (D7 part e): the start page is a window of its own (Windows: the main window's page while no tab is open) that
  steps aside when a document opens; its recent list offers Open and Show in Finder (AppKit keeps the list, so no Remove
  from List). Combine Files is a window (Windows: a dialog). Scans, combined files and PDFs from pictures or the clipboard
  open as unsaved documents named with the date (Save asks where), as Windows' new tabs. Scan finds scanners through
  Bonjour (`_uscan`, `_uscans`, listed in `NSBonjourServices`; Local Network asks the user once) and ImageCaptureCore for
  USB, not from the printers Inkvolt Print remembers (they live in its sandbox container); "Make the text searchable"
  runs Recognize Text on the new document (its own undo step), where Windows adds the layer before opening; each scanned
  JPEG gets the scan's resolution in its JFIF header, so `ImageImport` makes the page its real size. Settings leaves out
  what the Mac doesn't have (dark pages; reopening the last files, which macOS's window restoration does; the AI
  assistant) and says how to make Inkvolt PDF the default PDF app (Finder's Get Info) instead of a Default apps button;
  "Open documents at" (fit width, fit page, actual size) is the Mac's, where Windows reopens with the last zoom mode;
  update checks are Sparkle's automatic checks. The command palette is ⇧⌘K (⌘K is Link Selected Text, ⇧⌘P Page Setup)
  and lists the menu bar's own items, each checked along the front window's responder chain. The self-test keeps its
  settings in a defaults suite of its own.
- Redaction (E1): the user's own pattern is ICU's regular expression syntax (NSRegularExpression), where Windows reads
  .NET's (the common syntax is the same; .NET-only constructs such as balancing groups aren't); NSRegularExpression's
  error says only that a pattern can't be read, not where, so a parenthesis or bracket without its partner (the usual
  mistake) is found by a scan of our own and pointed at ("near character N", as Windows' .NET offset), and any other
  mistake is said to make the pattern unreadable, with what it might be (no position; Windows gives .NET's reason and
  offset). The time limits (1 s for the user's pattern, 2 s
  for a built-in one, per page) stop a match through NSRegularExpression's progress callback (.NET: its match timeout),
  reported as `RedactionSearchTimeout`. After Apply, recognized words that reach into a blacked-out area at all are
  dropped (Windows: those mostly inside one), so no letter of what the recognizer saw or guessed at the edge of a box is
  laid over the black.
- The redaction check (E1): MuPDF tells the Mac which characters are drawn invisibly (render mode 3, as an OCR layer;
  `PageText.isInvisible`, from the shim's character flags), which Windows' MuPDFCore doesn't: such text counts as covered
  only over a dark area (a box burnt into a picture with the old words kept invisibly), not over the paper of a scan or a
  redacted page, where an OCR layer's estimated letter boxes often fall between the letters. The pages' text is read
  first, then the pages walked and drawn (Windows reads it on another thread meanwhile). Attached ZIP (Office) files are
  read by a small reader of our own over the Compression framework, as are zlib streams in the raw bytes.
- Sanitize Document (E1): with metadata chosen, the properties and the document's XMP packet go altogether (Windows
  writes a bare packet naming PDFsharp). The new file identifier is written with MuPDF's `regenerate-id=no` (else MuPDF
  puts a second half derived from the old one back); an AES-128 or RC4 file, whose key is made from the identifier, is
  encrypted again with the new one when its open password is known (none, or given through `KeptProtection.run`), else
  the identifier stays and the report says so; AES-256 keeps its encryption as it is. MuPDF 1.25.2 draws optional
  content membership dictionaries with /P AllOn and AnyOff the wrong way round (it shows what they hide); the Sanitizer
  follows the specification, so content an AllOn dictionary hides goes, and the MembershipDictionaries test checks the
  result only, not MuPDF's view of the original.
- The app (E1): the Redact tool's key is F (Windows' tool has none); marks are drawn dark with a red edge and stay until
  applied or cleared (dropped if their page goes); the redaction bar, Redact by Pattern, the redaction check's report
  and Sanitize Document are a bar over the pages and sheets on the window; Redact Selected Text, Redact Search Matches,
  Apply Redactions…, Clear Redaction Marks, Check Redaction… and Sanitize Document… are in the Tools menu (Windows: the
  Review tab), the first also in the selection's context menu. Apply asks first (as Windows), then recognizes the text
  left on the pages with Vision in the same undo step; the self-test answers the question itself
  (`Report.isRunning`).
- What's in This PDF (E1a): the Mac has no Document Properties window, so the report is opened from the Tools menu and
  the Sanitize sheet only (Windows: also from Document Properties). Attached files are listed by the inventory's own
  reading of the EmbeddedFiles tree and attachment comments (Windows calls `Attachments.List`, which comes to the Mac
  with E9). The sheet shows at most 300 items per section, with how many more there are (Save Report lists them all;
  Windows' dialog lists all, up to the report's 2,000). The JSON writes characters beyond ASCII as they are, in UTF-8
  (Windows' writer escapes them as \uXXXX); its fields and their order are the same. A PDF date without a time zone is
  shown with this Mac's offset (Windows: +00:00).
- Headers, footers and watermarks: dates in `HeaderFooter.expand` are written by `DateFormatter` (`HeaderFooter.invariant`,
  en_US_POSIX, for the Windows tests' invariant culture: MM/dd/yyyy and HH:mm); text in other scripts is embedded as
  `TextPainter`'s Type 3 fonts (Windows: one Type 0 font). `Optimizer` resamples an image by drawing a one-image page with
  `PdfEngine` (JPEG at MuPDF's quality: `jpegQuality` is kept for the preset and ignored) and counts duplicate streams by
  an FNV hash of the bytes plus the dictionary; an AES-256 file keeps its open password through the rewrite without it
  being known (no `OpenPasswordUnknown`).
- Batch: a file counts as signed when a signature verifies as one (not an empty field); a "%PDF-" file MuPDF opens
  without pages fails as "This PDF has no pages"; result names follow the Windows rules (no `< > : " / \ | ? *`, no
  device names, 120 characters) so results move between the two. Presets refuse `checkAccessibility` and `saveAsPdfA`
  by name, saying they are Windows-only for now. The watched folder takes a file only when `open` with `O_EXLOCK` gets
  it (an app that locks what it writes keeps it off; the quiet period covers the rest) and holds `.inkvolt-watch.lock`
  with flock. The command line is the app's binary (`/Applications/Inkvolt PDF.app/Contents/MacOS/InkvoltPdf`);
  `--fill` isn't there (FormMerge comes with 1.4).
- Inkvolt Pro: the licence's issue date is kept as its `yyyy-MM-dd` text (`issuedDate` for showing it); the key is
  verified with CryptoKit (the one Apple framework PdfCore imports besides Foundation).
- Compare (E3): words are offsets in UTF-16 units of `PageText.text`, as .NET's string indices are; the categories come
  from Unicode scalar properties and the keys from `precomposedStringWithCompatibilityMapping` (NFKC). The overlay works
  on the Mac's RGB renders. The window fits the rows to its width (no zoom yet) and draws the pages on a queue of its
  own, keeping only the pictures near the ones shown.
- Signatures (E2): PdfCore reads and writes the CMS itself (`Der`, `Cms`: what .NET's `SignedCms` and
  `Rfc3161TimestampToken` do) and leaves the cryptography to Security.framework: `SecKeyVerifySignature` with the
  certificate's key, `SecKeyCreateSignature` with the ID's (so a smart card's key never leaves it), `SecTrust` for the
  chain. Trust is the Mac's: the system roots and the user's keychains ("trusted by this Mac"); the chain problems are
  named as .NET names them (UntrustedRoot, PartialChain, NotTimeValid, Revoked, RevocationStatusUnknown), each found by
  judging the chain again inside the certificates' validity. Digital IDs are Keychain identities: a personal ID is made in
  the login keychain (its backup is Keychain Access's .p12 export, not a .pfx Inkvolt writes, so PersonalIdBackupUses-
  ModernEncryption has no Mac counterpart), and a .p12 file is imported there (macOS keeps imported identities in a
  keychain). MuPDF writes "/Contents<…>" without a space; the tests find the gap after "/Contents". A signature
  dictionary MuPDF can't read (something slipped into it) is reported as invalid, where PDFsharp's failure made Windows
  scan the raw bytes. The timestamp is off by default, as on Windows (the server gets a hash of the signature only).
- Measure (E6): the commands are in Tools › Measure (Windows: Review › Measure), and the tools aren't in the tool strip
  (the command palette lists them). The measurement under way and the scale lookup are PdfCore's `MeasureDraft` and
  `MeasureScales` (Windows keeps them in `PageViewer.Measure` and `DocumentTab.Measure`, untested), so their rules are
  tested on the Mac only (MeasureDraftTests). Esc with nothing under way goes back to Select Text, the Mac's default tool
  (Windows: Hand). Set Measuring Scale and Calibrate are sheets (NSAlert with the fields); a length that isn't a number
  is refused with an error once the sheet closes (Windows' dialog stays open). The notice bar's Undo undoes the last step
  (Windows' toast undoes only a measurement). MuPDF keeps reals as 32-bit floats: /C reads back to about seven digits and
  points to four decimals, and the scale's exact value comes back from its /R ratio, as on Windows. The Windows dev
  script's `setscale`, `measure` and `measurements` are the self-test's `MeasureTest` and `measurementsReport()`. What a
  person must look at on the screen (nobody has yet; SSH shows no screen): the Measure submenu; each tool's crosshair,
  segments, dots, the area's light fill and dashed closing edge, and the dark value box by the pointer following a real
  mouse (also at 50 % and 400 % zoom, in dark mode); Shift's 45° steps with a real mouse; both sheets' layout and focus;
  the labels on the page (white-backed, upright on a turned page); and a file measured on the Mac opened in the Windows
  app and in Acrobat (the entries match the Windows tests', but no file has crossed yet).

- Prepare Form (E5): the commands are in Tools (Windows: Edit › Forms; ⌥⌘F for Ctrl+Alt+F), Detect Fields is also Tools › Detect Form Fields, and there is no start page card, as on Windows. The bar
  sits over the pages and the panel is a split view inspector (Windows floats both). The rules of clicks, drags, keys and typed values are PdfCore's `FormDesigner` and `FormDesignRules` (Windows keeps them in
  `PageViewer.FormDesign` and `DocumentTab.FormDesign`, untested), so they are tested on the Mac only (FormDesignerTests). ⌘D duplicates the selected field while the pages have the focus; without one it is Add Bookmark, as
  the menu says. Esc with nothing to let go goes back to Select Text, the Mac's default tool (Windows: Hand). The view doesn't turn on the Mac yet, so moves, handles and arrow keys work in page space (Windows goes through
  `RotatedView`). A list box whose /DV is an array keeps it and its value when moved or otherwise changed; on Windows `SetDefault` clears both (reported, not fixed there; aListBoxWithSeveralDefaultsKeepsThemWhenMoved). A failed
  move or property change says why in the usual error sheet (Windows' `quiet` edit a toast). `uniqueName` and `nextName` go through `NameBook`, which keeps its place, so a page of 3,600 check boxes is named in moments;
  Swift compares names by canonical equivalence where .NET compares ordinally. The tests draw in the built-in Helvetica through content streams (Windows: XGraphics with embedded Arial): MuPDF's boxes for it are taller, so an
  underscore field's bottom may reach 109 (Windows: 106). SignedFilesGetFieldsAppended uses `Core2SignatureTests.signed()`, which verifies, since the Mac's `SignedEditTests.signed()` has an empty signature. What a person must look
  at on the screen (nobody has yet; SSH shows no screen, and the self-test's snapshots show AppKit's drawing, not a real window): the bar's and the panel's layout at the window's smallest size and in dark mode; the tool icons; each
  cursor over fields and handles; dragging with a real mouse at 50 % and 400 % zoom; the field names, handles and Tab numbers at those zooms; Return, Esc and Tab in the panel's text boxes; VoiceOver's announcements; Detect Fields'
  sheet and Cancel on a long scanned form; and a form made on the Mac opened in the Windows app's window and in Acrobat.

E14, Better OCR stage A (Windows 2026-10-30; after E13, as the roadmap queues new items behind the E-steps). What to port:
- **Image cleanup**, `shared/InkvoltPrint.Core/Imaging/ScanCleanup.cs` (`ScanCleanup.Clean`, `SkewOf`, `Turn`, `Smooth`,
  `PaperLevel`, `Despeckle`, `Upright`) and `Deskew.Measure` in `Imaging/PageImage.cs` (the angle and the line strength;
  Print's `Deskew.Angle` is it with 10°). Plain loops over grey bytes with no Windows types, so it ports to Swift as is
  into PrintCore (the module map's `Imaging/PageImage` row) and PdfCore uses it from there. Core Image may replace
  `PageRotate` (`CIAffineTransform`, white behind) and the median (`CIMedianFilter`), never the decisions (skew, sideways,
  upside down, specks), which must stay ours so the tests mean the same. Vision's `VNDetectTextRectanglesRequest` can't
  replace `Upright` (it finds boxes, not which way up); `VNRecognizeTextRequest` reads upright text only, so the turn is
  needed on the Mac too.
- **Pipeline**, `pdf/src/InkvoltPdf.Core/ScanText.cs` (`RecognizeOptions`, `RecognizedPage`, `CleanedPageImage`,
  `ScanText.Recognize`, `ScanFrame`), `SuspectWords.cs`, `ScanPage.cs` (write-back) and the text layer's additions in
  `TextLayer.cs` (turned words, the `%InkvoltOCR 1 <lang>` comment lines and `Words`, `Correct`, `Keep`; keep the format
  byte for byte so a file corrected on one platform is reviewed on the other). The recognizer seam is
  `shared/InkvoltPrint.Core/Imaging/TextRecognizer.cs` (`ITextRecognizer`, `ISpelling`): the Mac's are Vision
  (`VNRecognizeTextRequest`, `.accurate`, `recognitionLanguages` from the language chosen) and `NSSpellChecker`
  (`checkSpelling(of:startingAt:language:wrap:inSpellDocumentWithTag:wordCount:)`, `guesses(forWordRange:…)`). Vision
  returns lines; split them into words with `VNRecognizedText.boundingBox(for:)` per word range (Windows gets words).
- **Confidence**: Vision gives a `confidence` per recognized string (a line's candidate, coarse values), not per word,
  and `topCandidates(_:)` alternatives per line. So the Mac keeps the same suspect-word heuristic and names (never a
  score); a line's alternatives that differ at a word may be added as one more reason, like ReadDifferently.
- **Tests to port**: ScanCleanupTests, ScanTextTests, SuspectWordsTests, OcrCorpusTests (pdf/tests/InkvoltPdf.Tests),
  with the same expectations: the corpus pages straightened within 0.3°, upright, the stand-in recognizer's heading placed
  at the same place and angle (−176.9°).
- **Corpus**: `pdf/tools/ocr-corpus` (ScanCorpus.cs, WordErrorRate.cs) ports as is; MuPDF's built-in fonts make the same
  pixels on the Mac, so the SHA-256s in its RESULTS.md must match the Mac's corpus. The roadmap's test (word error rate
  lower than with no cleaning, on every file) is run with Vision and written beside Windows' numbers.
- **The app**: Recognize Text's sheet gets the language, the two checks and "Replace the scans with the cleaned pages";
  a Suspect words list in the sidebar (each word beside its picture, Correct to with `NSSpellChecker`'s guesses, Keep as
  read), as on Windows.
E15, Export to PowerPoint and HTML (Windows 2026-10-30; after E14, on the Word export of D5c). The .NET code is the spec. What to port:
- **Writers**, `pdf/src/InkvoltPdf.Core/PptxWriter.cs` and `HtmlWriter.cs`: strings, XML and zip, with no Windows types. The
  master, layouts and theme in `PptxWriter` are fixed text: keep them byte for byte. `OpenXmlParts.Relationships` moved out of
  `DocxWriter` so both writers share it.
- **Layout**, `DocLayout.AnalyzeSlides` and `SlidePage` in `DocLayout.cs`: every line stays on its page, and running lines are
  only marked.
- **Shapes**, `ExportShapes.cs` (`ExportShape`, `ExportPath`, `ExportShapes.Read`, `Raster`): pure logic over a path's bounds,
  stroked flag and color, plus an RGBA rendering of the page at 2 pixels per point. `PdfEngine.GetExportPage(shapes:)` is the
  part to mirror on the Mac's MuPDF: collect the vector blocks' color with their bounds, leave out paths in a figure, render
  the page once if `NeedsRaster`, and add `Pictures` as rendered pictures.
- **Tags**, `ExportTags.cs` and `AutoTag.FigureAlts` (role map, inherited page, attribute lists, tags without a box).
- **Seam**, `DocumentExport.cs`: `ExportFormat.PowerPoint` and `.Html`, `ExportOptions.Source` and `.SourcePassword`, `WritePptx`,
  `WriteHtml`, and the additions `ExportPage.Shapes`, `ExportImage.Alt`, `ExportImage.Turn` (set by `Turned`).
- **Batch**, `BatchExportFormat.PowerPoint` and `.Html`: they come after `CommentSummary`, so `IsReview` is a range.
- **Platform-specific**: the menu items and save panel; opening the PDF for its tags (`ExportTags.Read` uses PDFsharp here; the
  Mac returns the same page, box and text from what it reads structure with); `run.ps1`'s PowerPoint check (COM). On the Mac open
  the corpus's .pptx in PowerPoint for Mac by hand, or use `soffice --headless --convert-to pdf`.
- **Tests to port**: ExportPptxTests, ExportHtmlTests, `BatchTests.ExportsToPowerPointAndHtml`, and the PowerPoint and HTML cases
  in ExportPipelineTests and BatchAutomationTests. Their expectations are platform-neutral: counts, text, order, positions in
  EMU to the point, colors. They read a .pptx with the Open XML SDK, which has no Swift version: read the zip and XML directly,
  and run the SDK's validator on Windows over files the Mac wrote (`ExportCorpus pptx file.pptx`).
- **Corpus**: `pdf/tools/export-corpus/corpus.json`, the same 7 documents, SHA-256s in `baseline.json`. `ExportCorpus html` and the
  Nu validator (`vnu.jar`, Java, local) work the same on the Mac; compare each document's slide and shape counts and lines in order
  with a Windows run.

Decided 2026-10-30 for E2: PdfCore imports Security.framework (with CryptoKit and Vision, already there) rather than
taking the CMS through a protocol from the app: the tests need the real verification, and Security is the Mac's
System.Security.Cryptography. The Keychain is touched only by `DigitalIds.keychain()`, `createPersonal(inKeychain: true)`
and `importP12`, which the app calls and the tests don't.

Decided 2026-10-27 for the PDF app:
- MuPDF 1.25.2, the Windows app's version (the same rendering); both apps move to a newer one together.
- Form JavaScript on JavaScriptCore: `JsPrelude` (already JavaScript) carried over, `JsFormHost` ported to JavaScriptCore,
  so forms behave as on Windows, the Windows tests apply and the host's consent prompts stay (MuPDF's mujs is ES5 and
  its own object model).
- Updates through Sparkle 2, with the appcast and the DMGs on GitHub Releases of the inkvolt repo (no server of our own;
  the source the AGPL asks for sits beside them). Sparkle's update check sends no system profile (the privacy rule).
- Developer ID: Apple lets only the Account Holder create the certificate (the API refuses), so `devid-cert.sh request`
  makes the key and signing request on `ignia-mac`, the owner uploads the request in the developer portal, and
  `devid-cert.sh import` keeps "Developer ID Application: Bermudez Systems LLC (AE6TTXW92K)" (until 2027-11-26) in a
  keychain of its own (`inkvolt-devid`, its password in `.env.local`). Checked: it signs with the hardened runtime and
  Apple's timestamp over SSH.

## Open decisions

None.

Decided 2026-10-27: development builds are signed with an Apple Development certificate of the team's, made through the
App Store Connect API key and kept in `~/Library/Keychains/inkvolt-dev.keychain-db` on `ignia-mac` (its password in
`.env.local`, not in git), so they keep their permissions between builds.
