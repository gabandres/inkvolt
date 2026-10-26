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

Not on the Mac: Open in Inkvolt PDF (no Mac Inkvolt PDF yet), HP clean-up (nothing like it on macOS), WIA. Still
simpler than Windows: the glass photos' boxes can't be dragged by hand yet (Find Photos Again, Save the Whole Scan), and
Print Photos' paper type and quality are the print panel's.

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
| P0 | Probe app on `ignia-mac`: answer research open items 1 to 10; record results in the research file | | Builds in CI; run pending |
| P1 | Package skeleton, CI job (`swift test` on a macOS runner), Model, SNMP | SnmpTests | Done: 42 tests. The connection and Windows queue tests wait for P4 and P7 |
| P2 | IPP | IppAndPdfTests (IPP part) | Done: 22 tests (codec, text fixtures, status, supplies, Identify-Printer, from OtherBrandsTests, RobustnessTests and MaintenanceTests too). The HTTP client waits for P4 |
| P3 | LEDM, CDM, other brands' status text | LedmTests, CdmTests, OtherBrandsTests | Done: 22 tests (LEDM documents and manifest, CDM identity, supplies and status, brands, the hardened XML and JSON readers). The connection, eSCL and web-page tests wait for P4 and P8 |
| P4 | Device HTTP, printer status, printer session, certificate pins | PrinterReadingTests, PrinterSessionTests, RobustnessTests, CertificatePinTests | Done: 78 tests (device HTTP, pins per port, the fixture transport, LEDM, CDM, IPP and eSCL clients, the connection probe, printer reader and printer session, printer ids; with the connection tests SnmpTests, CdmTests and OtherBrandsTests left for here, and eSCL from P8). The TLS handshake tests wait for PrintMac |
| P5 | Alerts, status lines | AlertTests, StatusLineTests | Done: 35 tests (conditions, the tracker's holds, quiet hours, pause, memory across restarts, polling, menu bar text, list lines) |
| P6 | Discovery: typed addresses, network search planning, DNS-SD join | NetworkSearchTests | Done: 21 tests (typed addresses, the search's addresses, SNMP question, reporting once, stopping; DNS-SD join and endpoints from OtherBrandsTests). The socket scanner is PrintMac's |
| P7 | Printer list with CUPS destinations | PrinterListTests, QueuePrinterTests (CUPS parts) | Done (2026-10-26): `CupsDestination`, `CupsQueues` (ids, virtual and temporary destinations, connection, matching a queue to a network printer), `CupsStatus`, `PrinterList` (queues part), `Demo.destinations` (30 tests); PrintMac `LibCups` (cupsGetDests2 and job counts over cupsd's socket, 1 test); the app lists queue printers, reads them every 10 s, and hides a removed network printer's own queues. `com.apple.security.print` is back. Checked on `ignia-mac`: the probe's queue for the M234dw is matched to it (not listed twice) |
| P8 | Presets, file names, scan recovery, page edits (eSCL came with P4a) | ScanPresetTests, ScanRecoveryTests, ImagingTests | Done: 52 tests (file-name templates and sets, the preset list and its JSON, the plan for a scanner, summaries; blank pages, skew, crop, rotation; scan recovery and run folders). Mail and sync-folder routes, batch separators and glass photos stay with "Later" |
| P9 | Offline diagnosis | OfflineFixerTests (diagnosis parts) | Done (2026-10-26): `OfflineModel`, `OfflineDiagnosis`, `OfflineRepairs`, `DemoOffline` (23 tests: 12 ported, 8 adapted, 3 new; the test file's header lists them); PrintMac `NetworkOfflineProbes` (Bonjour by UUID, TCP) and `LibCups` Resume-Printer / CUPS-Accept-Jobs; the app's Fix It… sheet. `--report … --demo --fix all` on `ignia-mac`: the office laser found at its new address and adopted, its queue resumed and its stuck job cancelled |
| P10 | App: main window, Add a printer, scan review, offline fixer, menu bar, settings, demo mode | DemoTests | First slice done (2026-10-26): the printer list from Bonjour and the state file, the printer pane (status, alerts, supplies, details, This is my printer), the menu bar item with alerts as notifications, the Local Network banner, demo mode, `--report`. PrintCore: `PrinterMonitor`, `DiscoveredPrinters`, `StateStore`, `SupplyText`, `Demo`, menu lines (15 tests, 287 in all); PrintMac: URLSession and UDP SNMP transports, Bonjour, Local Network signal (7 tests). Checked on `ignia-mac` with the owner's M234dw. Then (2026-10-26): the print queue card (`QueueJobs`, `RefreshGate`, 13 tests; cancelling the user's own held job checked on `ignia-mac`), the Scan tab (`ScanPages`, 5 tests; PrintMac `ScanImaging`, `ScanPdf` with Vision text, `DemoScanPage`; `--report … --demo --scan`: a blank sheet skipped, a 2.5° page straightened to 0.00°, a searchable PDF whose text is found), Settings (menu bar item, open at login through `SMAppService.mainApp`, alerts: low level, offline, quiet hours; `AlertSettings`, 4 tests), Pause Alerts in the menu, and window-closed checks (`PrinterMonitor.check`, `PollingConditions`). Later the same day: Print a PDF, Print Photos and Copy (scan → print) through the print panel on the printer's macOS queue (`Printing`; `PhotoLayout`, `CopyLayout`, `PageFit`, `PageRange` ported, 50 tests; PrintMac `PhotoSheets`); the Settings tab (LEDM settings and automatic firmware updates, the admin password in the Keychain: `PrinterPasswords`) and the maintenance card (`LedmSettings`, `FirmwareUpdate`, `Maintenance*` ported, 58 tests); USB scanners through ImageCaptureCore (`SystemScanners`, `SystemScanDevice`; `ScanDevice`, `ScannerMatch` and the printer list's scanner part, 7 tests; demo mode's `DemoScanDevice`); scan presets (one-click scans, Save (preset), Manage Presets, folders as app-scoped bookmarks). Checked on `ignia-mac`: the M234dw's 13 settings and firmware mode read (nothing written), AppKit finds its queue from the sandbox, ICC opens a session on it and reads its glass; `--report … --demo --scan` also saves a preset scan into its folder, subfolder and name. Add a printer (2026-10-26): the sheet (File › Add a Printer…, the toolbar's +, the empty list), the subnet search, removed printers put back, a typed address; PrintCore `AddPrinter` and `AddPrinterText` (9 tests), `Demo.searchNetwork`; PrintMac `SocketNetworkScanner` (2 tests); `--report … --search` found the M234dw (listed) on `ignia-mac`, and demo mode's unlisted laser. Parity with the Windows table (2026-10-26, after 1.1): batch scanning (`PatchCodes`, `Separators`, `BatchSplit`, `SeparatorSheet`, `SavedParts`, `PartNumbers` ported, BatchScanTests 21 tests; `ScanPages` files, separators and photos, 8 tests; PrintMac `SeparatorSheetPdf`), glass photos (`PhotoFinder`, `PhotoBox`, `GlassPhotoCrop`, GlassPhotoTests 12 tests; PrintMac `ScanImaging.photo`), presets' split, photos and after-steps, the ID card copy (PrintMac `IdCardSheet`), Set Up in macOS (`QueueSetup`, 7 tests; PrintMac `LibCups.addQueue`, `CupsSetupProbe`), the fixer's `.pointAt` (`setDeviceUri`), Print Photos' queue papers, borderless, crop and resolution (`QueuePapers`, 4 tests; `LibCups.media`), firmware Notify (`offered`, `noFirmwareNotify`, 2 tests); 538 PrintCore tests. Checked on `ignia-mac`: a permanent IPP Everywhere queue for the M234dw made and deleted from the sandbox (`--setup-probe`), its 25 paper sizes read; in demo mode `--batch` (2 PDFs at the Patch T sheet), `--photos` (3 photos at 4.0°, −6.0°, 2.0°, cut out straight), `--idcard`, `--setup`, `--fix all` (the queue pointed at the new address) |
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
  glass are cut out with `GlassPhotoCrop` on the full-size scan's pixels; their boxes show on the thumbnail, and Find
  Photos Again or Save the Whole Scan are the review's edits for now (no dragging boxes yet).
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

## Open decisions

- Inkvolt PDF's bundle ID: proposed `com.bermudezsystems.InkvoltPdf`.
- An Apple Development identity on the Mac, so development builds keep their Local Network permission between builds
  (ad-hoc builds may be asked again).
