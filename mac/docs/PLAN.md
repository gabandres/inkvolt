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
  Probe/                         InkvoltProbe: throwaway sandboxed app that settles the open platform questions (P0)
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
| P0 | Probe app on `ignia-mac`: answer research open items 1 to 10; record results in the research file | | Done (2026-10-26): results in the research file's "Probe results on a Mac"; items 3 (Printers & Scanners deep link) and 10 (SMAppService, now testable with the development certificate) still open |
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

Not in 1.0 (their modules port with their features): `ContentEditor`, `ContentLexer`, `Redaction`, `DocLayout`,
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
| D4 | Comments, drawing, stamps, images, text shaping for their appearances | DrawingAnnotationTests, DrawingGeometryTests, RubberStampTests, TextStampTests, Core2StampTests, LinkAndImageTests, ShapingTests, BidiLineTests | Started (2026-10-27): the drawing types (`AnnotStyle`, `AnnotGeometry`, `LineEnding`…) and `DrawingGeometry` (DrawingGeometryTests, 12 tests); `TabLabels` for D7 (TabLabelTests, 5 tests) |
| D5 | Forms: fill, appearances, actions, form JavaScript (JavaScriptCore), Fill & Sign | FormTests, Core2FormTests, FormActionTests, FormAppearanceTests, JsFormTests, Core2ScriptTests, TabLabelTests | |
| D5a | Edit text and images: the page's own text (ContentEditor, ContentLexer, the fonts it needs) and pictures | ContentEditorTests, ContentEditFontTests | |
| D5b | OCR: Vision's recognizer behind PdfCore's recognizer function, the invisible text layer (TextLayer) | TextLayerTests, ScanPdfTests | |
| D5c | Export to Word, Excel and text (DocLayout, DocxWriter, XlsxWriter, DocumentExport, ExportGlyphs, ExportPage) | ExportTests, ExportPipelineTests, ExportFormTests, ExportRealWorldTests; `pdf/tools/export-corpus` on the Mac | |
| D6 | Print layout | PrintLayoutTests | Done (2026-10-27): `PrintLayout` and `PrintPlan` (PrintLayoutTests, 13 tests); the printing itself comes with D7 |
| D7 | The app: document windows and tabs, the page view (tiled rendering, selection, find, VoiceOver), the side rail, tools, start page, settings, recovery prompt; Open in Inkvolt PDF from Inkvolt Print | | Started (2026-10-27): the reader, `mac/InkvoltPdf` (a SwiftPM app; `build.sh` makes, signs with the development identity and installs `/Applications/Inkvolt PDF.app`): open, Open Recent, Finder's Open With, window tabs; continuous scrolling, pinch and keyboard zoom with pages redrawn sharp in the background (stale renders cancelled); thumbnails and the outline in a sidebar; find with highlighted matches; selecting and copying text (word, line, all); the password prompt; damaged files refused with a message. `--self-test <report>` runs 17 checks per document in the real app: all pass on seven files (three real ones, as copies; a 300-page, a mixed-size and rotated, a navigation and a cupsfilter PDF), every page drawn at 0.5×, 1× and 2×. Not yet: tiles for very high zoom, selection across pages, clickable links, the icon; checked only through the self-test (no one at the screen) |
| D8 | Release: Developer ID certificate, hardened runtime, notarytool with the API key, the DMG, Sparkle 2 (EdDSA key, appcast and where it's hosted), notices and the source offer | | |

### Parity with Windows

Decided 2026-10-27 with the owner: Inkvolt PDF on the Mac reaches full parity with the Windows app (and Inkvolt Print
already has it, but for HP's clean-up tool, which has no macOS counterpart), so a person, an office or a school picks
the platform, not the features. 1.0 is the first stage; the E-steps after it bring every other Windows feature. From the
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
| Scan, printer status when printing, Inkvolt Print's printer settings | D7, with Inkvolt Print's PrintCore (eSCL, the printer reading) |
| Help › What's New, updates | D8 (Sparkle) |
| Redaction (with redaction by pattern), Sanitize Document | E1 |
| Signatures (verify), Sign Digitally | E2 (Security.framework; identities from the Keychain) |
| Compare Files | E3 |
| Reduce File Size, Flatten, Header & footer, Watermark | E4 |
| Prepare Form | E5 |
| Measure | E6 |
| Save as PDF/A-2b | E7 |
| Batch | E8 |
| Attachments, Layers | E9 |
| Read Aloud | E10 (AVSpeechSynthesizer) |
| AI assistant (bring your own, off by default) | E11 |
| PDF from Office files and web pages | E12 (web pages through WebKit; Office files through Word for Mac or LibreOffice when installed) |
| Split view | E13 |

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
- The tests write their PDFs by hand (`TestPdf`, `Core1TestPdf`); encrypted ones are written by MuPDF (AES-256), where
  the Windows tests use PDFsharp.

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
