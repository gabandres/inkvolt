# Inkvolt for macOS: plan

Decided with the owner:

| | |
|---|---|
| Apps | Inkvolt Print first; Inkvolt PDF after it shipped |
| Stack | Native Swift: SwiftUI with AppKit where needed; Apple frameworks only |
| Distribution | Print: Mac App Store (sandboxed). PDF: notarized DMG with Sparkle 2, MuPDF, AGPL |
| Minimum | macOS 15 Sequoia |
| Price | Free; no account, no telemetry, no cloud |
| Signing | The Apple team that signs the Inkvolt mobile builds (AE6TTXW92K) |
| Repo | This monorepo, `mac/`; shares fixtures and glossaries with the Windows apps |

Platform facts and their sources: [`research/print-v1-platform.md`](research/print-v1-platform.md). What a new Mac needs:
[`NEW-MAC.md`](NEW-MAC.md). What the Mac still lacks: "Open" at the end.

## Inkvolt Print scope

The Windows app's features: printer status, supplies and alerts (LEDM, CDM, IPP, SNMP; the same fallback order and
identity-before-data rule); Add a printer (Bonjour, the subnet search, a typed address); scanning (eSCL and USB through
ImageCaptureCore, presets, review, crop and straighten, crash recovery, batch scans with separator sheets and patch codes,
photos on the glass, the ID card copy); Copy, Print Photos, Print a PDF; HP maintenance, firmware and LEDM settings; the
offline fixer and Set Up in macOS; a menu bar item (the tray's equivalent) with alerts, launch at login only if the user
turns it on; demo mode (the made-up environment), so App Review can use the app without a printer; and the roadmap's
items after 1.0 (P12).

Not on the Mac: HP clean-up (nothing like it on macOS), WIA. Not yet: separator sheets marked with a QR code or barcode
saying PATCHT and the QR code on the printed sheet (Windows' `SeparatorCodes` through ZXing.Net; on the Mac, Vision's
barcode request would read them), so the Mac's choice still says "Patch codes" and `SeparatorCodeTests` has no Mac port.

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

| Step | What | .NET tests ported | Status |
|---|---|---|---|
| P0 | Probe app: the research file's open items | | Done (results in the research file's "Probe results on a Mac"; the probe's source is in git history up to 14329e3). What is still open is its "Open questions" |
| P1 | Package skeleton, CI job, Model, SNMP | SnmpTests | Done |
| P2 | IPP | IppAndPdfTests (IPP part) | Done |
| P3 | LEDM, CDM, other brands' status text | LedmTests, CdmTests, OtherBrandsTests | Done |
| P4 | Device HTTP, printer status, printer session, certificate pins | PrinterReadingTests, PrinterSessionTests, RobustnessTests, CertificatePinTests | Done; the TLS handshake tests are PrintMac's |
| P5 | Alerts, status lines | AlertTests, StatusLineTests | Done |
| P6 | Discovery: typed addresses, network search planning, DNS-SD join | NetworkSearchTests | Done; the socket scanner is PrintMac's |
| P7 | Printer list with CUPS destinations | PrinterListTests, QueuePrinterTests (CUPS parts) | Done |
| P8 | Presets, file names, scan recovery, page edits | ScanPresetTests, ScanRecoveryTests, ImagingTests | Done |
| P9 | Offline diagnosis | OfflineFixerTests (diagnosis parts) | Done (the test file's header lists what was adapted) |
| P10 | The app: main window, Add a printer, scan review, offline fixer, menu bar, settings, demo mode, then the rest of the Windows 1.0 feature table (batch scans, glass photos and their boxes by hand, the ID card copy, Set Up in macOS, Print Photos' queue papers, borderless, paper type, quality and color) | DemoTests, BatchScanTests, GlassPhotoTests and the table's others | Done. Not checked by a person: anything on paper (separator sheet, ID card, Print Photos borderless), the Photos sheet's dragging and keys, a feeder (batches and two-sided separator backs were checked in demo mode only), a real USB scanner |
| P11 | App Store: record, privacy label "Data Not Collected", review notes (demo mode, why `network.server`, the subnet search), screenshots (`--snapshot`) | | Done (live since 1.0). Listing, review notes and What's New go through `asc-listing.mjs` (README). Entitlements: sandbox, network client and server, `print`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `device.usb`, the app group; the preflight and the review notes say why each |
| P12 | The roadmap's items after 1.0 (`print/ROADMAP.md`): PrintCore halves on the PC, PrintMac and the app on the Mac | ProTests and each item's below | Done: 1.1, 1.2, 1.3, 1.5, 1.6, 2.3, 2.4, 2.6, 3.2, 3.4, 3.6, 3.7 (3.5 Open in Inkvolt PDF came with Inkvolt PDF for Mac). Left: 2.1, 2.2, 3.1, 3.3, which need a real printer or scanner |

### P12: what differs and what's left, per item

- **1.6 Pro key.** The key file's root is the app group container
  `~/Library/Group Containers/AE6TTXW92K.com.bermudezsystems.inkvolt/` that both apps claim in
  `com.apple.security.application-groups` (research file Q6: a group whose ID starts with the team ID opens without a
  prompt on macOS 15 for the sandboxed App Store app and the unsandboxed Developer ID one alike); `store(own:)` falls back
  to the app's own copy without a container. PdfCore's `Pro` sits on PrintCore's `ProCheck("pdf")`. **Mac difference:**
  no Get Inkvolt Pro button, price or shop link in the App Store copy (guidelines 3.1.1(a), 3.1.3(b); research file Q6),
  and no refusal names them, in the window or from Terminal (`print`, `status --all`): they say it's Pro and where a key
  is entered (`Pro.howToGet`). Before enforcement is switched on there, its Pro features need an in-app purchase too, or
  stay free in that copy. Not checked by a person: the window on screen (the key box, Return and Escape, the Remove
  alert, VoiceOver), Inkvolt PDF's window showing a key entered in Inkvolt Print.
- **1.3 Scanners that only give PDF.** PrintMac's `ScannedPdfPages` draws a page that isn't one JPEG through PDFKit at
  the scan's resolution (over 200 million pixels refused), set as `ScannerPdf.renderer` before anything scans. Not
  checked: a real PDF-only scanner, a drawn (not taken out) page in the app.
- **1.5 Firmware watch, Keep My Cartridges Working.** **Mac difference:** `StateStore.rename` (Windows'
  `RenamePrinterId`) is there for parity but nothing calls it: the Mac's ids were normalised from the start. Not
  checked: the notice and button on screen, a real firmware change, a printer set to install automatically.
- **1.1 Supply history.** A queue printer's CUPS levels feed the history without a page count, as Windows' queue
  readings. Not checked: the card and chart on screen (light, dark, Increase Contrast, VoiceOver), the save panel, a
  real printer's rows day after day, a cartridge change seen live.
- **2.6 Fleet page, export, `status --all`.** **Mac differences:** a queue's state and levels come with cupsd's one list
  of destinations (bounded as a whole), so A_queue_windows_lost_mid_read_says_so has no Mac case and
  A_read_that_hangs_holds_up_only_its_own_row's rows are network printers; a USB scanner macOS lists reads as ready to
  scan (no ImageCaptureCore session is opened); a colour MFP's queue may have no levels in cupsd (Windows reads them over
  SNMP through its port), so it's fine, not low; no permission prompt in the sandbox
  (A_copy_that_may_elevate_asks_windows_only_after_the_user_was_refused left out: a refusal is the steps); the sandbox
  lets `--out` write only inside the container (a file elsewhere comes from the shell's `>`); a network printer keeps the
  addresses it moved from (`previousHosts`, Windows' `_previousHosts`). Fix All is Resume and Accept Jobs (what Use
  Printer Offline comes to on a Mac); stuck jobs and Add Again are left to the printer's own Fix It…. Mac-only tests:
  The_page_takes_what_the_app_shows_and_marks_what_is_last_known,
  A_queue_name_a_printer_wrote_is_cleaned_in_the_question, The_demo_macs_fix_all_resumes_the_office_laser_and_leaves_its_stuck_job.
  Not checked: a real printer or queue through Fix All, VoiceOver and Tab by hand, `status --all` on a real Mac's printers.
- **2.4 Batch print.** **Mac differences:** macOS can't keep another program from writing, renaming or deleting an open
  file, so `BatchHeldFile` holds the file's bytes from the moment it's opened, and what prints is what was fingerprinted;
  a list's paths are the Mac's (devices under /dev and /.vol; another computer through the automounter, /net/<host> and
  /Network/Servers/<host>, needs the yes; a colon refused anywhere; a backslash read as a separator, so a Windows list's
  relative paths read); "someone still writing" is another program's `flock` (macOS has no sharing modes; a plain copy is
  caught by the quiet period and the end-of-file check); the sample PNG's pixels are stored, not deflated; Image I/O
  gives no size for a PNG whose header alone claims 40,000 × 40,000, so it reads as damaged; a PDF whose author doesn't
  allow printing is left out, as Preview won't print it; the sandbox lets `print` reach only what the Batch Print window
  was given (kept as app-scoped bookmarks) and the container: anything else reads "macOS doesn't let Inkvolt Print read
  this file"; a job is handed to cupsd **held**, its `copies`, `sides` and `media` read back and compared
  (`BatchTicketCheck`), released only when kept, where Windows validates the ticket before spooling. As Windows: a paused
  queue takes the jobs. The drop folder's lock `.inkvolt-watch.lock` is the one `Suite/FileLock` both Mac apps take.
  Not checked: paper (no job was ever released to a printer), the window on screen, Control-C in Terminal.
- **1.2 Record a printer, Report a Problem.** **Mac differences:** PrintCore records through the `HttpTransport` it is
  handed, so a reply comes whole and its bound is PrintMac's URLSession transport's
  (A_printer_that_never_stops_answering_doesnt_fill_this_pcs_memory is PrintMacTests'); the patterns are in ICU's syntax;
  `ZipArchive` stores files, not deflated as .NET's `ZipFile` (PrintCore can't use Apple's Compression); `record`'s
  folder is a plain name inside the app's recordings folder (the sandbox writes nowhere else), scanning is
  `--record-scan`, an option without its value is refused, and what it prints masks the address and this Mac's names;
  Report a Problem has no log ("(no log yet)"). Not checked: a real printer's recording, the window on screen.
- **3.6 Supply levels for USB printers.** Route 1 only (route 2 is Windows' bidi); what differs is under "Mac
  differences" (a queue printer's own supply levels). Not seen: a real IPP-over-USB printer, how fresh cupsd's
  `marker-*` stay while idle.
- **3.4 Job notifications.** What differs is under "Mac differences" (job notifications). Not seen: a notification on
  screen and its buttons, a real printer failing a job.
- **2.3 Scan cleanup and a Unicode OCR layer.** **Mac differences:** a stop is a `BatchStop` (the work runs through
  `offPool`, where Task cancellation can't reach), checked between rows; a resolution is held to 1 to 9600 dpi before the
  filters size their blocks by it (Windows trusts the scanner); the filters' pixels are PrintCore's, not Core Image's, so
  both apps clean a page alike; Undo covers clean ups only (the Mac review has no general Undo) and puts back a page's
  crop and filters, keeping a later turn (a crop drawn by hand stays: Windows undoes it first, as its own step); All Pages
  from a view of photos sets only the two switches it shows (Windows: all four); a cancelled save to a chosen place keeps
  the files it wrote and Save again writes the rest (Windows: "Save cancelled.", the next save writes all); a Text
  language from Windows ("ru") is Vision's tag ("ru-RU"), and the list is Vision's languages after Automatic; PDFKit, like
  pdf.js, finds each word of a right-to-left line but not a phrase across two. Not checked: Preview's own Find on screen,
  pdf.js on a file the Mac wrote, Vision's word boxes for Arabic or Japanese pages, a real scanner's pages; the crop keeps
  a few pixels of lid at the sheet's edge (`PaperEdge` errs toward keeping).
- **3.2 SNMP: a community per printer, SNMPv3 (Pro).** Logins in the Keychain (`SnmpLoginKeychain`, service
  `com.bermudezsystems.InkvoltPrint.snmp`). **Mac differences:** the crypto is a seam, `SnmpCrypto` (CryptoKit and
  CommonCrypto in PrintMac's `AppleSnmpCrypto`; a test-only one in PrintCoreTests), where Windows calls .NET's directly;
  `SnmpClient`'s login init throws where Windows' constructor throws ArgumentException; RFC 3414 A.3's MD5 and SHA-1
  vectors run in PrintMacTests only; the engine is discovered once per printer and Ku cached
  (`TheAgentIsDiscoveredThenReadSignedAndEncrypted` counts 1 discovery here, 2 on Windows;
  `AUsersKeysAreWorkedOutOncePerPassphraseNotPerEngine` is Mac only); no `SnmpLogins.rename` in use (the Mac's printer ids
  never change); SNMP Access… is in the sidebar's context menu (no Ctrl+K palette).
  **Windows ahead, for the Mac to take up:** a refusal on a connection whose login has answered signed is read as
  offline, not refused (a refusal can't be signed, so anyone on the network can send one), and the next connection's
  refusal decides; the Mac reads it as refused at once (`aLoginRefusedOnAConnectionReadsAsRefusedNotOffline` takes two
  checks on Windows). The Mac's refused snapshot raises no alert; Windows' carries `PrinterSnapshot.LoginRefused`
  (`AlertKind.LoginRefused`, an error). A refusal keeps whether another device answered (the Mac's `setRefused` replaces
  the phase). A refusal is the printer's only from the engine ID its signed answers came from, remembered with its
  `SnmpDevice` (`EngineId`), so another device that took the address reads offline and SNMP Access…'s check lets such a
  refusal be saved anyway (`SnmpLoginCheck.Refused.FromThisPrinter`); once an agent has answered signed, a client takes
  no refusal from it (`SnmpClient.SignedEngineId`); a refused snapshot keeps offline's hold running, so refusals spoofed
  every other check can't silence offline. Not checked: a printer's SNMPv3 agent, net-snmp's agent, a printer with
  `public` disabled.
- **3.7 Spanish interface.** Every sentence PrintCore and PrintMac show goes through `loc` (`Suite/CoreLanguage`,
  `CoreStrings.xcstrings`, Windows' Spanish word for word where it exists), installed by the app only when it runs in
  Spanish: the command lines and Inkvolt PDF's use of PrintCore stay English; a test gives its own table to its own task
  (`CoreLanguage.withTable`), never the process. The app's own text is in `Localizable.xcstrings`, Info.plist's in
  `InfoPlist.xcstrings`. Checks: `CoreStringsTests`, `ShownStringsTests` (PC), `check-strings.sh`, `--report … --strings`.
  **Mac differences:** supply names stay English in the model (history and alert keys) and read in Spanish where shown
  (`SupplyNames.display`), so a printer's own "Black Toner" reads "Tóner negro" too; macOS's menus and panels come from
  macOS in its language; the Spanish names of macOS screens (Configuración del Sistema, Impresoras y escáneres, Ítems de
  inicio) were written from memory. Left in English: printers' own words, the command lines, logs, the report's labels,
  Report a Problem's details, recordings, export columns, protocol and parser errors. Not checked: a Mac whose macOS is
  in Spanish, the UI on screen in Spanish.

## Mac differences

- Numbers from outside that become an Int: Swift's `Int(x)` traps on NaN, infinity or a value out of range
  where .NET's cast doesn't, so such a value is checked as a Double first (`Int(exactly:)`, or a `// bounded:` reason;
  `mac/tools/check-int.sh` in CI; `HostileNumberTests` in both packages). Where it shows: a poster is at most
  `PrintLayout.maxPosterTiles` (1000) sheets across or down; an image too large to state says so without its size; a field
  font size that isn't a number reads Auto; a color component that isn't a number is written as 0; a redaction area's NaN
  edge blacks out to the image's edge; a supply forecast from readings that make no line is steady; the photo finder looks
  for nothing beyond 1e6 pixels per inch; Office exports write lengths within ±1e15 units.
- Inkvolt Pro's signature check is a protocol in PrintCore (`ProSignatureVerifier`): CryptoKit in PrintMac, a stand-in in the
  Windows-run tests. Key dates stay text (yyyy-MM-dd, checked as a real date) instead of .NET's `DateOnly`. The key file has one home
  (no Store-package redirection to look through).
- A page's scanner PDF (`ScannerPdf.origin(of:)`) is found by the page's bytes, in a table bounded to the last 32 PDFs, where
  Windows ties it to the byte array's lifetime (`ConditionalWeakTable`); `PdfOrigin.document` tells PDFs apart.
- SNMP errors are Swift errors: `SnmpFormatError`, `SnmpTimeoutError`, `SnmpErrorStatus` (the .NET exceptions).
- IPP attribute values are an enum (`IppAttributeValue`: text, integer, boolean, bytes), not `object`.
- Device XML is read with `XMLParser` into a small tree (`XmlElement`, by local name); a document with a DTD is refused
  before parsing. CDM's JSON goes through a small reader of its own (`Json`: numbers keep their text, nesting capped at 64)
  rather than JSONSerialization, whose booleans and numbers differ between Darwin and other platforms.
- HTTP goes through PrintCore's own `HttpTransport` (request and response values; `DeviceNetworkError` for no answer),
  so PrintCore never opens a socket: PrintMac's URLSession transport and the fixture transport sit behind it.
  `CertificateCheck` holds the pin rule the TLS transport asks on each handshake; the loopback TLS tests
  (CertificatePinTests' handshakes) move to PrintMac. URLSession sends both `Host` and `Authorization` as
  given, which the Epson eSCL quirk and the EWS password need (below).
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
  model only shows what it says. With the window open it watches live; with the window closed the menu bar item's checks take
  over (below), as the Windows app's `AlertPolling`.
- Queue printers are macOS's CUPS destinations (`cupsGetDests2` through libcups over cupsd's domain socket; the sandbox
  refuses `localhost:631`), not Windows queues: the queue's state, `printer-state-reasons` and `marker-*` are IPP's, so
  they're worded by the IPP readers, with macOS's own conditions first (offline, paused, not accepting jobs; CUPS's
  `cups-*` notes left out). A queue belongs to a network printer by the UUID in its device URI (`dnssd://…?uuid=`), the
  printer's address or Bonjour host name there, its Bonjour service name, or an unambiguous name or model. Bonjour's
  temporary destinations (printers macOS sees but nobody set up), faxes, classes and PDF writers are left out. Queues
  aren't renamed (renaming one in Printers & Scanners changes `printer-info`, its shown name), so there's no rename
  rule. Queue ids are `mac-queue:<name>`. Windows scanners' part of the printer list is ImageCaptureCore's (`SystemScanners`, `ScannerMatch`).
- A queue printer's own supply levels (roadmap 3.6): Windows asks through its IPP class driver
  (`IppPrintDevice`) or a maker's driver over bidi; the Mac has no driver route, so PrintMac asks the queue's printer
  itself over IPP when its device URI says it speaks IPP (`IppQueueReading.route`: `ippusb://` or a relay on `localhost`
  is USB, an IPP or Bonjour URI is the network; `usb://`, sockets, LPD and shared queues aren't asked), and reads the whole
  reply where Windows hands over the bare attributes group. cupsd's own copy (`marker-*` from the queue's last job) stands
  when no printer answers, which Windows' spooler has no counterpart for; the supplies card then shows no source line.
  Words say "the printer over USB (IPP)" and "From the printer", never "through Windows"; the origin with no answer is
  "macOS's print queue". Paused, not accepting jobs, and stopped on an error are macOS's holds that stay the headline.
  `DeviceQueueStatus` is an actor: reads that overlap share one round of questions, and a round with nothing keeps the
  last reading for 2 minutes (`keptFor`), asking again every 30 s meanwhile (Windows drops it on the first miss and waits
  5 minutes; its callers read one at a time).
- Job notifications (roadmap 3.4) read CUPS's `job-state`, not the spooler's bits: failed is `stopped` or
  `aborted` (no `job-state-reasons` from `cupsGetJobs2`, so a jam and a queue paused mid-job both read failed); a job
  held by hand isn't stuck; a job CUPS gave up on and then lists as waiting again was restarted. No page counts, so a job
  moves by its size, its state or a job leaving, and a long job on a printer saying it's printing raises one "may be stuck"
  after 15 minutes more often than on Windows. The queue's offline reason stands for the job's PaperOut and Offline bits;
  Use Printer Offline, Spooling and Retained have no counterpart. CUPS keeps finished jobs: printed and cancelled ones
  count as gone, one given up on is told only within 15 minutes of finishing (never when CUPS gives no finish time). A job key is `Job|id|milliseconds` (Windows
  writes .NET ticks; each app reads only its own state file). Names are cut in UTF-16 units as on Windows; a lone
  surrogate reaches Swift as U+FFFD and stays as that character. Whose job it is (`JobOwner.owns`) is stricter than on
  Windows, since `cupsGetJobs2` never says which computer a job came from and a Mac sharing its printer lists other Macs'
  jobs under the same user name: a job that doesn't say is yours only on a queue no other computer prints to
  (`CupsDestination.othersMayPrint`: `printer-is-shared` false and not another computer's queue; not saying counts as
  shared), one whose `job-originating-host-name` is localhost (PrintMac's reader may ask for it) is yours on any queue,
  and a domain or computer this Mac can't compare with is never a match (Windows names the job then). A job counts as
  having left only once two reads in a row miss it (as of the first miss; a read that misses a job decides nothing
  stuck), so one missed read restarts no stuck wait; `pendingUntil` also asks for a read when a failed job's hold runs
  out; over the 256 remembered jobs the newest are kept. Windows does all three the same way since 2026-11-05
  (`00e4ed7`, JobAlertTests.cs with the Mac's test names), and on both a read that misses a job leaves a stuck alert held
  by quiet hours as it is.
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
  isn't needed). Open in Inkvolt PDF (roadmap 3.5, done 2026-11-02), as on Windows: a preset's last step (offered when
  Inkvolt PDF is installed, or kept as "(not installed)"; a JPEG preset says Inkvolt PDF opens PDFs only), Settings ›
  General's "Open scans in Inkvolt PDF" (off; shown when it is installed), and the save bar's Open in Inkvolt PDF link
  after a PDF save (`InkvoltPdfApp`). Mac difference: Inkvolt PDF is found by bundle identifier through Launch Services
  and handed the files with `NSWorkspace.open(_:withApplicationAt:)`, not a URL scheme (the sandbox allows it; nothing
  else is shared). Checked on `ignia-mac`: the build (0 warnings) and `--report --demo --scan` (the saved PDF listed for
  the hand-off, Inkvolt PDF found). Not checked: a person seeing Inkvolt PDF open the files, and the report with a stub
  app registered in its place (the real Inkvolt PDF is installed on the Mac).
- Add a printer is a sheet over the main window (File › Add a Printer… ⌘N, the toolbar's +, the empty list's button). Its rules
  (what an address that answered becomes, the order, what the sheet says, a few identified at a time) are PrintCore's
  `AddPrinter`, tested, where the Windows app keeps them in its view model. The search's networks are the Ethernet and Wi-Fi
  interfaces that are up with a broadcast address (no utun, ipsec, ppp, bridge, awdl or llw), not "adapters with a gateway";
  TCP through Network framework, the SNMP question on a BSD socket with `SO_BROADCAST`. "Connected with a cable?" points at
  Printers & Scanners (USB printers are listed through their macOS queues).
- Discovery is Bonjour only (no Windows association endpoints): `dns_sd`'s browse, resolve and IPv4 lookup in PrintMac
  (`BonjourDiscovery`; Local Network denied is `kDNSServiceErr_PolicyDenied`), joined into printers by PrintCore's
  `DiscoveredPrinters` (the Windows discovery's `Merge`, services part). A printer needs an IPv4 address to be listed.
- Local Network access has no API: `LocalNetworkSignal` is told by the transports and Bonjour (denied: URLSession's -1009
  whose network path says `localNetworkDenied`, `EHOSTUNREACH` on UDP, `PolicyDenied`; allowed: any answer). Denied shows a
  banner with a link to System Settings; once allowed, discovery and the offline printers start again at once.
- A scanned page past `PageCleanup.maxPixels` (300 M pixels by its header, read without decoding; hostile-input review,
  2026-11-06): saved as the scanner sent it with no edit at all, where Windows drops only its filters and still turns,
  straightens and crops it at full size (a JPEG claiming 65,500 × 65,500 is 17 GB as RGBA, twice over for PageRotate).
  PrintCore: `PageEdits.for(width:height:)` is `.none` there; `ScannedPage.tooLargeToEdit` (set by the app from the
  header, not kept in the recovery folder) stops the page check straightening, cleaning up or finding photos, refuses photos
  set by hand, and its note says "Saved as scanned: too large to straighten, crop or turn" (the Clean up view says it with
  the millions of pixels). PrintMac: `ScanImaging.decode`, which every scan decode goes through (OCR's `ScanPdf.recognize`
  and `IdCardSheet` too), never decodes such a page at full size and makes a small copy of it only from a baseline JPEG
  (`isBaselineJpeg`: a progressive one or another kind isn't decoded at all); an ImageCapture page file over
  `DeviceHttp.maxScanReplyBytes` isn't read and ends the scan with a message. Batch print pictures were already refused
  past `BatchPrintLimits.maxPicturePixels` and photo sheets read at most 3000 px; ScannedPdfPages past 200 M pixels.
  Tests: PageCleanupTests.aPageTooLargeToCleanSavesAsScanned (Windows' twin, the Mac's ending), ScanPagesTests.
  aPageTooLargeToEditIsSavedAsScannedAndSaysWhy, MacImagingTests.aPageTooLargeToEditIsSavedAsScannedNotTurnedOrCropped,
  aPageClaimingAHugeSizeIsNeverDecodedAtFullSize, aHugePageThatIsntABaselineJpegIsntDecodedEvenSmall,
  anImageCaptureFileLargerThanAScannedPageIsntRead.
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

Decided for Inkvolt Print: the bundle ID is `com.bermudezsystems.InkvoltPrint`, on the Inkvolt mobile apps' team
(AE6TTXW92K); development builds are signed with the team's Apple Development certificate ("Open decisions" below); App
Store builds are signed by Xcode with the team's cloud-managed certificates through the App Store Connect API key (no
certificate in the Mac's keychain), as the mobile apps are. The app is a hand-made Xcode project (no XcodeGen). Print and
PDF stay two apps (PDF can't be on the App Store: AGPL MuPDF and Sparkle).

## Inkvolt PDF

Decided with the owner:

| | |
|---|---|
| Engine | MuPDF's C library for everything the document is: drawing, text, and the PDF objects that editing, forms and saving work on (the role PDFsharp has on Windows). One model of the document, so pages look and export as on Windows. No PDFKit for the document; the page view is our own |
| Text shaping, form scripts, signatures | Core Text (or MuPDF's own HarfBuzz) for HarfBuzzSharp, JavaScriptCore for Jint, Security.framework for System.Security.Cryptography.Pkcs: Apple frameworks, no packages beyond MuPDF and Sparkle |
| Bundle ID | `com.bermudezsystems.InkvoltPdf` |
| Distribution | Developer ID, notarized, a DMG; updates through Sparkle 2 (EdDSA-signed appcast). Not sandboxed (Sparkle's unsandboxed setup; the app opens whatever file the user picks) |
| License | AGPL-3.0 with MuPDF's notices and source offer, as `pdf/THIRD-PARTY-NOTICES.md` |

Scope: full parity with the Windows app, so a person, an office or a school picks the platform, not the features; a
roadmap item (`pdf/ROADMAP.md`) counts as done only when it ships on both. One Inkvolt Pro key (the same signed format)
unlocks Pro on both, and a business licence covers both. Text editing, OCR and export were in 1.0, so it stands against
PDF Expert, which sells exactly those.

### Layout

```
mac/
  InkvoltPdfKit/                 Swift package
    Sources/MuPDFShim/           C over MuPDF that catches its errors (fz_try); MuPDF itself is the `MuPDF` binary target
                                 (Frameworks/MuPDF.xcframework, from mac/Vendor/mupdf, not in git)
    Sources/ScriptLimits/        JavaScriptCore's watchdog, declared in C
    Sources/PdfCore/             the Windows Core's rules over MuPDF: engine, session, edits, forms, pages, text (Core
                                 Text), form scripts (JavaScriptCore), OCR (Vision), and every E-step's module
    Tests/PdfCoreTests/          Swift Testing; reads pdf/tests fixtures and test PDFs in place
  InkvoltPdf/                    the app (AppKit, a SwiftPM package): Info.plist, build.sh, assemble.sh, sign.sh,
                                 release.sh (Developer ID, notarytool, DMG, Sparkle appcast); InkvoltPdf.entitlements (the app group)
  Vendor/mupdf/                  build.sh: MuPDF at a pinned tag as a static XCFramework (arm64, x86_64), built from
                                 its source (not kept in the repo), with the build's notices
  tools/                         swift-dev.ps1, mac.sh, bench/
```

Unlike PrintCore, PdfCore needs MuPDF, so it builds and tests on the Mac and in the `mac` CI job, not on the Windows PC
(MuPDF could later be built for Windows' Swift too).

### Module map (.NET to Swift)

| `pdf/src/InkvoltPdf.Core` | Swift | Notes |
|---|---|---|
| `PdfEngine`, `PageText`, `TextLayer`, `Links`, `Geometry` | `PdfCore` (top level; `TextLayer` in `PdfCore/Ocr`) | MuPDF on both; the closest port |
| `DocumentSession`, `DocumentSession.Edit`, `Incremental`, `Recovery` | `PdfCore/Session` | PDFsharp's object edits become MuPDF `pdf_obj` edits; incremental saves with `pdf_save_document` |
| `PdfSecurity`, `KeptProtection`, `PasswordStrength`, `SignedEdits` | `PdfCore/Security` | |
| `PageEditor`, `PageRange`, `ImageImport`, `Bookmarks`, `BookmarkTree` | `PdfCore/Pages` | |
| `Annotations`, `Annotations.Drawing`, `Appearances`, `DrawingGeometry`, `RubberStamps`, `TextStamps`, `PageMarks` | `PdfCore/Annotations` | appearance streams written as on Windows |
| `FormActions*`, `FormScripts`, `JsFormHost`, `JsPrelude`, `TabLabels` | `PdfCore/Forms` | Jint becomes JavaScriptCore behind a protocol, so PdfCore tests can use a fake |
| `Shaping`, `FontKit`, `FontNames`, `FontPrograms`, `TextFonts`, `Bidi` | `PdfCore/Text` | HarfBuzzSharp becomes Core Text or MuPDF's HarfBuzz (decided at D4) |
| `PrintLayout` | `PdfCore/Printing` | printing through `NSPrintOperation` with our own page drawing |
| `Redaction`, `RedactionPatterns`, `RedactionCheck`, `Sanitizer` (with `HiddenContent`), `StructTree`, `DocumentInventory`, `InventoryReportFiles` | `PdfCore/Redaction` | E1 (the inventory: E1a); `FormEditor.ClearFields` there too |

Everything else in `InkvoltPdf.Core` came with the steps below.

### Steps

As for Print: each step ports the module's .NET tests first, under the same names, then the code until they pass. All
are done; what differs is under "Mac differences" below and in the sections after it, and what a person must still look
at under "What a person must look at" and in each section.

| Step | What | .NET tests ported |
|---|---|---|
| D0 | MuPDF for the Mac: `Vendor/mupdf/build.sh` (pinned tag, the Windows app's 1.25.2 or the current release), the XCFramework, `CMuPDF`, the package skeleton, the CI job; open a test PDF, draw a page, read its text |  |
| D1 | Engine: open (passwords), page geometry, rendering (regions, cancel), text and words, links, outline | EngineTests, Core1EngineTests (with Core1TextTests), PageTextTests, Core1NavigationTests (the reading parts) |
| D2 | Document session, edit transaction, undo steps, incremental save, kept protection, passwords, recovery | EditTransactionTests, RecoveryTests, KeptProtectionTests, SecurityTests, OwnerPasswordTests, SessionProtectionTests, PasswordStrengthTests, SignedEditTests |
| D3 | Pages: organize, ranges, insert from files and images, bookmarks | PageEditorTests, PageRangeTests, PageStructureTests, ImageImportTests, BookmarkTests, BookmarkTreeTests |
| D4 | Comments, drawing, stamps, images, text shaping for their appearances | DrawingAnnotationTests, DrawingGeometryTests, RubberStampTests, TextStampTests, Core2StampTests, LinkAndImageTests, ShapingTests, BidiLineTests |
| D5 | Forms: fill, appearances, actions, form JavaScript (JavaScriptCore), Fill & Sign | FormTests, Core2FormTests, FormActionTests, FormAppearanceTests, JsFormTests, Core2ScriptTests, TabLabelTests |
| D5a | Edit text and images: the page's own text (ContentEditor, ContentLexer, the fonts it needs) and pictures | ContentEditorTests, ContentEditFontTests |
| D5b | OCR: Vision's recognizer behind PdfCore's recognizer function, the invisible text layer (TextLayer) | TextLayerTests, ScanPdfTests |
| D5c | Export to Word, Excel and text (DocLayout, DocxWriter, XlsxWriter, DocumentExport, ExportGlyphs, ExportPage) | ExportTests, ExportPipelineTests, ExportFormTests, ExportRealWorldTests; `pdf/tools/export-corpus` on the Mac |
| D6 | Print layout | PrintLayoutTests |
| D7 | The app: document windows and tabs, the page view (tiled rendering, selection, find, VoiceOver), the side rail, tools, start page, settings, recovery prompt; Open in Inkvolt PDF from Inkvolt Print |  |
| D8 | Release: Developer ID certificate, hardened runtime, notarytool with the API key, the DMG, Sparkle 2 (EdDSA key, appcast and where it's hosted), notices and the source offer |  |
| E1 | Redaction (with redaction by pattern), the redaction check, Sanitize Document | Core2RedactionTests, RedactionPatternTests, RedactionCheckTests, SanitizerTests |
| E1a | What's in This PDF (roadmap 2.5), over E1's Sanitize | DocumentInventoryTests |
| E2 | Digital signatures: verify (the Signatures pane, the bar), Sign Digitally | Core2SignatureTests, IncrSignatureTests, SignatureChangeTests, SigningTests |
| E3 | Compare Files | CompareTests |
| E4 | Reduce File Size, Flatten, Header & footer, Watermark | OptimizerTests, FlattenTests, HeaderFooterTests, WatermarkTests |
| E5 | Prepare Form: the field kinds, placing, moving, resizing and editing fields, their properties, Tab order, Detect Fields | FormDesignTests, FieldDetectionTests |
| E6 | Measure: distance, perimeter, area, Calibrate, Set Measuring Scale | MeasurementTests |
| E7 | Save as PDF/A-2b, and Batch's Save as PDF/A | PdfATests |
| Pro | Inkvolt Pro: the licence key, its check, Help › Inkvolt Pro… | ProTests |
| 2.4 | Make Accessible, the Reading Order and Alt Text pane, Save as PDF/A-2a, and Batch's actions for them (roadmap 2.4) | AutoTagTests, AutoTagKindsTests, FontUnicodeTests, ReadingOrderTests |
| E8 | Batch, with presets, watched folders and the command line (roadmap 1.2) | BatchTests, BatchAutomationTests |
| 1.3 | Accessibility checker (the Mac half of roadmap 1.3; Make Accessible is roadmap 2.4) | AccessibilityCheckTests, HostileStructureTests |
| E11 | AI assistant (bring your own, off by default): Summarize, Ask about this document, Explain selection, the window that shows what goes where | AiTests, AiReviewTests |
| E12 | PDF from Office files and web pages: File › New PDF from Office File… and from Web Page…, the start page's Create a PDF card, and Office files and saved pages opened from Open, the Dock or Finder | ConversionTests |
| E10 | Read Aloud: View › Read Aloud (⇧⌘Y) from the top of the view or the selection, the sentence and word highlighted and followed, a bar with previous and next paragraph, pause, stop, the voice and the speed | ReadAloudTextTests |
| E9 | Attachments and layers: the sidebar's Attachments pane (attach, save, open attached PDFs, remove) and Layers pane (show and hide for viewing and printing, Reset, Save as Default) | Core2FeatureTests (attachments and layers), the attachment parts of Core1XmpTests, IncrSignatureTests and SignedEditTests |
| E13 | Split view: View › Split View (Top and Bottom, Side by Side, Remove Split, Switch Pane), two places of the same document at once | (none: Windows' `DocumentTab.Split.cs` is app code with no unit tests) |
| E14 | Better OCR, stage A (roadmap 2.2): cleaning before recognition, suspect words, writing the cleaned page back | ScanCleanupTests, ScanTextTests, SuspectWordsTests, OcrCorpusTests |
| E14a | Suspect words for Batch, Scan and export (roadmap 2.2; Windows 2026-11-04, commit 6f7b8a8) | BatchTests.ocrKeepsTheRecognizersSuspectWordsForReview, ExportPipelineTests.theRecognizersSuspectWordsAreCounted, ScanTextTests.aPageRecognizerMarksSuspectWordsAsRecognizeTextDoes (Mac only) |
| E15 | Export to PowerPoint and HTML (roadmap 3.2): File › Export To › PowerPoint Presentation… and HTML Web Page…, Batch's two actions | ExportPptxTests, ExportHtmlTests, ExportPipelineTests and BatchAutomationTests (their PowerPoint and HTML cases), BatchTests.ExportsToPowerPointAndHtml |
| E16 | Speed on huge files (roadmap 3.6): the benchmark, then Find across long documents | FindAllTests |
| 2.3 | USB scanners, the Mac's leftovers (roadmap 2.3): leaving out blank pages, scan presets, the scanners Inkvolt Print remembers | UsbScannerTests (PrintCore; the WIA and TWAIN ones stay with Windows) |
| 3.7 | Spanish interface (roadmap 3.7's Mac line) and What's New in Spanish for both Mac apps | PdfStringsTests, ShownStringsTests, CoreStringsTests (PrintCore's target: the PC and the mac job) |
| 3.6b | A hostile file's time: page checks (Windows' `PageChecks`, 2026-11-05), in process | PageCheckTests |
| 3.5 | Indexed folder search (roadmap 3.5's Mac line): Edit › Find › Search Folders… (⌥⇧⌘F, the command palette) over folders indexed on this Mac | IndexTermsTests, FolderIndexTests, FolderIndexerTests |
| 3.3 | Compare: Office files, scans and formatting (roadmap 3.3's Mac line), on E3's Compare Files | CompareChangesTests, CompareAlignTests, CompareContractTests (and CompareTests, E3's, unchanged) |
| 2.1 | Paragraph text editing (roadmap 2.1's Mac line): Edit Text & Images rewrites a paragraph in its box, characters its font lacks from fonts on this Mac, looks for a selection, text in form XObjects, turned text | ParagraphEditTests, ContentEditorTests, ContentEditFontTests |
| 3.1 | Translate side by side (roadmap 3.1's Mac line): Tools › AI Assistant › Translate with AI…, a translated copy beside its original, through the user's own AI endpoint | TranslationReplyTests, TranslationRunTests, TranslationLooksTests, TranslationMarkupHostileTests, TranslationCopyTests, TranslationLinkTimingTests |
| CB | The command bar (Windows' 1.12 design, docs/design/command-bar.md): the toolbar's groups Edit, Convert, Comment, Fill & Sign, Organize, Protect, Scan & OCR as split items, the icon-only pointer tools, the one-click jobs, the bar's colours | CommandBarLayoutTests (the table), BarColorsTests, ExportTargetTests → `CommandBarTests`, `ExportTargetTests`; ReservedFileNamesTests (PrintCore) |
| 4.18 | Mark All Matches (roadmap 4.18): Edit › Find › Highlight, Underline and Strike Out All Matches, after a search with the Find bar (`SearchMarks`, `MarkMatches.swift`; `--edit --only-text-tools` drives it) | SearchMarksTests |
| 4.15 | Links from Addresses (roadmap 4.15): Tools › Annotate › Links from Addresses…, the addresses listed to untick, the ticked ones made links in one step (`AddressLinks`, `Links.putOnTexts`, `LinkAddresses.swift`) | AddressLinksTests |
| 4.6 | Copy Text from Area and Copy Area as Table (roadmap 4.6): Edit's two commands on the last Snapshot box, or the next one drawn; the snapshot's notice offers Copy text; a box without text read with Vision (`AreaCopy`, `AreaCopyActions.swift`) | AreaCopyTests |
| 4.1 | Spell check where people type (roadmap 4.1): the paragraph editor, notes, text boxes, callouts, replies, the inspector's text, a run of page text and form fields; suggestions, Ignore Spelling, Add to Dictionary; Settings › Check spelling as I type (`SpellChecker` in PdfCore/Text, the app's `SpellCheck`, `SpellingField`, Spelling.swift) | SpellCheckerTests |
| 4.2 | Find and Replace across the document (roadmap 4.2): Edit › Find › Find and Replace…, a sheet listing every match with its page and the words around it as it is typed, Replace and Replace All (one undo step, one save, what couldn't be replaced as asked listed) (`TextReplace`, `ContentEditor.paragraphsOf`/`replaceParagraphIn`, ReplaceSheet.swift) | TextReplaceTests (with `ReplacedTextReadsTheSameInPdfJs`, opt-in) |

From the steps, besides the sections below:
- D8: `release.sh --publish` rebuilds and re-notarizes, so the published DMG's SHA-256 differs from the one verified
  before it.
- E12: Microsoft Word, Excel or PowerPoint convert first when installed, but that is **off** until a person runs the
  checklist ("Microsoft Office as E12's converter"); a real LibreOffice and a real web address were never run (a made-up
  `soffice` and a saved page only).
- E13 split view: Switch Pane is ⌘' (Windows: Ctrl+F6; on the Mac ⌃F6 is macOS's keyboard navigation and ⌃⇥ the window
  tabs' next tab), and F6's cycle through both panes has no Mac counterpart (Tab and ⌘' reach them). Not checked by a
  person: dragging the bar between the panes, the accent frame, VoiceOver naming the second pane.
- E10 Read Aloud (AVSpeechSynthesizer): a real voice was never heard by a person.
- E14a: `PageOcr.recognizer(_:options:spelling:)` is a page recognizer through `ScanText` with Recognize Text's choices,
  so the words it marks stay marked (`…SuspectWordsAsRecognizeTextDoes`, Mac only). Not checked: a real scan or Batch run
  with Vision and the Mac's dictionary.
- E15: census-p60 page 16's line chart is short stroked segments whose boxes are over 3 pt on the Mac, so they are kept as
  27 pictures where Windows makes them lines. Not checked: the .pptx in PowerPoint for Mac or Keynote.
- E16: FindAllTests ported, two adapted (the Mac's `findAll` returns its pages and hands them to `onPage` where Windows'
  is an enumeration); FindWorkerTests has no counterpart (below).
- 2.3: no black and white (the Mac's scans are color or grey), so a preset has no `BlackAndWhite`; text recognition is
  always available (Vision); the pages become the PDF through PdfCore's `ImageImport`, so the page-assembly tests count
  the pages kept instead of opening a PDF.
- 3.7: the menu bar is built by the app, so its standard menus and items carry macOS's own Spanish names (Archivo,
  Edición, Visualización…), `DocumentCommand.shownTitle` over the English `title` that stays the identity. The Mac's own
  wording for the owner: `pdf/docs/SPANISH-REVIEW.md`, "Inkvolt PDF for Mac".
- 4.18: the commands are in Edit › Find and are off until Find has matches (Windows opens its Search pane and says to search
  first); the marks take the Highlight, Underline and Strike Out tools' colours from the markup toolbar, as Highlight
  Selected Text does on the Mac. `Annotations.read` now reads at most `Annotations.maxQuads` (20,000) + 1 lines of a text
  mark, as Windows' `QuadRectsOf` (the Mac read every line before). Not checked by a person: the marks on screen.
- 4.15: Windows' pattern runs in ICU (`NSRegularExpression`, offsets in UTF-16 as `PageText`'s), which has no time limit
  like .NET's 1 s: the pattern can't start inside a word (its look-behind) and its domain labels are bounded, so a page's
  text is scanned in one pass. The command is in Tools › Annotate beside Link Selected Text… (Windows: Review, Edit on
  the bar); with nothing ticked, the notice says to tick one (Windows keeps its dialog open). Not checked by a person: the
  list's look with long addresses, VoiceOver on it.
- 4.6: the text's lines end with LF and a table's rows too (Windows' clipboard has CR LF); a table goes on the pasteboard
  as tab-separated text and as HTML (`.html`, the fragment alone: Windows' CF_HTML header, `ClipboardHtml`, has no Mac
  counterpart, so `TheClipboardsHtmlHeaderPointsAtTheFragment` keeps its HTML and tab checks only). The Snapshot box isn't
  outlined after it's drawn (Windows outlines it until another tool is chosen): it stays the area to copy while the
  document is unchanged. Copy Text from Area with no box picks Snapshot and the next box copies words instead of a
  picture. The notice says Numbers, Excel or Pages where Windows says Excel or Word. Not checked by a person: pasting
  into Numbers and Excel for Mac.
- 4.1: the dictionary is `NSSpellChecker` (`MacSpelling`, the closest dictionary the Mac has for the language; Add to
  Dictionary is macOS's Learn Spelling, the self-test's kept for its run only). The app draws the underlines itself (a
  temporary spelling attribute on the editor's layout manager, from `SpellChecker.check`, the editors' own continuous
  checking off) and puts its items at the top of the editor's menu (macOS's own spelling items taken out), so every editor
  follows PdfCore's rules where Windows' plain text boxes use WPF's speller and then drop the words ignored: on the Mac one
  path for all. A text field's field editor is shared by the window, so `SpellingField` clears its underlines when editing
  ends. Ignore is "Ignore Spelling" (macOS's name), for the session in every editor. The third language tried is the Mac's
  (`Locale.current`) where Windows tries Windows' display language. Not checked by a person: the red underline's look,
  the menu by Control-click and from the keyboard, VoiceOver reading a misspelled word.
- 4.2: matching is Foundation's (`NSString.range(of:options:)`, case-insensitive unless Match case) where Windows uses the
  invariant culture's `CompareInfo`; offsets are UTF-16 as on Windows. `ContentEditor.replaceParagraph` now opens the
  document and calls `replaceParagraphIn` (Replace All's per-paragraph path), as Windows' does. The command has no key
  (Windows: Ctrl+H; ⌘H hides the app, ⌥⌘F is Prepare Form's) and is off while Organize Pages shows. Replace from the sheet
  shows no progress (one paragraph); Replace All shows it page by page with Cancel. `nextAfter` gives nil where Windows'
  gives -1. Not run here: `ReplacedTextReadsTheSameInPdfJs` (INKVOLTPDF_PDFJS, needs Node on the Mac). Not checked by a
  person: the sheet's look, VoiceOver on its list.
- Mac additions: Prepare Form's arrow-key move (written after 0.45 s) is flushed when the document is asked to close
  (`PdfDocument.canClose`), so ⌘W saves or asks about it; HybridXref's xref stream gives up past 64 MB on both
  (`HybridXref.MaxStreamBytes`); `PngDecoder` inflates only the bytes its size needs, as Windows' `ReadExactly`.

### Mac differences

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
  is `PdfCore/Text`, not `PdfMac/Text`. MuPDF keeps numbers as 32-bit floats, so colors read
  back rounded to 4 decimals; link addresses go through our own parser (with punycode) where .NET uses `Uri`; stamp
  dates follow a given `Locale`.
- Form scripts: JavaScriptCore has no public time limit, so its watchdog (`JSContextGroupSetExecutionTimeLimit`, a
  private API declared in the `ScriptLimits` C target) stops a script after 0.5 s of CPU (2 s per run); fine for a
  Developer ID app (no App Review), but Apple may change it: the fallback is running scripts on a thread that is abandoned
  when late. No heap limit: the prelude caps arrays at 100,000 items and strings at 1 M characters. The host's submit
  answers yes or no (Windows: a task); dates are matched by our own parser (Windows: .NET's); XFDF with a DTD is
  refused. The code is `PdfCore/Forms`.
- The tests write their PDFs by hand (`TestPdf`, `Core1TestPdf`); encrypted ones are written by MuPDF (AES-256), where
  the Windows tests use PDFsharp.
- The app (D7 part c): Fill & Sign's signatures and initials are kept between launches since 2026-11-03, as Windows'
  library (up to three signatures and one set of initials, PNG files in Application Support's "Inkvolt PDF/signatures";
  `SavedSignatures` in PdfCore, tested by SavedSignaturesTests, a Mac addition: Windows' library has no tests); the
  Signature menu lists them with their pictures, Draw and Type make a new one (disabled with three saved), and Delete a
  Saved Signature asks first; the menu bar's Tools › Place Saved Signature lists them too; Sign Digitally's Image picks
  any saved signature (Windows: the same). Form data goes in and out as XFDF and FDF only (Windows also CSV and JSON), through
  `FormEditor.resetForm`, `exportData` and `importData`, which have no .NET counterpart file (their tests:
  FormDataExchangeTests); a choice field opens as a menu under the field (Windows: a drop-down editor); messages the
  Windows app shows as notifications go to a bar over the pages.
- The app (D7 part d): the close and quit questions are AppKit's (NSDocument: Save, Don't Save, Cancel for each document;
  quitting with several changed documents first offers to review them); the self-test answers them through the same
  callback (`PdfDocument.testCloseAnswer`). Printing goes through `NSPrintOperation` and the standard panel (printer,
  copies, paper, orientation, preview) with Inkvolt's options in its accessory view (the document's page range, one page
  per sheet at actual size or fitted, pages per sheet, booklet, poster), the sheets laid out by `PrintPlan`. Vector
  printing (2026-11-06, `PdfCore/Printing/PrintCopy`, PrintCopyTests): on paper each page is drawn by Core Graphics
  (`CGContext.drawPDFPage`, through `PrintLayout.toPaper` and the page's `toPageMatrix`, clipped to its box: poster tiles
  too) from a print copy made in memory before the print panel opens, off the main thread (a sheet with Cancel after
  0.3 s; Cancel prints nothing): the bytes the view engine shows (the layers chosen made again from the document's,
  not kept beside them), every comment and form field (signatures too) drawn into its page by its own appearance
  (`Flattener`; the file's own, never one made again, as MuPDF ignores /NeedAppearances), decrypted, and always written
  by MuPDF (since the hostile-input review, 2026-11-07: Core Graphics read the document's own bytes when nothing needed
  flattening, and could resolve an object defined twice or a broken cross-reference table differently from MuPDF's
  repair; no copy is written when no page prints as vectors, and the document's own bytes print when MuPDF can't write
  one that needed nothing flattened or decrypted); Core Graphics reads it in place (one buffer). Core Graphics draws with
  no bound, so each vector page is first read through the bounded engine without drawing (`PrintCopy.bound`,
  `PdfEngine.readThrough`: the stream checks, the reading in pieces under the 10 s budget, each picture by its header's
  size, none decoded; up to eight engines on the copy's shared bytes at once), unless the view engine read it within its bounds
  already (`verdictOf` passed in): a page refused prints as a picture, which the engine refuses too, so the sheet shows
  the refusal's sentence in the page's box (Windows prints a refused page blank). A page the view engine found too slow
  is read again (its drawing may be what took the time; reading alone takes 10 s only for a bomb or a pathological
  stream, which Core Graphics would read without a bound); a MuPDF error that isn't a refusal keeps the page in vectors.
  The review's figures, `PrintCopyBench` on ignia-mac (busy with other builds, load 4 to 10), nothing rated by the
  view yet: the bench's 500-page scan 0.17 s before the bound, 7.8 s with the 24 px drawing, 0.28 s now; its 400-sheet
  drawing set (72,000 paths a sheet) 0.13 s, 92 s, 7.9 s now, of which MuPDF's writing is 0.4 s and the rest reading
  every sheet's paths once. Pages the view has shown cost nothing more. The rule: paper never shows more or less than the screen, and when unsure the page is
  a picture. `Flattener.Look` is MuPDF 1.25's drawing rule (pdf_process_annot, the appearances it makes up at load),
  used both to draw and to classify: nothing for a link or popup, the Invisible, Hidden and NoView flags, a widget of
  no field (no /FT or /T), a /Rect without area (an invisible signature); a page prints as MuPDF's 300 dpi picture,
  as every page did before, when MuPDF draws an appearance flattening can't (none of its own, an /AS state its
  appearances lack, an unsigned signature's "sign here" box, a box without area), a note kept upright (NoRotate) on a
  turned page, a /Rotate that isn't a quarter turn, a size, box or turn Core Graphics reads differently (/UserUnit,
  broken boxes; `PrintCopy.checked` per page), or no copy at all (Core Graphics can't open it or MuPDF's rewrite of
  it). File › Flatten draws by the same rule (a popup's appearance is no longer drawn into the page; Windows draws
  it). The panel's preview stays the engine's pictures and never makes the copy. Dark Pages
  only colors the screen. A font the file doesn't embed is Core Graphics' choice on paper (MuPDF's on screen).
  Self-test (`--only-print`): 20 KB on paper against 456 KB as pictures for the synthetic document, its words found as
  text, every layout's ink where the pictures put it. Pages larger than 16
  megapixels at the zoom shown are drawn in 512-pixel tiles of the part in view over a 16-megapixel picture of the page.
  Links open as on Windows: a page or web and mail addresses at once, any other address after "Open this link?". New
  bookmarks go after the one selected and are named in a sheet (Windows edits the title in the list). Extract writes one
  PDF (opened in a tab unless unticked); Windows also offers a file per page. The Mac's additions are on Windows
  too since 2026-11-17: the Polygon and Polyline tools (the same keys V and Z; Windows' `VertexDraft` also takes a corner
  back with Backspace and keeps Shift's 45° steps), and moving and recoloring sticky notes and text marks
  (`Annotations.move`, `Annotations.setColor`, CommentMoveTests; Windows' `Annotations.Move`, `SetColor`, the same tests).
  Windows differs: its hand tool pans over a text mark that isn't selected (a click selects it, then a drag moves it), a
  recolor also recolors the replies lying on a note and keeps another app's note icon, and a move takes replies of every
  kind with it; the Mac picks a mark up at once and redraws any note as its bubble.
  A text mark over a selection across pages is one undo step.
- The app (D7 part e): the start page is a window of its own (Windows: the main window's page while no tab is open) that
  steps aside when a document opens; its recent list offers Open and Show in Finder (AppKit keeps the list, so no Remove
  from List). Combine Files is a window (Windows: a dialog). Scans, combined files and PDFs from pictures or the clipboard
  open as unsaved documents named with the date (Save asks where), as Windows' new tabs. Scan finds scanners through
  Bonjour (`_uscan`, `_uscans`, listed in `NSBonjourServices`; Local Network asks the user once) and ImageCaptureCore for
  USB, and lists the printers Inkvolt Print remembers first (its hand-off in the app group, `SuitePrinters`, since
  2026-11-06; its own state file lives in its sandbox container); "Make the text searchable"
  runs Recognize Text on the new document (its own undo step), where Windows adds the layer before opening; each scanned
  JPEG gets the scan's resolution in its JFIF header, so `ImageImport` makes the page its real size. Settings leaves out
  what the Mac doesn't have (dark pages; reopening the last files, which macOS's window restoration does) and
  says how to make Inkvolt PDF the default PDF app (Finder's Get Info) instead of a Default apps button;
  "Open documents at" (fit width, fit page, actual size) is the Mac's, where Windows reopens with the last zoom mode;
  update checks are Sparkle's automatic checks. The command palette is ⇧⌘K (⌘K is Link Selected Text, ⇧⌘P Page Setup)
  and lists the menu bar's own items, each checked along the front window's responder chain. The self-test keeps its
  settings in a defaults suite of its own.
- Rotate view: View › Rotate View Clockwise (⇧⌘R) and Counterclockwise (⇧⌘L) (Windows: Ctrl+Shift+Plus
  and Minus) turn the active pane's view only; a second pane starts at the main pane's turn, then turns on its own.
  `PagesView` lays the pages out turned and maps every page point through `viewRect`, `viewPoint`, `pageSpace`,
  `page(at:)` and `pagePoint` (`RotatedView`), so links, the selection, fields, comments, Prepare Form and Measure follow
  it; the page pictures and tiles are drawn as rendered, under a turned transform (Windows renders them turned).
  Arrow keys move comments and Prepare Form's fields the way they point on the screen, as Windows' `Nudge`. A field's
  or the text editor's box sits over the turned field upright (Windows turns the editor). Labels (Measure's value,
  reading order's numbers) stay upright. Going to a spot down a page (a bookmark, a link's target) goes to the page's top
  on a turned view, as on Windows, and Add Bookmark takes the page's top. The turn is remembered per file with the page
  (Reopen at last page). Thumbnails, printing and export stay as the file is. ViewTest (`--only-view`) checks it.
- Dark pages: View › Dark Pages (Night Reading) (Windows: the View menu and the look bar) and Settings'
  "Dark pages" box, one setting for every window (`DarkPages`, as Windows). `NightColors` in PdfCore is the Windows
  viewer's map (lightness flipped, hue kept, 26...226), tested by NightColorsTests (a Mac addition: Windows' map is
  private to its viewer, untested); `PageRenderer` applies it to the page views', thumbnails' and organizer's pictures
  as they are drawn, and the paper under a page is dark grey. Windows leaves pages alone in a high-contrast theme; the
  Mac does when Accessibility's Invert colors is on (the screen is inverted already). Fields lose their tint (as
  Windows). Printing, export and the file are unchanged. ViewTest checks it.
- Thumbnail drags: the sidebar's thumbnails drag to move pages (one undo step, "Move N pages"), onto
  another window's thumbnails to copy them there ("Copy N pages from …"), and take PDFs and pictures dropped from the
  Finder (inserted where dropped), as Windows' thumbnail list. Only a PDF's first file of a multi-file drop is
  inserted, as Insert Pages from File. Drag starts are AppKit's (NSTableView), so the self-test drops through the same
  `drop(_:before:)` with its own pasteboard (ViewTest): the mouse part of a drag isn't exercised over SSH. The organizer
  keeps its own drags (moving only).
- Reading modes: View › Single Page (⌘4), Continuous (⌘5), Two Pages (⌘6), Two Pages with Cover (⌘7), as
  Windows' Ctrl+4…7, for the active pane, kept as the mode new windows open with (`Layout`, the Windows name and
  values); a second pane starts in the main pane's mode. `PagesView` lays out pairs in rows (the cover alone on the
  right, odd pages on the right after it, as Windows' `Relayout`), and Single Page lays out only the page shown; going
  to a page, a find match, a flashed or revealed comment and Read Aloud's word show their page first
  (`prepareToShow`). Single Page turns past a page's end by the scroll wheel (a pull of 60 points at the edge, not
  momentum), Page Down, Space and the arrows; Home and End go to the first and last page. A file's own /PageLayout
  isn't read yet (Windows opens it the way it asks). ViewTest checks it.
- Insert from Scanner: Pages › Insert from Scanner… (Windows: Organize › Insert from Scanner…) opens the
  Scan window for the document: its title and button say Insert, a row picks where (after or before the current page,
  at the start, at the end; Windows' position picker), and Insert Pages puts the scanned pages there as one undo step
  ("Insert N pages from the scanner"); "Make the text searchable" then recognizes the inserted pages (its own undo step,
  as Scan's new PDF). The place is clamped to the document as it is then, as Windows. AppTest drives it with Inkvolt
  Print's demo scanners; no real scanner was used.
- Report a Problem: Help › Report a Problem… (Windows: the same) shows the details (the version, macOS
  and its architecture, the settings Windows lists that the Mac has, plus the reading mode), masked by PrintCore's
  `Diagnostics.scrub`, editable before Copy; Copy and Open a GitHub Issue copies them and opens a prefilled issue. The
  report, log tail and issue address are `ProblemReport` in PdfCore (Windows' shared `Diagnostics.Report`, `Tail`,
  `IssueUrl`), tested by HelpTests' five report, tail and issue tests (same names; a stand-in scrub, the masking being
  DiagnosticsTests'). Differences: "macOS:" where Windows writes "Windows:" and .NET's version; the Mac app keeps no
  log, so the report says "(no log yet)". Nothing is sent.
- Go to Page: Go › Go to Page… (⌥⌘G; ⌘G is Find Next on the Mac) asks for a page number or the page's
  label as the file names it ("iv", "A-3") in a sheet, a matching label first (Windows: Ctrl+G focuses the toolbar's
  page box, which takes the same; the Mac has no page box, the window's subtitle shows the page). Nothing matching:
  asked again with the range. `DocumentFeatures.findPageByLabel` and `findPage` (Windows' `DocumentTab.FindPage`) in
  PdfCore; Core2FeatureTests' `ReadsPageLabels` and `HostilePageLabelsAndCyclicTreesStayCheap` ported. ViewTest checks
  the command.
- Document Properties: File › Document Properties… (⇧⌘I; Windows: Ctrl+D, which the Mac keeps for Add
  Bookmark, and ⌥⌘D is the Dock's) is a sheet with Windows' rows (file, location, size, pages, the current page's size,
  PDF version, security, the app that made it, producer, dates; a row without a value left out) and Title, Author,
  Subject and Keywords to change as one undo step ("Edit document properties"); What's in This PDF… opens the inventory
  from it. The Security line is `SecurityInfo.summary` in PdfCore (Windows' `SecurityActions.Describe`, untested there;
  SecurityTests' `documentPropertiesDescribesTheProtection` is a Mac addition). `PageEditor.readMetadata` and
  `writeMetadata` and their tests were already ported. Dates in the Mac's short date and time style (Windows: "g").
  PagesTest checks it.
- Reverse Page Order: Pages › Reverse Page Order (Windows: Organize › Reverse Page Order), one undo step
  ("Reverse page order"), enabled with two pages or more; the chosen pages stay chosen at their mirrored places, as
  Windows. `PageEditor.reverse` and its tests (`ReversesPages`, the labels in `PageLabelsFollowTheirPages`) were
  already ported. PagesTest checks it.
- Extract Pages and Split Document: Pages › Extract Pages… (Windows: Organize › Extract Pages…) asks which
  pages (the chosen ones filled in) and where to: a new document (a window; Windows: a tab), one PDF file (the save
  panel), or a separate PDF file per page in a folder ("name (page 3).pdf"), and can delete them from the document
  after (one undo step; never every page). Pages › Split Document… (Windows: Organize › Split Document…) splits by a
  number of pages, page ranges separated by ; or the top-level bookmarks (the pages before the first are a part of
  their own) into a folder, named by a pattern ({name}, {n}; a bookmark's title added). Every name is picked before
  anything is written, a name already there gets " (2)", and no file is replaced; a failure says which files were
  written (`SplitFiles` and `BatchWriteError` in PdfCore: Windows' `Organize.Split` checks, `PdfFiles.UniquePath`,
  `WriteBatch` and `BatchWriteException`). A password-protected document asks once before its pages are written
  without the password, as Windows. Differences in the names: "/", ":" and control characters become "_" (Windows:
  its own invalid characters and device names such as CON), and a name is cut to fit the Mac's 255 bytes (Windows: the
  259-character path). Windows has no tests for these (app code): SplitFilesTests (3) is a Mac addition. PagesTest
  checks the file per page, the new document, a split by count twice (numbered names) and at the bookmarks.
- Form fields' hover actions: a field's /AA /E and /X actions run as the pointer enters and leaves it with a
  tool that fills fields (`PagesView.hoverField`, from the page view's mouse moves and its exit, `FormFiller.hover`),
  through `FormEditor.runAction` as clicks and focus changes are; a hover while another action is queued or running is
  dropped (Windows' `SetHoverWidget` and `QueueWidgetAction`). The core and FormActionTests'
  `HoverRunsScriptsWithoutDialogsPrintingOrOutwardActions` were already ported. AppTest checks it on a small form made
  there.
- An attached PDF with its own password: Open (the Attachments pane) asks for the attached file's open
  password, again after a wrong one, and opens it with it as a new unsaved document; Cancel opens nothing (Windows'
  `OpenAttachment`). Windows has no test for it (app code); AttachmentsLayersTest checks it with a protected PDF attached there.
- Compare's zoom and start-page card: the Compare window has −, Fit and + (⌘-, ⌘0, ⌘=; 10 % to 800 %,
  from the shown scale by 1.25), the rows as wide as the zoom needs with a horizontal scroller, the row in view kept in
  view; Fit fits the window's width again (Windows' `CompareWindow` Zoom and SetZoom, Ctrl and the wheel there; the Mac
  has no ⌘-wheel zoom here). The start page has a Compare files card after Combine files, as Windows, asking for the two
  versions as File › Compare Files… does. No Windows test (app code); CompareTest and AppTest check them.
- Export with the layers shown: File › Export To… reads the document with the layers shown or hidden as
  in the Layers pane (`exportEngine`, over `Layers.withVisibility`, as printing already did; Windows exports from its view
  engine); PowerPoint and HTML still read the language and alternate text from the document's own bytes, as Windows.
  AttachmentsLayersTest checks it.
- Resizing and nudging pictures in Edit Text & Images: the selected picture shows eight handles; dragging
  one resizes it (Shift keeps its proportions), the arrow keys move it (Shift: 10 points; the moves add up and are
  written as one step once the keys rest for 0.45 s, before anything else acts on the picture, and before the window
  closes), as Windows' `PageViewer.EditContent`. `ContentEditor.moveImage` (any box) and its tests were already ported.
  Fixed on the way: after a move the selection was dropped (the document's own change notice read the page again and
  looked for the picture where it had been); it is now found where it went. FeatureTest checks the handle and the keys.
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
- What's in This PDF (E1a): the report is opened from the Tools menu, the Sanitize sheet and Document Properties (since
  2026-11-03), as on Windows. Attached files are listed by the inventory's own
  reading of the EmbeddedFiles tree and attachment comments (Windows calls `Attachments.List`; the Mac's
  inventory still reads them itself, though E9 brought `Attachments`). The sheet shows at most 300 items per section, with how many more there are (Save Report lists them all;
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
  device names, 120 characters) so results move between the two. The watched folder takes a file only when `open` with `O_EXLOCK` gets
  it (an app that locks what it writes keeps it off; the quiet period covers the rest) and holds `.inkvolt-watch.lock`
  with flock. The command line is the app's binary (`/Applications/Inkvolt PDF.app/Contents/MacOS/InkvoltPdf`);
  `--fill` (the form merge, `FormMerge`) came with 1.4.
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
- Make Accessible (2.4): the commands are in Tools (Windows: Review) and File › Save as PDF/A-2a; the Reading Order pane is
  an inspector on the right of the pages (Windows: a pane on the left), with buttons for the moves and Done. Suggest with AI came with E11. A piece
  read with another page doesn't scroll the pages to its box when selected. The writer builds the tree in Swift classes
  and writes each /K at the end (Windows keeps PDF arrays as it goes); the same elements, order and keys. A form's own walk
  doesn't follow the forms it draws: Windows' `PageWalk` does, without end for a form that draws itself when it holds
  /Artifact (reported, not fixed there); `formInfo` reads each form once, so forms drawing each other many times end. The
  standard fonts come from the Mac's twins, as E7's. The texts say "this Mac" and Tools where Windows says "this PC" and
  Review. **A person must look at** (the Mac's self-test checks the behaviour and PNGs of the window were looked at by the
  agent, which can't see focus or live drawing): the Make Accessible sheet's layout and its re-ask on a missing title; the
  pane in light mode and at its narrowest (280 pt); whether the selected row is highlighted in the list (the PNG doesn't
  show it); drag to reorder; numbered boxes on a real document (badges overlapping tight lines, as Windows); VoiceOver
  reading the rows and announcing a move; Page Up/Down on a keyboard without those keys (fn+↑/↓). The whole self-test's `--snapshots` stall seen with E5 was most likely AppKit opening the folder argument as a document and stopping on its modal alert (not tested again); the self-test now turns that off (`NSTreatUnknownArgumentsAsOpen`). Help › Inkvolt Pro… threw on its first build without a licence (the key box's width pinned before it joined the stack), so the window never showed: fixed here, and it needs the next release.
- Save as PDF/A (E7): the standard fonts are embedded from the Arial, Times New Roman and Courier New macOS ships (the
  same faces, widths and glyph numbers as Windows': the hand-written samples' copies draw identically on both under Core
  Graphics). Windows subsets them with HarfBuzz (`HbSubset`); the Mac has no HarfBuzz subsetter, and MuPDF 1.25.2's
  `fz_subset_ttf_for_gids` renumbers glyphs but maps code points beyond the font's glyph count (’ € • – …) to the old
  numbers, so `TrueTypeSubset` (Foundation only) keeps every glyph's number, empties the ones not used, writes `loca`,
  `glyf`, a (3,1) format 4 `cmap` and a format 3 `post`, and drops the layout tables; no file is refused for it. A
  document saying PDF 2.0 (or below 1.4) comes out as 1.7 with its catalog /Version dropped. MuPDF writes the file (no
  object streams, the metadata uncompressed) and caps a name it reads at 127 bytes, so a structure role name longer than
  that is shortened where Windows keeps it (and fails veraPDF's 6.1.13 on nist-sp800-63-3.pdf; the Mac's copy passes).
  A wrong permissions password for a file that also has an open password is asked again (it doesn't open the file at
  all, so PdfCore says `PasswordRequired`, not `OwnerPasswordRequired`). The app's sheets: the refusal and the result
  list their lines in a scrolling, selectable box (Windows: a message box);
  "sRGB output intent…" keeps its small s (Windows capitalizes it "SRGB"). PDF/A-2a came with Make Accessible (below). Found
  on both platforms and **fixed on both 2026-10-30** (tests by Windows' names in PdfATests): (1) a PDF/A copy keeps XMP
  only in the catalog, and `validate` checks it. Names over 127 bytes (a Word role name): MuPDF cuts a name as it reads it,
  which can make two names one, so `LongNames` reads each object's own text where the table says it is, before any rewrite,
  and gives it back through the shim's `inkv_obj_replace` with the same shorter unique name as Windows' (first 118 bytes, "~",
  8 hex digits); one in page content refuses. (2) A form with Reader usage rights converts, its rights going with a line in
  the changes; a /DocMDP without a signed field refuses ("It is certified…"). (3) A Fill & Sign mark or an IRS check box
  (ZapfDingbats) is embedded from macOS's /System/Library/Fonts/ZapfDingbats.ttf, where Windows uses Segoe UI Symbol: all 187
  codes of the built-in encoding, Adobe's widths (so a file giving them passes), the real shapes, so the change line says
  nothing about shapes differing; its fsType 14 sets editable embedding, and the least restrictive bit counts
  (`TrueTypeSubset.allowsEmbedding`, a refusal by name if a later macOS changes that). Symbolic as on Windows: one (3,0) cmap
  at 0xF000 + code, Flags 4, no /Encoding, a /ToUnicode; a font in the form's /DR is dropped, not embedded. PdfATest now runs
  after FeatureTest's marks. **veraPDF 1.30.3 flavour 2b on E7's inputs (9 samples, 43 real PDFs): 47 pass, 5 fail before; 59
  pass, 0 fail after (the 13 samples, 46 real files; 13 inputs refused instead of 16, the 3 IRS forms now converting).** What a person must look at on the screen (nobody has yet; SSH shows no
  screen): the File menu item; the progress sheet; the permissions password sheet; the refusal sheet with many fonts (rw-in-fa-due-diligence-services.pdf)
  and its scrolling; the result sheet's list and Open the Copy; the save panel (its name "… (PDF-A).pdf", the document's
  folder); dark mode; and a copy opened in Acrobat or Preview.

- Accessibility check (roadmap 1.3): the command is Tools › Accessibility Check… (Windows: Review), the pane is the sidebar's last
  segment, a symbol that appears with the first check. Fixes that name a command name
  the Mac's: File › Remove Password Protection…, Pages › Flatten…, Tools › Prepare Form, File › Document Properties (Windows' words since
  2026-11-03; the language and "Show document title" still say a PDF editor's, as on Windows); the checks that Windows words with Attach a File and Read Aloud
  name the Mac's: View › Show Attachments, then Attach… (21-001), and Read Aloud (⇧⌘Y) or VoiceOver. Saving the report offers Open Report in the pane (Windows: Open on its toast). Text in a corrupt file differs by reader: MuPDF
  rebuilds what it can, so a file PDFsharp refuses is checked as far as it reads (`7.5-t01-fail-c.pdf`, with an external stream: Windows
  says it can't be checked, the Mac fails it, as veraPDF does). Limits Windows doesn't have, none reached by a real file: at most 2,500,000
  parsed drawing steps of forms are kept, a form drawn again isn't read again, 500,000,000 drawing steps per document (then a note),
  16,000,000 places per table (then a note, and that table's cells aren't compared), each rendition and appearance stream walked once, and
  XFA's `dynamicRender` found by a one-pass scan rather than a timed regular expression. `TextFont`'s glyph lookup now follows Windows' (Unicode-platform
  cmaps, Mac cmaps by glyph name), which it had fallen behind.
  Reported, not fixed, on Windows: (a) wcag-table-word.pdf's 15-003 (a known difference in `a11y-corpus`'s README, called a veraPDF inconsistency) is
  Windows' false report: the file has three revisions, and PDFsharp reads an older version of its TH tags, without their /A /Scope; MuPDF reads the
  current ones, so the Mac agrees with veraPDF on this file. (b) `Rendition` has only a depth limit, so a selector listing itself 100 times is
  100^8 walks, with no cancel check. (c) `Table`'s grid can take gigabytes for a crafted table's spans. (d) The XFA regular expression's
  `RegexMatchTimeoutException` isn't among the exceptions `Run` or the app catch (read from the code, not run).
  What a person must look at: everything on screen. Off-screen snapshots of the window (ignia-mac, dark mode) showed the pane's text wrapping, the
  selected row, the orange outline and the checklist as intended, but no one has seen them on a screen or used them with a mouse or VoiceOver. To check: the
  fifth segment's symbol and its tooltip; the sidebar's width once it appears; the outline fading after 2 seconds; light mode; the
  three buttons in a narrow sidebar; a long list scrolling; keyboard from the list to the checklist; VoiceOver reading a row and a checkbox; the saved report in Safari, in both color modes;
  Batch's Add Action listing it.
  Found on the way: AppKit opens any argument naming something on disk as a document, so `--self-test … --snapshots <folder>` stopped behind an error alert
  over SSH; self-test runs now turn that off (`main.swift`). Whether this was also the stall E5 saw on the whole suite wasn't tested.

- Prepare Form (E5): the commands are in Tools (Windows: Edit › Forms; ⌥⌘F for Ctrl+Alt+F), Detect Fields is also Tools › Detect Form Fields, and there is no start page card, as on Windows. The bar
  sits over the pages and the panel is a split view inspector (Windows floats both). The rules of clicks, drags, keys and typed values are PdfCore's `FormDesigner` and `FormDesignRules` (Windows keeps them in
  `PageViewer.FormDesign` and `DocumentTab.FormDesign`, untested), so they are tested on the Mac only (FormDesignerTests). ⌘D duplicates the selected field while the pages have the focus; without one it is Add Bookmark, as
  the menu says. Esc with nothing to let go goes back to Select Text, the Mac's default tool (Windows: Hand). The view doesn't turn on the Mac yet, so moves, handles and arrow keys work in page space (Windows goes through
  `RotatedView`). A list box whose /DV is an array keeps it and its value when moved or otherwise changed; Windows' `SetDefault` cleared both until 2026-10-30 (aListBoxWithSeveralDefaultsKeepsThemWhenMoved). A failed
  move or property change says why in the usual error sheet (Windows' `quiet` edit a toast). `uniqueName` and `nextName` go through `NameBook`, which keeps its place, so a page of 3,600 check boxes is named in moments;
  Swift compares names by canonical equivalence where .NET compares ordinally. The tests draw in the built-in Helvetica through content streams (Windows: XGraphics with embedded Arial): MuPDF's boxes for it are taller, so an
  underscore field's bottom may reach 109 (Windows: 106). SignedFilesGetFieldsAppended uses `Core2SignatureTests.signed()`, which verifies, since the Mac's `SignedEditTests.signed()` has an empty signature. The pages keep their zoom when the panel opens, so a page shown wide runs under its edge until scrolled or zoomed (Windows leaves it room with a margin). What a person must look
  at on the screen (nobody has yet; SSH shows no screen). The self-test's snapshots, AppKit's drawing of the window in dark mode, were read on 2026-10-30: the bar, the panel's rows and the fields on the page lay out as meant. Not seen: a real window; the bar and the panel at the window's smallest size and in light mode; each
  cursor over fields and handles; dragging with a real mouse at 50 % and 400 % zoom; the field names, handles and Tab numbers at those zooms; Return, Esc and Tab in the panel's text boxes; VoiceOver's announcements; Detect Fields'
  sheet and Cancel on a long scanned form; and a form made on the Mac opened in the Windows app's window and in Acrobat.

E14, E15 and E16, what differs:
- **OCR (E14).** Vision's `VNRecognizeTextRequest` returns lines; they're split into words by `boundingBox(for:)` per word
  range (Windows gets words), and its `confidence` is per line and coarse, so the Mac keeps the same suspect-word
  heuristic and names (never a score). The text layer's `%InkvoltOCR` comment lines are kept byte for byte, so a file
  corrected on one platform is reviewed on the other. `MissedLines` (Windows re-reads lines its recognizer skips, and
  "1111") isn't ported: on the OCR corpus Vision skipped no line (word error rate 0-6.3 %; `VisionProbeTests`, opt-in
  `INKVOLTPDF_VISION_PROBE=1`) and read the lines of four 1s; its weak spot is lines of nothing but thin digits in small
  serif type after cleaning. `ScanText.clearlyMore` is ported anyway. The Mac's OCR corpus JPEGs are ImageIO's, so their
  bytes differ from Windows' RESULTS.md (the pixels before the JPEG are the same). Core Image may replace `PageRotate` and
  the median, never the decisions (skew, sideways, upside down, specks), so the tests mean the same.
- **PowerPoint and HTML (E15).** The Open XML SDK has no Swift version: the tests read the zip and XML directly; run the
  SDK's validator on Windows over files the Mac wrote (`ExportCorpus pptx file.pptx`), or open the corpus's .pptx in
  PowerPoint for Mac, or `soffice --headless --convert-to pdf`. `PptxWriter`'s master, layouts and theme are fixed text,
  kept byte for byte.
- **Find (E16).** MuPDF instances don't wait on each other on the Mac (Windows' MuPDFCore wrapper serialises them, hence
  its find workers), so Find reads pages on threads in one process (`PdfEngine.findAll`; the scaling is in
  `mac/tools/bench/RESULTS.md`). One copy of the file's bytes is shared by every engine instance (`SharedBytes`).

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
  makes the key and signing request on the Mac, the owner uploads the request in the developer portal, and
  `devid-cert.sh import` keeps "Developer ID Application: Bermudez Systems LLC (AE6TTXW92K)" (until 2027-11-26) in a
  keychain of its own (`inkvolt-devid`, its password in `.env.local`). Checked: it signs with the hardened runtime and
  Apple's timestamp over SSH.
- AI assistant (E11): the commands are in Tools › AI Assistant (Windows: Review › AI Assistant), Explain with AI on the selection's Control-click menu, and the settings are a sheet opened from there or from a row in Settings. The words say "this Mac" for "this PC" (reach labels, the window, messages). Keys are generic passwords in the login keychain, service `com.bermudezsystems.InkvoltPdf.ai-key`, the endpoint as the account (Windows: `ai-keys.dat`, DPAPI), never in UserDefaults; the settings have the Windows names. The Keychain's access list ties a key to the app's signature, so a development build may ask for it after a release build saved it. Nothing is logged: the Mac has no log of the kind Windows writes these lines to.
  The connection can't be URLSession alone: it can't be told which address to use, and the promise is that a local name only ever reaches a local address. So this Mac and the network go through `AiSocketTransport`: the name is resolved by us, each address checked with `AiEndpoint.allows`, the checked one connected to over Network.framework (several at once, the first to answer), no proxy (`preferNoProxies`), HTTP/1.1 by hand with one request per connection and `Accept-Encoding: identity`, with https verified against the host name in a verify block. The internet goes through URLSession (the system proxy, as Windows' proxy setting; ephemeral, no cookies, cache or kept credentials; redirects declined, so the 3xx comes back and is refused). URLSession adds its own headers (User-Agent, Accept-Language) to internet requests, which Windows' HttpClient doesn't; the socket path sends only Host, the content headers, Accept, the key and Connection. An IPv6 link-local address is connected to without its scope, so a `.local` name that has only fe80:: addresses fails where Windows connects; with an IPv4 address too, that one answers.
  Entitlements: none added, none needed. The DMG app has no entitlements, is hardened and not sandboxed, and hardened runtime doesn't limit outgoing connections. App Transport Security doesn't apply to Network.framework, and URLSession only ever gets https (`AiEndpoint.tryParse` refuses http:// to the internet), so Info.plist has no ATS exception. macOS 15's Local Network permission does apply to a server elsewhere on the network: `NSLocalNetworkUsageDescription` now says so too, and a refused permission reads as "allow Inkvolt PDF in System Settings › Privacy & Security › Local Network". The first connection waits for that question, and is given up after 10 seconds like any other; a second try works once it is answered.
  The window: Send stays off with a line saying what to tick, where Windows says so when Send is pressed. The Pages question is one field (All, or a range), not Windows' range control. Stop ends a request in progress; a name being resolved can't be stopped, but it is no longer waited for. API keys with a line break are refused before anything is sent (a Mac addition: the socket path writes headers by hand). `Copy All` for the preview's Copy all. Words the About box and start page use now say "unless you send": "Nothing you open leaves this Mac unless you send text to an AI you set up."
  A person must look at (nobody at the screen; snapshots of the sheets and the pane were read, in dark mode, but not on a real screen or in light mode): the pane opening beside the pages and being dragged wider; the disclosure triangle and the sheet growing with it; the amber box for an internet endpoint in light mode; a long answer streaming with the list scrolling along; a citation's look and click; Return and Shift-Return in the question box; the Control-click menu; the real Local Network question with a server on another computer; VoiceOver reading the status line and an answer. Not exercised at all: a real Ollama or LM Studio (none on ignia-mac; no paid service was called, by rule), a real https endpoint through URLSession and through the socket path's certificate check (only TLS to a plain server, refused), saving a key in the real login keychain from the app (locked over SSH; `AiKeychainStore` itself is tested on a throwaway keychain).

Decided 2026-11-03 in the Mac UX review (`docs/UX-REVIEW.md`, branch `mac-ux`; Mac differences from Windows):
- The document window has a macOS toolbar (`WindowToolbar.swift`; its default and allowed items are `ToolbarLayout` in
  PdfCore): sidebar, zoom, Highlight, Markup, Fill & Sign, Share, Search, customizable. Windows keeps its one-row command
  bar with every tool. The Mac's tool strip is the markup toolbar, hidden until asked for (⇧⌘A, Preview's key) or until a
  markup tool is picked; its groups drop from the right in a narrow window.
- The Tools menu groups the tools in submenus (Annotate, Fill & Sign, Redact, Forms, Measure, Accessibility, AI
  Assistant), File the new PDFs (New PDF) and the PDF/A saves (Save as PDF/A); Windows' ribbon groups differ.
- The start page shows four tool cards (Fill & sign, Edit text & images, Combine files, Create a PDF), the other six behind
  Show All Tools; Recent comes before the tools. Windows shows all ten.
- The sidebar picker holds only the panes the document offers; Windows' rail shows its buttons the same way (Layers,
  Suspect Words), the Mac now does it for Signatures too.
- Settings apply as they change (no Save or Cancel), as Mac apps do; Windows' dialog applies on Save.
- `--ux-shots` (with `--self-test`, `--snapshots` and `--synthetic`): the review's shots, menu listing and AX audit
  (`AxAudit` in PdfCore).

Decided 2026-11-03 in the Mac UX review's round 2 (`docs/UX-REVIEW.md`, branch `mac-ux-2`; Mac differences from Windows):
- The markup toolbar is a titlebar accessory under the window's toolbar (Preview's place), its color the system's
  color well; Windows keeps its style bar's eight swatches.
- Dialogs keep their advanced choices behind a More Options triangle that remembers per dialog (`SheetForm`): Sign
  Digitally, Add Header & Footer, Add Watermark, Recognize Text, Redact by Pattern, Reduce File Size, Flatten, Split
  Document, Batch's result options. Windows' dialogs show every option.
- Sanitize Document's sheet lists only the kinds the document holds; the others are one line. Windows lists all.
- The window's subtitle shows the zoom ("Page 1 of 3 · 134%", only off 100%); Windows shows it in its zoom box.
- The commands named in jargon (PDF/A-2b, Flatten, Sanitize Document, Suspect Words) show a plain note as their
  tooltip; the names are Windows' until both apps rename (proposals in UX-REVIEW.md).
- Text size: only the sidebar's lists follow macOS's size (AppKit has no Dynamic Type); Windows follows its Text size
  everywhere.
- `--ux-shots` also opens, shoots, audits and cancels every sheet and alert of the document window (`UxDialogs`);
  `--ux-main` leaves them out. `DialogNames` names a dialog's controls for VoiceOver from the labels beside them.

Decided with the owner (architecture): Inkvolt PDF's menu bar comes from one **document command table**,
`DocumentCommands` in PdfCore (`Ux/DocumentCommands.swift`, pdf/GLOSSARY.md): each command's title, key, place, action
(the Objective-C selector's name), plain-words note and what it needs (`Requirement`, over a window's `DocumentState`).
`MainMenu` builds the menus from it and `DocumentWindowController.validateMenuItem` asks it; the busy rule (a long task
or a progress sheet) is written once, `isBusy`. A new command is one row and its @objc method; actions are names, so
`MenuTest` checks each has a method and an item. The command palette reads the menus as built (AppKit adds items a person
sees and retitles others). Windows keeps its ribbon's XAML and each command's CanExecute. The self-test's `--only-…`
checks are one table, `Report.scenarios`.

### Comments and form data in and out (roadmap 1.4)

`CommentFiles` (XFDF, FDF, CSV), `FormDataFiles` (XFDF, FDF, CSV, JSON), `FormMerge` and `--fill`, `CommentSummary`, and
Batch's comment and form data exports, with Windows' tests under their names. Mac differences:
- Foundation has no XSD validator, so `exportedXfdfFollowsTheXfdfRules` checks the Windows test's XSD rules attribute by
  attribute; XML is read by `XMLDocument` after any `<!DOCTYPE` or `<!ENTITY` anywhere in the file is refused (Windows
  looks at the first 4 KB and reads with DTDs prohibited); refusals are `PdfEditError`s (Windows' `InvalidDataException`);
  exported entries are in key order (Windows: the file's).
- JSON is read by `JSONSerialization` (JSON5, for Windows' comments and trailing commas) after nesting past 64 is refused;
  a JSON number keeps `NSNumber`'s text (1.50 reads "1.5"; Windows keeps "1.50").
- The comment summary's dates use the locale's short date and time style (Windows' "g").
- A person must look at: Export Comments' and Export Form Data's Format row (light and dark), Import Comments' panel and
  the Comments Imported sheet with a long skipped list (VoiceOver reading "Skipped comments"); Fill Forms from CSV's sheet
  (the token note with many columns, More Options, a wrong pattern's red line), its progress and Cancel on a long CSV, the
  Forms Filled sheet with many failed rows; `--fill` from Terminal; a summary of a real reviewed document (the discs and
  lines, long replies, a rotated, a cropped and a scanned page); comments exported here opened in Acrobat or Preview, and
  Acrobat's XFDF imported here.

### Snapshot and printer status when printing (no Windows test to port)

- **Snapshot** (`PdfCore/Pages/Snapshot.swift`, SnapshotTests; Tools › Snapshot, ⌥⌘C). Mac differences: no single key
  (Windows' G is the Signature tool's here and every letter is a tool's), so ⌥⌘C; Esc during the drag cancels it and Esc
  again goes back to Select Text; the split view's second pane takes it. Copy only, as Windows (PNG and TIFF sized in
  points). A person must look at: the drag's box at several zooms and on a turned view, pasting into Pages, Mail and
  Preview, VoiceOver reading the notice.
- **Printer status when printing and Inkvolt Print's printer settings** (Windows' `PrinterCheck`,
  `FileActions.ConfirmPrinterReady`). Windows' Inkvolt PDF reads Inkvolt Print's `state.json`; on the Mac that file is in
  Inkvolt Print's sandbox container. **The hand-off:** `SuitePrinters` in `PrintCore/Suite`, the file
  `<app group>/Inkvolt/printers.json`, which Inkvolt Print writes (each remembered network printer: id, name, model,
  addresses, accepted UUIDs, the macOS queue matched to it; no readings, pins, presets, folders or keys; never in demo
  mode) and Inkvolt PDF only reads, bounded (256 KB, 100 printers, 512 characters a value; it never throws).
  `PrinterHealth` and `PrinterCheck` are PrintCore's (SuiteTests). Mac differences: Windows asks "Print anyway?" after its
  dialog closes; `NSPrintOperation` runs the panel and the job in one call, so the warning is in the panel's accessory
  before Print is pressed, and the panel watches its printer twice a second. The menu item stays without Inkvolt Print
  and offers its App Store page (Windows hides it). The status read doesn't use Inkvolt Print's certificate pins (they
  stay in its container). A person must look at: File › Print… with a printer Inkvolt Print knows (the line, its color
  in light and dark, switching printers, a printer turned off: the red warning within about 2 seconds, VoiceOver), the
  Printer Settings button and menu item with and without Inkvolt Print, Local Network asking once.

### A hostile file's time: page checks in process

Windows draws a page first in a check process and refuses it past 10 s (pdf/ROADMAP.md, "A hostile file's time"). The
Mac calls MuPDF in process, so it bounds the call itself, through the cookie every call that reads a page's content now
takes (`inkv_cookie_limit`, `inkv_cookie_stopped`). **Mac difference:** no check process, no second drawing.

- **Why the cookie alone wasn't enough.** MuPDF looks at a cookie between a content stream's operators and a display
  list's nodes, not while it inflates: the 7 KB page's 4 GB of zeros is one lexer call skipping white space. So
  `MuPDFShim` opens every document over its own stream (`inkv_source`, bytes in place or a file read with `pread`): while
  a call reads a page, it hands MuPDF chunks that start at 16 bytes at each new place in the file and grow only while
  MuPDF uses them up within 4 ms of its own CPU time (a byte of a twice-Flated page is up to a megabyte; a slow share
  or a busy machine doesn't shrink them; the clock, a kernel call, is read once 256 bytes went by, or with each larger
  chunk, so at most a quarter of a gigabyte inflates unseen), and past the budget or once cancelled it throws `FZ_ERROR_TRYLATER`, MuPDF's
  progressive-loading "not yet": its filters, lexer and object loading pass it up without repairing the file or caching
  anything half read. That bound sees only the file's bytes, so a stream decompressed more than twice in a row (four
  Flates make gigabytes of each byte inside the filters, which never read the file again while they do) is refused
  before the page is read: `inkv_check_streams` walks what the page reaches (content, resources, forms, patterns,
  pictures, fonts, annotations' appearances; not up the page tree, to other pages or into actions), each object once,
  and counts each stream's decompressing filters (Flate, LZW, RunLength, Brotli, CCITT, JBIG2, DCT, JPX); more than two
  refuses the page (`failed`). No real file chains more; a filter inside MuPDF can't be reached without patching it.
  What a walk went through to its end, with all it leads to, is kept for the document (a page read again, and the
  fonts and forms every page shares, aren't resolved again); nothing is kept after a damaged object or once the
  document is edited (MuPDF's incremental section; the shim's editing calls forget it too).
  Once a call is stopped, MuPDF's allocations fail while it reads (`FZ_ERROR_SYSTEM`, which its interpreter and loading
  pass up without repairing anything): its reads turn every error but "not yet" into the end of the stream, and its
  interpreter swallows "not yet" for each tile of a pattern it draws itself, so a pattern with no step at all (2^62
  tiles) read for ever after the stop. While a call reads a page's content, one allocation is at most 4 bytes for each
  pixel allowed: an inline picture (`BI … ID … EI`) is decoded whole while the content is parsed, and a JPEG 2000 one as
  it is read, both before the guard sees them, so one larger than the cap is refused before it decodes.
  A guard device (`inkv_guard`) in front of the list, text, export and draw devices looks at the clock with each
  drawing call (every 64 calls, and before every picture, shading, tile and group: nested forms drawn a billion times
  read no bytes) and refuses a picture, or its soft mask, of more than `PdfEngine.maxPicturePixels` (268 M pixels,
  where Windows' check process runs out of memory: half its 2 GB at 4 bytes a pixel) before anything decodes it: MuPDF
  1.25 decodes a Flate picture through a subsampling stream, so drawn small it allocates little but inflates every
  sample, and only its size can tell. In front of a draw device it also counts a pattern's tiles over what the pixels
  show (as the draw device does) and refuses the page (`tooSlow`) when drawing them (30 ns a tile and 0.7 ns a tile
  pixel: 194 M tiles of 81 pixels took 16-17 s here) would outlast the part's time left: the draw device draws them all
  inside one call. A pattern of no area in pixels or with a step of 0 draws nothing (its tiles are skipped as cached;
  a step of 0 refused the page before: its count wasn't a number). A stopped page's
  display list is never kept.
- **The budget** (`PdfEngine.pageBudget`, default 10 s as Windows' limit; tests use 1 s) is the reading thread's own CPU
  time (`CLOCK_THREAD_CPUTIME_ID`), so Find's parallel threads, the viewer's or a slow disk can't refuse a page for good
  that is only waiting (Windows' check process is alone in its process; a refusal is permanent, so the wall clock would
  be unfair here). It runs for the reading (making the
  display list or the text), then again for the drawing of what was read (a Type 3 glyph read late). Every call that
  reads a page's content goes through `PdfEngine.reading`: `render` (the view, thumbnails, print, OCR's page images,
  redaction's pictures), `saveImage` (export of pictures, Batch's page images), `text` (Find, copy), `textLines` and
  `exportRead` (export, redaction's reading), `renderRegionRgba`, and Find's own threads; print draws the refusal's
  sentence in a refused page's box (a Mac difference: Windows prints it blank). What a call
  found is the page's verdict for that engine (`verdictOf`: `fine`, `tooSlow`, `failed` for a picture too large), and a
  refused page throws `PageRefused` at once from then on; an edit opens a new engine, whose pages are read afresh.
- **Cancel and closing.** Cancel aborts the cookie (the stream throws at its next chunk: the 7 KB page stops in
  milliseconds; export stops before its next picture); `PdfEngine.close` aborts every reading under way before it takes
  the engine's locks. The cookie's flags are C11 atomics, and a call starting never clears an abort a Cancel set.
  `CancelToken.unregister` waits while `cancel()` runs that handler on another thread, so a call frees its cookie only
  once no handler can touch it; a handler not started yet is taken off at once, and on the thread running the handlers
  (a handler calling back, a linked token's) nothing waits. A handler mustn't wait on a thread that may be
  unregistering. A cookie is made, begun and used on the calling thread (Find's threads each have their own instance
  and cookie), so its deadline is that thread's CPU time.
- **Where it shows.** The viewer draws Windows' "This page took too long to read and isn't shown" ("This page can't be
  displayed" for a picture too large) in the page's place and asks for it no more; Find skips it and its status says
  which pages weren't searched (a Mac sentence: Windows' summary says the page may be damaged); Batch's page images
  leave it out with "Page {0} couldn't be read"; exports report it as unreadable (an empty page). Jobs over many pages
  skip it and say "Pages that couldn't be read were skipped: …" (`SkippedPages`): Redact by Pattern's search (with what
  it marked, so nobody takes the result as clean), the redaction check (in its notes; an earlier version's page, by
  name; the report is then `incomplete`, as is one told of pages the search before skipped, `RedactionCheckOptions.skipped`,
  and Batch fails such a file and saves nothing, Windows' Incomplete: Redact Patterns on a page it couldn't search, Check
  Redaction on one it couldn't read; Tools › Check Redaction then says it couldn't look at everything, with the notes,
  never "Nothing recoverable was found"), Prepare Form's field search, Recognize Text and Batch's OCR, the AI
  assistant's reading (sent as an empty page). Every other part the redaction check notes and goes past makes it
  incomplete too (since 2026-11-07; **Mac difference:** Windows only notes the starred ones): content the walk of covers
  couldn't read (a damaged stream or form, past 400,000 operators or 8 nested forms)*, covers it couldn't take out to
  look under*, an original it couldn't read*, an earlier version it couldn't open*, more earlier versions than the 32 it
  reads*, more values than the 500 it looks for, a value search past its 10 s, a stream past 64 MB or one that can't be
  decoded.
  **Mac difference:** Windows' versions of those jobs stop at a refused page (only Find, Batch, export, compare, print and
  the AI skip it). Applying redactions still stops at a refused page with a mark: it can't draw the page to black it
  out, and skipping would leave the text there. One figure's picture for the AI (Make Accessible) says it couldn't be
  drawn.
- A person must look at: a bomb page in the viewer (the sentence, centered, in light and dark; the neighbours drawing
  after it), thumbnails and the organizer (a blank page), Find's status line with a skipped page.

### Indexed folder search (roadmap 3.5)

Windows' design (pdf/ROADMAP.md 3.5) on the Mac, the .NET code as the spec: one index file per folder in the app's own
Application Support (`~/Library/Application Support/Inkvolt PDF/FolderIndex/<hash>.<generation>.idx`, the folder's path
hashed so no name shows), terms to pages, each page's text kept compressed, written only at the end a commit at a time,
compaction to a new generation. A search reads no PDF: the index proposes pages, Find (`PageText.findIn`) confirms on the
kept text and gives the excerpt. No network, nothing leaves the Mac; Spotlight isn't used (it indexes what it chooses,
its text extraction isn't Find's, and Windows' design has no counterpart: the index must say which pages Find finds).

**Mac differences.**
- **Reading in process, no index workers.** As Find (E16): the indexer reads PDFs on its own reading threads (half the
  cores, up to four, utility priority). Every page goes through the engine's page check (`pageBudget`, 10 s; a picture
  too large; a stream inflated again and again), so a bomb page is refused and counted as unread, not waited on
  (FolderIndexerTests.A_bomb_page_is_refused_by_its_budget…). A watchdog gives a file 2 minutes of its thread's processor
  time (`thread_info`, as Windows counts the worker's) and 10 minutes without a sign of life; a reading told to stop that
  doesn't within the grace is left behind and a new thread reads on (its result is dropped when it ends). What a worker
  process bounded and a thread can't: memory (MuPDF's store and picture limits stay; Windows' 2 GB job limit has no
  counterpart) and a crash. For the crash, a journal beside the index (`<hash>.reading`, `<hash>.crashes`) names the files
  being read; the next launch counts them, and a file that was being read when the app ended twice is `crashed`, never
  read again until it changes or Rebuild. Where Windows gives each file a process of its own, several files read at once
  share the app: when the app ended with more than one in the journal, none is counted; each is a suspect, read again
  one at a time with nothing beside it, so only a file that ends the app by itself is counted (review). A
  file read through clears its count; a reading given up stays in the journal, marked, until its thread is back, and
  when the app ends with one there the readings given up are the ones counted, whatever was read beside them (a hang is
  as bad as a crash for indexing), so suspects never come back unchanged launch after launch: each file costs two
  launches at most (second review). Quitting or
  removing the folder is an orderly stop: the journal of readings is closed and forgotten, so a reading still under way
  then is never counted; the app stops all folders at once and waits once (2 s), as Windows' `StopAll`. A reading that
  throws something unexpected counts as a crash too (once more, then `crashed`), Windows' worker dying.
- **Change notices:** FSEvents (file events, the root watched) on the folder and everything under it, then a look every
  30 s as on Windows (a network volume may give no events). What the listing skips (names starting with ".", Finder's
  hidden folders, `~$` files) wakes nothing, so a busy `.git` or cache costs nothing; a notice names its place, and up to
  64 places are looked at alone (a folder listed, a file looked at, a place gone taken out with what is under it) instead
  of the whole tree; dropped events, the folder itself, a new file past the limit or only in iCloud mean a whole look
  (Windows looks at the whole folder on any notice). A file changed in the last 2 s waits for the next look: the Mac
  opens a file being copied, where Windows' sharing rules refuse it.
- **Locks:** a search takes no lock that writing holds (a commit or a compaction never holds it up; Windows reads its
  flag without one). Words are filed by the reading thread before it takes the indexer's lock, the indexer writes
  (`F_FULLFSYNC`) outside it, and the window reads the status and the index from a snapshot under a lock held only for a
  moment. A commit that fails (a full disk) keeps its batch, with the counts right, says so in the folder's status, and
  is written first on the next look (after 5 s, doubling up to 30 s), so nothing read is lost or read twice; an index
  found damaged that can't be emptied waits the same way and says so, never a tight loop; a Rebuild asked while another
  app holds the index says so and is done once it opens. One path is one entry: a file read again before its first
  reading was written replaces it (in the batch, or in a batch a write failed on), and a commit that adds a path the
  index has marks the old text dead for compaction.
- **Listing:** `readdir` and `lstat`; symbolic links aren't followed (a link leads out of the folder or round in a
  circle), hidden files and folders and `~$` files are skipped; iCloud Drive's files whose bytes are only in the cloud
  (`SF_DATALESS`) are counted and left there, Windows' Cloud Files placeholders. A folder moved while it was listed reads
  as away, never as its files gone. Paths are kept as listed, "/"-separated and case kept (a Mac volume may tell case
  apart); the hash takes the path with "..", "." and links resolved, not upper-cased.
- **Folding:** Windows asks its collation's sort keys what Find reads alike; the Mac's Find is Foundation's comparison
  (`.caseInsensitive`, `.diacriticInsensitive`), so `IndexTerms` folds each letter with Foundation (through upper case
  when that stays one letter, then width, NFKD, marks dropped) and also as Windows does the letters Foundation keeps apart
  (ø, æ, œ, ł, đ, ß, digits of other scripts): the index may propose more, Find decides. Its `stamp` hashes the folding
  of every letter, so a macOS whose tables differ builds the index again. A run of letters longer than a term (48) is
  filed in overlapping pieces of 48, one every 24 units, its first 1,024 units at most, and a query's longer word looks
  up its first 23, so the end of a long run is found as Find finds it (Windows files a long run under its first 48
  only: a search for its end finds nothing there). `IndexTerms.version` 2: indexes made before are built again.
- **More bounds:** besides Windows' (512 MB a file, 50,000 pages, 32 M characters of text, the page check, 2 minutes),
  at most 100,000 PDFs a folder (the rest counted as over the limit) and 2 GB for the index file (past it nothing more is
  read until compaction makes room; said as a problem).
- **The file:** each page's directory entry also keeps its plain length and CRC-32 (the Compression framework's raw
  DEFLATE has no checksum of its own, unlike Windows' zlib stream), so damage reads as damage. Commits are flushed with
  `F_FULLFSYNC`; a new generation's name (compaction's rename, a cleared index's new file) is synced through its folder
  before the old one is retired. One app per index through `flock` on `<hash>.lock`.
- **The window:** Edit › Find › Search Folders… (⌥⇧⌘F; Windows: Edit › Search Folders…, Ctrl+Alt+Shift+F), a window of
  its own: the search field (searches as you pause typing), Match case, Whole words, Ignore accents (on), the results
  (file, page and times, the excerpt with the hit in bold; double-click or Return opens the PDF at the hit with the Find
  bar showing the words, found with the same options), the indexed folders with their status line, Add Folder…, Pause,
  Skipped Files…, Rebuild…, Remove…. The folders are kept in the settings (`IndexedFolders`) and indexed while the app is
  open; quitting stops them, committing what was read.
- **Not ported:** IndexWorkers and its tests (no workers), the killed-writer crash test (a process of its own; the file
  cut at every byte stands for it), the memory-limit test, workers that can't start, Cloud Files sync roots.

**Not checked:** the 10,000-PDF bench on the Mac (Windows' `index-make`/`index-run` have no Mac port), a real hostile
PDF that crashes MuPDF, a network volume, iCloud Drive's dataless files for real (the flag is tested, not a download), a
disk filling up.

- A person must look at: the window in light and dark and at its narrowest, the excerpt's bold hit, VoiceOver on the
  results and folders, a result opening at its hit in a document already open.

### Compare: Office files, scans and formatting (roadmap 3.3)

Windows' 3.3 on the Mac's E3 Compare: CompareChangesTests, CompareAlignTests and CompareContractTests ported with their
names (camelCase), then `CompareLooks`, `CompareMoves`, `CompareScan` and `CompareAlign`.

**Windows ahead, to port:** `CompareAlign` lines up a scan at another size or a quarter turn off
(`PageAlignment.Scale`, the frames tried per quarter turn, the sizing at 2 pixels; CompareAlignTests'
`AScanAtAnotherSizeOrAQuarterTurnOffIsLinedUp`, `WhatReallyChangedStillShowsOnAScanAQuarterTurnOff`,
`AScaledAlignmentGoesThereAndBack`), and Compare reads scans with the language's dictionary. E15's exports carry links
(`ExportSpan.Link`; ExportHtmlTests' and ExportPptxTests' link tests). Folder search's phrase reading: a file's
pages read together from its text read once (Windows' search cursor filled a megabyte per page; check the Mac's port), and
`SideBySideAscii` (FolderIndexTests' `The_quick_phrase_reading_agrees_with_the_full_one`,
`Pages_of_many_files_and_long_pages_read_back_in_order`), a file's pages 32 at a time to all processors but two
(`A_big_files_pages_are_shared_among_the_threads_in_chunks`), and a long run's end taken as any phrase head
(`A_phrase_whose_first_word_ends_a_run_longer_than_is_read_is_still_found`). The scan cleanup's which-way-up test leaves
out a run of ink rows over 3 times the page's lines' height (the lower middle of runs of 6 rows or more, a tight run cut
between its bands first), then reads the lines again without it (`Upright.MaxLineRatio`, `MinLineRows`; PrintTests' `UprightTests`, ScanTextTests'
`APageWithALargeShadedPictureIsTurnedTheRightWayUp`): `ScanCleanup.swift` has the old reading.

**Mac differences.**
- **Office files through E12's converter** (Microsoft's app when installed, else LibreOffice): `Converting.pdfForCompare` runs E12's `OfficeConversion`
  (its precheck, the question for a file from the internet, the converter's own process, time limit and Cancel) behind a
  progress sheet, and nothing is opened. Without either the message says so.
  LibreOffice lays a .docx out a little differently from Word, so an Office file is best compared with a PDF LibreOffice
  made too (or two Office files): against Word's PDF, line breaks and fonts may differ. **Not checked:** a real .docx.
- **Scans read with Vision**, in Recognize Text's language (`SavedOcr.language`), through `PageOcr.recognizer` (each page
  rendered at 300 dpi within 60 million pixels, under the page checks), one page at a time, on this Mac; Compare Without
  Reading Them stops it (the pages read so far count). A page Vision fails on counts as not read, and the summary says how
  many. Vision's boxes are upright (no angle), so `CompareScan.pageTextOf` gets angle 0; a skewed scan still reads in
  Vision's line order. Windows' recognizer skipping a line (`couldBeALostLine`) is kept as the heuristic it is.
- **The compare read** (`PdfEngine.comparePage`, Windows' `GetComparePage`): the shim's `inkv_compare_page` reads the page's
  own content (no annotations), as `inkv_page_chars` does, with each character's font, size and color and the pictures'
  boxes (no pixels, no paths); the text is the same as `text`'s (theLooksLineUpWithThePageTextOnEveryPage). It keeps the
  pictures (`FZ_STEXT_PRESERVE_IMAGES`, as Windows' `GetComparePage`) to tell a scan, so MuPDF may start a new line at a
  picture set inline where `text` doesn't: the words compared are the same (wordsBesideAnInlinePictureAreTheTextsWords). Under the page
  checks: a bomb page is refused at its budget (PageCheckTests' list of bounded calls has `comparePage`).
- **A page that can't be read** (refused by the page checks, or MuPDF fails on it) is read as an empty page and listed as
  "Not compared", its row headed "couldn't be read: not compared", and left out of the visual check; the rest of the
  documents is compared. Windows shows such a page as a page without text.
- **Extra bounds:** `CompareAlign.find` on two pages renders them within 4 million pixels (100 dpi for any real page;
  Windows renders at 100 dpi whatever the size); the image overload refuses images past 6 million pixels (no alignment).
  The visual check looks at most 2,000 rows with text, as Windows, each cancellable.
- **The visual check** renders rows without text at 0.7 (E3 used 0.5), as Windows, and now also pages with text that
  stayed in place (what looks different off the text) and two scans lined up (`VisualCompare.overlayScans`); the Visual
  overlay of a scan's row is lined up the same way. A picture of a page can be a PNG, JPEG, TIFF, BMP or HEIC.
- `MakeThePdfsWithWord` isn't ported: the PDFs are Word's, made on Windows.

### Speed on huge files: drawing in bands (roadmap 3.6)

Drawing a sheet of the drawing set took most of a page's time in one thread (584 ms on the M1 Air); a display list is now
drawn in bands, one a core. The bench's numbers: `mac/tools/bench/RESULTS.md`.

- **Bands.** `render_rgb` draws a list in bands of rows when the engine's context was made for it
  (`inkv_new_drawing_context`: MuPDF's locks; only the engine's own rendering instance, never the text or Find ones) and
  the list has 2,000 paths or more and no picture (`inkv_bandable`, counted by the guard while the list is made and kept
  with it per page). Each band (`inkv_draw_band`, `dispatch_apply_f`) clones the context, wraps its rows of the one
  picture (`fz_new_pixmap_from_pixmap`) in a draw device and its own guard, and runs the list with its rows as the
  scissor. `PdfEngine.bands`: one a core (`activeProcessorCount`, at most 16) for a drawing of 512 K pixels or more, else
  one thread (tiles, thumbnails); `bandsForTests` sets it for tests and the bench.
- **The page check holds.** The bands share the cookie: a stop or Cancel seen by one stops all at their next drawing call
  (`CancelStopsEveryBand`), and sets each band's own MuPDF flag (`inkv_cookie.bands`), so a band that is only skipping
  the nodes outside its rows stops at the next node too (`ACancelStopsBandsThatOnlySkipAsSoonAsOneThread`). They share
  one CPU budget: each guard adds its own thread's time to the call's count (`spent`) and stops when the count passes
  the budget, so a page that takes 10 s of one core is refused after the budget in 16 bands as on one
  (`APageSlowToDrawIsRefusedAfterOneBudgetInBandsToo`; with a budget each it would have been drawn). The bands cost more
  CPU in all than one thread (each walks the whole list), so a drawing out of time in bands is drawn again on one thread
  with a budget of its own before the page is refused: never refused in bands where one thread draws it
  (`APageOneThreadDrawsInItsBudgetIsDrawnInBands`, red first), at the cost, for a page that is refused, of a budget's
  CPU time in bands first. A pattern's tiles are counted over the whole picture, not the band.
- **Why not pictures.** MuPDF decodes and scales only the part of a picture a draw shows, so a band near a picture's edge
  sampled another source row (up to 255 apart on a picture of sharp stripes): a page with any picture (a scan, a logo)
  draws on one thread as before, and so does text in a Type3 font whose glyphs draw a picture or a shading (a glyph
  larger than MuPDF's glyph cache takes, 256 pixels, is drawn clipped to the band: `guard_text_pictures`,
  `AType3GlyphWithAPictureIsNotSplit`, red first).
- **Paths, byte for byte per band.** MuPDF's rasterizer moves a slanted edge's end to where it crosses the picture's top
  or bottom, rounded to its sub-pixel grid, and steps the edge from there (`draw-edge.c`, `clip_lerp_y`): a picture's rows
  depend on where it is cut, on one thread as in bands (the viewer's tiles differ from a whole page the same way), and
  overlapping bands would only move the cut. So each band is, byte for byte, what one thread draws of its rows
  (`EachBandIsWhatOneThreadDrawsOfItsRows`), a sheet of lines along the rows and columns is the whole page's picture byte
  for byte (`ASheetOfStraightLinesIsTheSameInBandsByteForByte`), and a sheet of slanted lines is within anti-aliasing of
  it (at most 32 apart, under 2 on average, `ADrawingInBandsIsTheSameAsOnOneThread`; every other kind of page byte for
  byte).
- **Locks.** MuPDF takes its allocation lock to keep and drop each node's path in every band, even nodes outside the band:
  with pthread mutexes the threads queued in the kernel (`sample`: more time waiting than drawing; 8 bands 192 ms a
  sheet), with `os_unfair_lock` 162 ms; a spin lock was as fast idle and twice as slow under load. More bands than cores
  is slower (16 on the M1's 8: 206 ms). `bench bands drawings.pdf 1 4 8 16` measures it.
- **The page ahead.** The viewer asks for the next page after the ones shown, the way it last scrolled (`ReadAhead`: the
  way changes only when the first page shown does, and is forgotten when the pages are laid out again), so a sheet is
  often drawn before it scrolls in. Not in Single Page, nor zoomed into tiles. It never holds up what is shown
  (`PageRenderer.requestAhead`): it starts only once no page or tile shown is waiting, a request for what is shown cancels
  it and starts it again after, and it becomes that request if it is the page now shown. The bench doesn't measure the
  viewer: a person scrolling a drawing set should see fewer blank sheets.

### What a person must look at

Built and tested over SSH; nobody saw these on a screen. Each needs a person at a Mac:

- Saved signatures: the Signature menu's pictures beside each saved signature (light and dark mode), the disabled Draw
  and Type Signature with their tooltip when three are saved, Delete a Saved Signature's question, Tools › Place Saved
  Signature, Sign Digitally's Image list; quitting and opening the app again keeps them.
- Rotate view: View › Rotate View Clockwise (⇧⌘R) and Counterclockwise (⇧⌘L) at 90°, 180° and 270°: the pages and their
  sharp tiles at 400 % drawn turned (no gaps or seams), selecting text, clicking links, filling a field (its editor
  sits over the turned field, upright), drawing and resizing comments, Prepare Form's fields and their handles' cursors,
  Measure, the find highlight and Read Aloud's marks; each split pane on its own; a file reopening turned.
- Dark pages: View › Dark Pages (Night Reading) and Settings' box: pages, thumbnails and the organizer's cards dark at
  once in every window (no flash of white while redrawing), colored pictures keeping their hue, the fields' outline
  without tint, comments and the selection still readable; with Accessibility's Invert colors on, pages are left as
  they are.
- Thumbnail drags: dragging one or several thumbnails in the sidebar (the gap where they will land), dropping them in
  another window's sidebar (a copy, "+" on the pointer), and a PDF or pictures dragged from the Finder onto the
  thumbnails; the moved pages selected after.
- Reading modes: View › Single Page (⌘4), Continuous (⌘5), Two Pages (⌘6), Two Pages with Cover (⌘7): the pairs'
  gap and centering at several zooms, Zoom to Width and Zoom to Page fitting a pair, turned pages in pairs, Single
  Page turned by scrolling on past a page's end with a mouse wheel and a trackpad (no flicker from coasting), by Page
  Down, Space and the arrows, and the subtitle and thumbnails following.
- Insert from Scanner (Pages menu): **needs a real-scanner check by a person** (nobody has scanned into an open
  document with a real scanner: the self-test uses Inkvolt Print's demo scanners only). The window titled Insert from
  Scanner with its Insert row; a network (eSCL) and a USB scanner; the feeder's pages inserted in order where chosen;
  Make the text searchable recognizing only the inserted pages; the window going back to Scan for File › Scan….
- Report a Problem (Help menu): the window's layout and wrapping, the details' monospaced text, editing them before
  Copy, and Copy and Open a GitHub Issue opening the browser on a prefilled issue (the self-test only makes the
  address).
- Document Properties (File menu, ⇧⌘I): the sheet's rows and their wrapping (a long location, a long producer), the four
  fields, Save Changes, Cancel and What's in This PDF…, on a protected and a signed file.
- Edit Text & Images' pictures: the eight handles and their reach at several zooms, Shift keeping the proportions, the
  arrow keys' moves shown before they are written, on a turned view.
- Compare's zoom: the − Fit + buttons in the bar, the horizontal scroller at 200 % and more, the row in view kept;
  the start page's ten cards (three rows) with Compare files.
- An attached PDF with its own password: the password question naming the attached file, a wrong password asked again.
- Form fields' hover actions: a real form whose fields change on hover (a button's look, a help text set by its
  script) with a mouse and a trackpad; nothing flickering while the pointer crosses fields quickly.
- Extract Pages and Split Document (Pages menu): both sheets' layout, Choose… for the folder, the problem line after a
  wrong range or pattern, the progress sheet on a long document, the Finder opening on the folder, and the password
  question on a protected file.
- Reverse Page Order (Pages menu): the thumbnails and the organizer redrawn in the new order, the chosen card where it
  went.
- The UX review's window (branch `mac-ux`): the toolbar in Liquid Glass, light and dark, its overflow menu in a narrow
  window, Customize Toolbar…'s sheet and Icon and Text mode, the Markup button staying pressed while the markup bar shows,
  Share's picker, the tab bar under the unified toolbar; the start page's Show All Tools; Settings applying as you change
  them; Increase Contrast and VoiceOver over the toolbar and the markup bar.
- Go to Page (Go menu, ⌥⌘G): the sheet's field taking focus, Return going there, a label typed in a file with page
  labels (the self-test's document has none), and the sheet asked again with the range.
- The UX review's round 2 (branch `mac-ux-2`): the markup toolbar under the toolbar in Liquid Glass (light, dark,
  Increase Contrast, full screen, a narrow window, several tabs), the color well's popover and Show Colors…, the width
  pop-up; More Options opening and closing on a sheet that is already showing (the shots were taken after it settled),
  in Sign Digitally, Header & Footer, Watermark, Recognize Text, Redact by Pattern, Reduce File Size, Split and Batch;
  the subtitle's zoom while pinching; the comment list at the Large sidebar size; VoiceOver reading the dialogs' controls
  by their labels; the tooltips on Save as PDF/A, Flatten, Sanitize Document and Review Suspect Words.
- Filling a real form by hand (the self-test types through the editor's own path, `FormFillTest`): a masked field's editor on
  screen, comb cells that draw what was typed under a format, a USCIS form in Acrobat after filling here.

### Filling real forms (the forms corpus)

`mac/tools/forms-corpus` is Windows' `pdf/tools/forms-corpus` on PdfCore (README and RESULTS.md there), with typing, tab order,
encryption, bookmarks and damaged copies added. What it found is fixed with Windows' test names (`RealFormTraitTests`,
`EncryptedFormFillTests`, `FormActionTests`) and `DamagedFormTests`; the app's check is `FormFillTest` (`--only-form-fill`).
Mac differences:

- **Encrypted forms that allow filling.** Windows reads a decrypted copy and writes each new object with its own `StandardCrypt`;
  here MuPDF holds the file key from the user password and writes the update itself (`PdfEdit.open`'s `userEdit`). So a repaired
  such file can be written whole with `encrypt=keep`, where Windows only ever appends; there is no copy that can fail, and none of
  Windows' checks on it (/Perms, handler consistency, /Encrypt written again).
- **A stale tail** (`StaleTail`). Windows cuts a tail holding no object and rebuilds the cross-reference otherwise. MuPDF's repair
  takes the last copy of an object, so an old object in the tail replaced the real one (a whole form's fields, in `~tail`): here a
  tail that doesn't start as an update would (an object or a table, after white space and comments) is left out whatever it holds,
  unless a signature's /ByteRange covers it. Every MuPDF open is given the same bytes (`MuDoc.open`, `PdfEngine.open`), so Batch,
  the merge and every reader agree with the view. A tail holding objects is left out only as a repair: the person is told, and
  signatures made before it aren't shown valid.
- **Junk after the last %%EOF** (more than 512 bytes of white space, or anything holding no object). Windows keeps it and appends
  after it. MuPDF's update counts its offsets from the end of the revision it read, so every update (an edit, a signature) goes
  right there and the junk is dropped (`MuDoc.appendsAfter`). A revision that only lost its end isn't junk: nothing older is read
  in its place, and saving asks for the rewrite as any signed file that can't take an update.
- **A repaired file** (`PdfRepair.normalize`, at a session's open and reload, `fromBytes(repair:)`, `recover(repair:)`, Batch and the
  form merge): the copy MuPDF's repair reads is written out once, every object and the encryption kept, where Windows rebuilds
  the cross-reference with PDFsharp. The rest is Windows': `DocumentSession.repairedLength`, a bar that says so until closed, a
  signature over no more than the copy (or one that can't be placed in it) `.unsupported` and `inRepairedFile`, no certifying,
  `RecoveryInfo.repairedLength`. `Signatures.verify` also takes bytes no session made sound (a damaged file read as it is) as
  repaired whole. Long-term data (3.4) is never added to a repaired file, as on Windows.
- **A repaired file written whole** has every object loaded first (`MuDoc.write`): MuPDF's writer takes a repaired cross-reference
  for one without object streams and, with garbage collection, silently dropped what they hold (bookmarks, structure trees).
- **Comb cells under a format.** A format's separators that don't fit the cells (SSN in 9 cells) would push the last digits out;
  the cells show what was typed. Windows draws what fits. The field's value and `displayValue` are the same on both.
- **Pasted Zip, phone and SSN numbers** (`FieldKeystrokes.typed`): with room for just the digits, the separators that don't fit
  are left out, so `123-45-6789` pasted into a MaxLen 9 SSN box goes in as its digits. Windows cuts the paste to the MaxLen
  (`123-45-67`), which the commit then refuses.

### Microsoft Office as E12's converter

**Off in 1.10.0:** `OfficeInstalls.drivesMicrosoftOffice` is false and every `OfficeInstalls` takes it
unless told otherwise; the converters are chosen from `driven` (Microsoft's apps only when driven), so nothing built or
changed later drives Word, Excel or PowerPoint: LibreOffice converts every Office file as in 1.9.0, and 1.9.0's messages
name a Microsoft app as not used yet. The Apple Events entitlement is left out of `InkvoltPdf.entitlements` meanwhile
(put it back when turning this on; `NSAppleEventsUsageDescription` stays, unused). The code below stays in and its tests
drive it (`drivesMicrosoft: true`); `OfficeConversionTests.microsoftOfficeIsOffForNowAndLibreOfficeConvertsAsIn1_9` and
the self-test's `AppTest` (a made-up Word installed is sent no script) check the gate. Turn it on (and announce it in What's New) only after a person with Microsoft 365 signed in on a Mac has run this
section's checklist: the Automation prompt needs a person, which no ssh run can be.

Windows converts Office files through Word, Excel or PowerPoint (COM, `OfficeConverter.cs`); the Mac now does too, through
AppleScript, with LibreOffice (E12's `OfficeConversion`) as the fallback. `PdfCore/Convert/MicrosoftOfficeConversion.swift`:

- **The chooser** (`OfficeInstalls.route`): the Microsoft app for the file's kind when Launch Services finds it
  (`com.microsoft.Word`, `.Excel`, `.Powerpoint`), else LibreOffice, else nothing and `missing` names both. Chosen once
  (`OfficeConversion.job`, with the checks before anything starts), so the progress names the converter that runs; Open
  and Compare share it (`Converting.prepareOffice`). **Mac difference:** Windows uses Office only and has no fallback.
  Here, when Microsoft's app fails for a reason of its own (`OfficeAppFailure.aboutTheFile` false: not activated,
  Automation denied, not started, a timeout, not set up, a copy over 512 MB, several PDFs), LibreOffice converts it when
  installed, and the notice says why the app didn't; the file's own trouble (a password, a file it couldn't open, a PDF
  over 1 GB) and Cancel aren't retried; when both fail, both reasons are said. The conversion runs on a thread of its
  own (`OfficeConversion.run`), never one of Swift concurrency's pool.
- **The seam** (`OfficeScriptRunner`): `OsascriptRunner` runs `/usr/bin/osascript` on a script file, as a program of its
  own through `ConverterProcess` (its own process group, ended at the 3-minute limit or on Cancel); the paths and the name
  go as the run handler's arguments, never into the source. Tests give a fake runner; `OsascriptRunner` itself is tested
  with scripts that drive no app (arguments with quotes and `$(…)` come through as they are, an error's number, the limit).
- **Staging:** Office for Mac is sandboxed, so a copy goes in `~/Library/Group Containers/UBF8T346G9.Office/Inkvolt PDF/`,
  in a folder of its own (0700) removed after on every path; folders a crash left are swept there at the next Office
  conversion (and the temp folder's at launch, which nothing did before). The copy's name is the original's, shortened to
  60 characters, without `:` and `/`, with a tag unique to the conversion: "Report (Inkvolt 1a2b3c4d).docx". Bounds: a file
  over 512 MB isn't copied; a PDF over 1 GB isn't read (LibreOffice's too, `ConvertedPdf`); one conversion at a time.
  No group container means the app was never opened: said so ("open it once and sign in").
- **Office as found** (`MicrosoftOfficeScripts`): a probe first asks whether the app is running (no event sent to it;
  when that can't be told, it counts as running: never quit). The script finds the copy by its unique name, never the
  active document; saves it as PDF; closes only it, without saving; quits the app only if it wasn't running before and
  has no document left. Every event to the app sits in a `try`, so an error comes back tagged with its stage. No
  `activate`, no shell. AppleScript's own `with timeout` (the limit less 10 s) ends a stuck event first; after a timeout
  or a denial it sends nothing more. After any run that didn't succeed (but a denial): a timeout, Cancel, osascript
  stopped at the limit, an error, a clean-up script (15 s, not cancellable) closes the copy by name and quits the app on
  the same terms, if it is still running; only then is the copy removed and the next conversion let in. **Not joined:**
  Excel saving one PDF per sheet is said as such ("saved this file as 3 separate PDFs") and LibreOffice tried; their
  order can't be told without a run of Excel. **Mac difference:** Windows opens a new hidden instance; on the Mac the app's
  window shows the copy while it converts (Office for Mac has no hidden instance), and Word's own macro settings apply
  (Windows forces macros off); the question for a file from the internet says so.
- **Entitlements:** `com.apple.security.automation.apple-events` in `InkvoltPdf.entitlements` (the hardened runtime blocks
  osascript's events without it; `sign.sh` applies the file, so `build.sh` and `release.sh` both get it; notarization
  accepts it) and `NSAppleEventsUsageDescription` in Info.plist (Spanish in `InfoPlist.xcstrings`).
- **Errors in words** (`MicrosoftOfficeConverter.failure`, from osascript's error number and the script's stage): Automation
  denied (-1743, -1744: where to turn it on), a timeout (-1712 or the process limit: "it may be waiting in its window: to
  sign in, for a password, or with a question"; the limit said as LibreOffice's is, `OfficeConversion.limitText`), the app
  quit (-600, -609), not started (-10810, a dictionary it can't read), a password (read from the error with the copy's
  name and folder taken out: a file named "Passwords" isn't one), a file it couldn't open, and not saved (the save failed, or no PDF: "saves only when it is activated:
  sign in"), which is how an unlicensed Office (read-only mode) shows. An encrypted Office Open XML file is refused before
  anything starts, as with LibreOffice.

**Only a person with Microsoft 365 signed in on the Mac can check** (none of it has run; the scripts' Office terms come
from Office's AppleScript dictionaries as published, not from a run). On a Mac, with Word, Excel and PowerPoint:

1. File › New PDF › New PDF from Office File… with a .docx: macOS asks whether Inkvolt PDF may control Microsoft Word, with
   the usage text (en, then es with `--lang es`); OK makes the PDF; a second file asks nothing.
2. Same for a .xlsx (Excel; does the PDF hold every sheet, or the active one only?) and a .pptx (PowerPoint).
3. With Word closed: Word opens, converts, quits. With Word open on another document: that document stays open and
   unchanged, Word keeps running. Nothing named "(Inkvolt …)" stays open, and `~/Library/Group Containers/UBF8T346G9.Office/Inkvolt PDF`
   is empty after.
4. Does macOS (15 and later) ask whether Inkvolt PDF may use other apps' data when it writes the copy there? Note what it says.
5. Don't Allow, then convert again: the Automation message; turn it on in System Settings › Privacy & Security ›
   Automation; it converts.
6. A legacy .doc with an open password: Word asks for it or fails; the message is the timeout's or the password's, and
   Word is left with no copy open once the question is dismissed.
7. Signed out (or an unlicensed Office in read-only mode): the "saves only when it is activated" message, or the timeout's.
8. A .docm with macros: what Word asks; Cancel at Inkvolt PDF's progress: the clean-up closes the copy if Word answers
   (Word's question may keep it busy past the clean-up's 15 s).
9. File › Compare Files… with a .docx on one side; opening a .docx from Finder with Inkvolt PDF.
10. The release build: `codesign -d --entitlements - "/Applications/Inkvolt PDF.app"` lists apple-events; `release.sh` notarizes.
11. A workbook of several sheets with different page setups: one PDF, or the "separate PDFs" message and LibreOffice's.
12. With Word not activated and LibreOffice installed: LibreOffice converts and the notice says why Word didn't.

### Command bar (CB)

Windows' command bar (1.12, approved by the owner 2026-11-08) in the Mac's own toolbar. PdfCore `Ux/CommandBar.swift`
(`CommandBar`: the groups, their commands with the line under each, main jobs, at-once items, tints, priorities;
`BarColors`), `Export/ExportTarget.swift`, `ToolbarLayout` (UxRules.swift); the app's `CommandBarItems.swift`, the notice
bar's links (LongTasks.swift) and the self-test's `CommandBarTest` (`--edit --only-command-bar`; shots with `--snapshots`).
Shots for the owner: `docs/design/mac/`.

- **Native form.** Each group is an `NSMenuToolbarItem` with `title` set, so AppKit draws its icon and label side by side
  with a split arrow, in the toolbar's Liquid Glass; the body sends the main job, the arrow opens the menu. The pointer
  tools are an `NSToolbarItemGroup` (select one) of three icons, showing the tool in use. Menu items carry the Windows
  flyout's line as `NSMenuItem.subtitle`, the main job in semibold. Comment ends with a Draw submenu (the Tools menu's
  drawing tools), Protect holds Redact. VoiceOver: the body is named by its label ("Convert"), the arrow by its menu's
  accessibility label ("Convert: more commands"); the body's tooltip says the main job and Option-click. Keyboard: the
  toolbar's items with Full Keyboard Access (Tab, Space; the arrow is its own element), and every command is in the menu
  bar and the command palette.
- **Mac differences.** Option-click asks first where Windows uses Shift+click (Option is the Mac's alternate action). The
  fitting is the toolbar's own: groups go into its » overflow whole, labels never drop; `CommandBar.visibilityPriority`
  keeps Edit, Convert, Comment and Fill & Sign longest (Fill & Sign under them in Spanish, as Windows), then the pointer
  tools, Organize, Protect, Scan & OCR first; Save, Print, Undo and Redo stay in the menus (⌘S, ⌘P, ⌘Z), as Mac
  toolbars do. Convert has no Images… item: the Mac has no export to pictures yet. Under Increase Contrast the colours
  give way to the label colour (Windows: high contrast); Differentiate Without Color changes nothing, since every
  coloured icon has its label. The toolbar's identifier changed (`InkvoltPdfDocumentBar`), so a toolbar customized
  before starts from the new defaults; the old Highlight, Fill & Sign, Edit, Redact and Organize buttons are replaced by
  their groups (Markup, Zoom, Share and the rest stay in Customize Toolbar…).
- **One-click jobs.** Convert › Word, Excel, PowerPoint, text, HTML: `ExportTarget.reserve` makes name.docx next to the PDF
  with `open(O_CREAT | O_EXCL | O_NOFOLLOW)` (a regular file or nothing), "name (2).docx" when taken, Documents when the
  PDF isn't saved or its folder refuses; a Windows device name (`ReservedFileNames`: CON, COM¹, CONIN$…) is refused, so
  it asks with the save panel. The reservation runs off the main thread inside the window's long task, so the document is
  busy from then on (no edit, a second click converts nothing: `convertingAtOnce`); a closed window or a failed or empty
  export deletes the reserved file while it is still empty. All pages, scans read with the saved setting; the file opens;
  the notice says "Saved name.docx · Show in Finder · Change options…", and Change options… does nothing on a closed
  window and says "Wait a moment: … is still busy." on a busy one. Fill & Sign › Sign arms the first saved signature
  (a damaged one: "Couldn't read … Its picture can't be read. Delete it and add it again.") or opens the pad the first
  time; Comment › Highlight marks the selection (none: the highlighter); Protect › Password asks only for the password
  (AES-256, nothing restricted; a protected document gets the full sheet); Redact marks the selection (none: the tool);
  Scan & OCR recognizes every page with the last settings.
- **Reserved names, one rule.** `ReservedFileNames` (PrintCore) is Windows' `DeviceNames.IsReserved` (shared/InkvoltPrint.Core):
  COM0–9, LPT0–9, COM¹ COM² COM³ LPT¹ LPT² LPT³, CONIN$, CONOUT$, trailing dots and spaces trimmed, cut at a colon, its
  tests' cases ported; Batch's names (`BatchNames`), Inkvolt Print's (`FileNameTemplate`) and `ExportTarget` use it.

### Paragraph editing (roadmap 2.1)

Windows' `ContentEditor` paragraph editing (Paragraphs, ParagraphLooks, Forms, Turned, `StandInFonts`) in PdfCore, its
tests first under their names (`ParagraphEditTests` and its parts, `ContentEditorTests`' one-run cases,
`ContentEditFontTests`); `editedParagraphsReadTheSameInPdfJs` is opt-in (`INKVOLTPDF_PDFJS=1`, `pdf/tools/pdfjs-check`)
and `corpusParagraphsTakeTwentyMoreWords` needs `INKVOLTPDF_CORPUS` (the export corpus's PDFs). The app's editor is
`ParagraphEditor.swift`; the self-test is `--only-paragraph-edit`. The document's undo manager takes document edits only
(a text view registering in it crashed), so typing and looks have their own undo inside the editor.

- **Stand-in fonts are Type 3 fonts.** Windows embeds a HarfBuzz subset of a TrueType file (`CidFontWriter`); macOS's
  fonts are often collections or CFF, so the Mac writes Core Text's outlines as Type 3 fonts (`Type3FontWriter`, as its
  annotations' text already is). For a paragraph edit each also gets /Name (`/InkFbN_…`, so `TextFont` reads it as a
  stand-in and doesn't block its text as "a Type 3 font"), /BaseFont by family and style ("Arial,Bold", read back as
  "Arial Bold"; Windows' name says the file, "arialbd") and a /FontDescriptor (ascent, descent, bold and italic flags),
  so an edited paragraph reads back as one with its stand-ins and looks. pdf.js and MuPDF read them as typed.
- **The families.** `StandInFonts` ranks the families macOS ships: Arial (Helvetica's metrics), Helvetica Neue, Verdana,
  Tahoma, Trebuchet MS, Gill Sans, Times New Roman, Georgia, Palatino, Baskerville, Hoefler Text, Courier New, Menlo,
  Andale Mono, each face found through Core Text by family and traits; Windows' Segoe UI, Calibri, Cambria, Constantia,
  Consolas, Palatino Linotype and Lucida Console are aliases of the nearest or not there. Characters none has come from
  Core Text's fallback for the character, never the LastResort font. The look bar lists every family Core Text lists
  (`lookFonts`: CFF and collection fonts work here, where Windows lists TrueType files only); a family named like a face
  ("Arial Rounded MT Bold") is a family of its own on the Mac.
- **ZapfDingbats and Symbol not embedded.** macOS has both fonts: ZapfDingbats is measured with
  /System/Library/Fonts/ZapfDingbats.ttf (its built-in encoding from Unicode's mapping of the Dingbats block, the glyph
  names and widths from the font; Windows reads Adobe's AFM and glyph list, which the Mac doesn't copy), Symbol with
  macOS's Symbol.ttf by its glyph names' characters (Adobe's widths, rounded; the euro 750 as on Windows).
- **The editor is a popover, at a readable size.** Windows lays a rich text box over the paragraph at the page's zoom; the
  Mac's editor is a popover anchored on the paragraph showing its text at 14 points (other sizes in proportion), in its
  family when this Mac has it.
- **Ported with 3.1:** the walk's hidden-layer blocking, clips and paints, and the Translate parts (columns,
  fit): see Translate side by side.
- **For a person to check on screen:** the editor's popover over a paragraph at several zooms and in dark mode; the look
  bar's swatches; VoiceOver reading the editor, its bar and its note; an edited paragraph in Preview and Acrobat (pdf.js
  and MuPDF are checked by the tests).

### Translate side by side (roadmap 3.1)

Windows' Translate in PdfCore (`Translate/`, `ContentEditor+Translate`, `+TranslateTurned`, `+TranslateLinks`,
`+TranslateLooks`), its tests first under their names (camel-cased); the app is `Translate.swift` (Tools › AI Assistant ›
Translate with AI…, the copy beside its original); the self-test is `--only-translate`, with a stand-in translator on
loopback. Mac differences:

- **Run ids aren't unique once an operator draws columns.** The Mac's walk tells runs apart by operator id; a translated
  copy's walk makes a run of each column one operator draws, so each run also has a `key` (its place among the page's
  runs), which the translation code uses where Windows compares records by reference.
- **A shared /Resources copied for one page now shares nothing with the original** (`ContentEditor.ownCopy`). Found by
  the 100-page report: pages sharing one /Resources by reference, with its /Font dictionary direct inside, each got a
  copy for its new fonts that shared that direct dictionary; MuPDF's compacting save renumbered it once through each copy,
  and every page's fonts pointed at other objects (all text read as U+FFFD). The paragraph editor had the same path for a
  one-page edit (`aPageEditedInAFileWhosePagesShareResourcesKeepsEveryPagesFonts`).
  **Fix round 1 (review):** the cause is general, so the safety net is too: before every compacting write
  (`MuDoc.write` with `garbage`) `unshareDirectObjects` walks from the trailer, every reference once (a work list), and
  gives each direct dictionary or array met a second time its own deep copy (64 levels deep, 4 million entries at most,
  for hostile files). The copies are deep where edits make them too: a link's copy for a wrapped line (its inline /A),
  a form copied for one page (translated or edited), PageMarks' resources (headers, footers, watermarks, released in
  1.10) and Flattener's inherited resources (released). Fonts are prepared before any copy, in the dictionary the walk
  read (translatePage, replaceParagraph, replaceText). Checked for the same pattern: redaction, forms and comments copy
  nothing shallowly (stamps build their resources fresh, form faces are streams, FDF import grafts). `SharedObjectTests`.
  **Fix round 2:** past its budget (4 million entries of work) or depth (64 levels) the pass says so and the file is
  written with `garbage=yes` (unused objects dropped, nothing renumbered: correct, not compacted; `lastWriteUncompacted`).
  Entries are walked by index and replaced under their own name objects (any bytes: a /F#E9 key too), copies made in C
  in time linear in their size (`inkv_obj_deep_copy`, bounded the same way). Cost on the bench corpus (debug build):
  the pass 0.00-0.14 s, a 641 MB compacting save 0.52 s with or without it (`UnsharePassTimingTests`, opt-in).
- **One copy of each stand-in font.** `TranslationWriter.finish` adds each Type 3 font once and has every page refer to it
  (Windows embeds one CID font per face); a 20-page report holds at most a dozen font objects.
- **No open-password step.** Windows refuses an AES-256 file opened with its permissions password alone, since PDFsharp
  can't keep its protection without the open password; MuPDF keeps the encryption as it was (`KeptProtection`), so the
  Mac's `makePlan` doesn't ask for it.
- **Timing limits.** Windows' release-build limits of the markup and link tests (750 ms to 1.5 s of processor time) are
  2 to 6 s here: `swift test` builds for debug, and the full parallel run adds to processor time. A quadratic case takes
  hours either way. The run tests' endless body yields instead of sleeping (a sleep's wake-up came minutes late in the
  full run).
- **The test fixtures are written by hand.** Windows draws its report with PDFsharp; `TranslationPdf.report` writes the
  same report (white bands under each line, a ruled table, a figure, a footer) in `ContentEditPdf`'s subsets of Arial,
  Arial Bold and Times New Roman (printable ASCII), its pages sharing one /Resources by reference.
- **Fonts on this Mac.** Stand-ins are the families macOS ships (see paragraph editing); a translation's letters the page's
  fonts lack are drawn in one of them, `Arial` and `Arial Bold` in the looks test as on Windows.
- **For a person to check on screen:** the Translate dialog and its progress sheets; the copy's window with the original on
  the left at several zooms; VoiceOver on the dialog; a translated copy in Preview and Acrobat; a run against a real model
  (Ollama or LM Studio on this Mac): the tests and the self-test use stand-ins only.

### Gotcha: GCD's global queue on CI

Tests that must run while the pool is busy (a Cancel, a deadline's timer) run on threads of their own
(`onItsOwnThread`): GCD's global queue runs only as many blocks as there are cores, and on CI's 3-core runner other
suites held it, so a Cancel came after the render had ended. Endless test streams sleep 1 ms a read rather than spin, and
a timer must not be re-armed per streamed line (millions queued once killed the runner through jetsam).

### Redaction by pattern, Windows' additions (roadmap 1.1)

Windows' redaction by pattern additions (named sets, scans searched through OCR, Check What Was Found, the read-back,
the removal report and CSV, Batch's failure rules, the Pro split) on the Mac, its tests ported under their names.

Mac differences: Vision is always there, so "couldn't be read" means no recognizer was given or it failed, never a missing
OCR language (the wording says text recognition couldn't read it); a page the engine refuses (page checks) is listed as not
searched, makes the check incomplete and fails Batch's file (`RedactionSearchResult.skipped`), where Windows' search
stops; a recognized word that touches a blacked-out area at all is left out of the text laid back (Windows: mostly
inside); a saved set's pattern is ICU's, so one written on Windows can read differently or be refused, and ICU refuses a
pattern nested 990 deep in plain words (A_pattern_nested_very_deep… accepts either); the value check needs no splitting
of its search (ICU has no .NET size limit); Batch's step editor fills its fields from a saved set instead of opening the
sheet. Stricter than Windows after the port's code review: a hit counts as kept only where most of a box lies on a kept
one (Windows: touches, so a value beside a kept one read by OCR passed); values cut past the check's 500 that the patterns
didn't read outside the pages make it incomplete; an earlier version whose objects can't be read makes it incomplete; a
name tree's names aren't searched but the scripts and files they lead to are; a set is deleted from the file it was read
from; the list's VoiceOver labels say whether a line is ticked. Not checked: Vision on a real scan in this flow (the corpus uses the stand-in), a person looking at the list and the
report on screen, VoiceOver on the list.

### Long-term validation (roadmap 3.4)

Windows' 3.4 (PAdES B-LT and B-LTA when signing, Add Verification Information…, Check Signatures Online…, Batch's
action and `--online`, field locks when certifying, the Pro gate) on the Mac, its tests ported under their own names
against `LtvTestPki` on this Mac's loopback (nothing needs the internet). `LtvClient` is the one way online.

Mac differences:
- **Going online.** `LtvClient` resolves a name itself (getaddrinfo), refuses it when any address is this Mac's or a local
  network's, and connects only to the addresses it checked, through Network.framework (`AiSocketTransport`, as the AI
  assistant does for this Mac and the network: no proxy, plain HTTP/1.1, one request a connection, TLS checked against the
  name); Windows checks on the connection made, in `SocketsHttpHandler`'s connect callback. A request's time limit is the AI client's
  `AiDeadline` (one GCD timer: a sleeping task didn't fire while a loaded run kept the cooperative pool busy). Every timestamp the app asks for goes through it
  too, so a timestamp server must use https:// (signing used URLSession with the address typed; the http DigiCert default is
  gone, Sectigo's suggested, as on Windows).
- **Chains** are built by `SecTrust` with network fetching off (Windows' `X509Chain` with no revocation and no downloads); the
  tests trust their root for one check (`Signatures.verify(_:_:anchors:)`, SecTrust's anchors only). Verifying no longer goes
  online at all: `Signatures.verify(online:)` takes what Check Signatures Online brought (`RevocationSnapshot`), not a flag that
  let SecTrust fetch revocation.
- **Batch**: the run's cancel token cancels the long-term task; "offline" means no interface but loopback is up with an
  address (getifaddrs; .NET's `GetIsNetworkAvailable`). The window's list of addresses is worked out in PdfCore
  (`Ltv.plan(files:)`, tested), where Windows' app does it.
- **Check Signatures Online**'s answer counts for the window until it closes (Windows: the tab). It judges each signer's
  chain at the time the window's list was worked out for (its timestamp's), so it asks what the window listed.
- **After the port's review** (Windows the same since PDF 1.14.0.0, but for the last): signing for the long term demands a
  complete chain for the new signature only (an earlier signer whose certificate names nothing usable no longer stops it); a
  CRL that lists the certificate with a date it can't read counts as revoked; a delegated responder is looked for among all
  the certificates its issuer issued for OCSP signing before the cap; a certificate's name is shortened to 120 characters
  where it is shown. **A Mac difference:** a file is encrypted by its trailer, not by the bytes "/Encrypt" anywhere in it
  (signing, Add Verification Information, Batch); Windows keeps the byte rule, which its append and signing paths share.
- **Stricter after the hostile-input review before 1.12.0** (Windows the same since PDF 1.14.0.0): a file whose validation data
  outlasts the check's 20 s never leaves a certificate trusted (a store built to use up the time could hide a revocation);
  what a /DSS names counts as validation data only when nothing else in the document reaches it (an attachment a store
  names stays the document's); a CRL that says which distribution point it is speaks only for certificates naming it; only a
  timestamp from a trusted authority gives a signature its time for the level and the chain (an untrusted one leaves it
  B-B); the no-check extension counts only on an OCSP responder; an address with a space or control character in a
  certificate is no address, and names are shown on one line without control or direction characters.
  Since 1.12.1 (Windows 1.14.0.0's reviews): nor what an annotation written inside a page's list draws with, nor what the
  page tree's nodes hold (an inherited page size or turn, an indirect /Kids array), a node written inside the catalog or
  its parent too (a Mac addition: Windows walks only nodes that are objects of their own).
- **Signature changes**: a key the later revision has with a null value counts as there (a /DSS of null reads as validation
  data, as on Windows, where PDFsharp keeps the null).
- **Tests**: a stalled server waits with `LtvTestPki.pause`, which `stop` ends; the exploding stream packs 64 MB (400 MB on
  Windows) and the time is checked, not .NET's allocation counter; the server is `AiLoopbackServer` (threads of its own).
- **Each reply's connection is closed** once read (`body.close()`): a reply that came whole with its head otherwise kept its
  socket open (8 a file in a probe; a full test run under a shell's 256 open files then failed every loopback test). Measured
  flat after the fix: 25 rounds of Add Verification Information, Check Online and failing requests, 9 descriptors throughout.
Not checked: EU DSS's validator on the Mac's files (`pdf/tools/pades-check` was run on Windows' files only), Acrobat's "LTV
enabled", a real certificate authority and timestamp server (`INKVOLTPDF_REAL_TSA` runs the one test against Sectigo), a
person looking at the windows and the pane, VoiceOver on the address lists.

## Open decisions

None.

Decided: development builds are signed with an Apple Development certificate of the team's, made through the App Store
Connect API key (`dev-cert.sh`) and kept in `~/Library/Keychains/inkvolt-dev.keychain-db` (its password in `.env.local`,
not in git), so they keep their permissions (Screen Recording, Local Network) between builds. It lasts a year
(`NEW-MAC.md`).

## Open

No Mac since November 2026: these wait for the next one (`NEW-MAC.md`).
- Wave 4's paper commands (`pdf/ROADMAP.md`, Batch A: 4.3, 4.4, 4.5, 4.7, 4.13, 4.14), done on Windows. Until 4.4 is
  ported, a Batch preset with `removeBlankPages` or `splitAtBlankPages` is refused on the Mac as an unknown action.
- Inkvolt Print 4.7 (`print/ROADMAP.md`, Wave 4 Batch C): Clean up's Drop a color and Remove punch holes (`ColorDropout`,
  `PunchHoles`), done on Windows.
- Inkvolt Print 4.11: a preset's file named from the first page's text (`TextFinds`, `{text-date}`, `{text-title}`,
  `{text-number}`), done on Windows.
- Inkvolt Print 4.14: scan presets saving Word (.docx) and text (.txt) files (`ScanDocx`, `ScanText`, `PageText`), done on Windows.
- Inkvolt Print 4.8: join two halves of an original too big for the glass (`HalvesJoin`), done on Windows.
- Inkvolt Print 4.16: cards, calendars and collages in Photos (`PhotoProjects`, `PhotoSheet.Lines`/`Texts`; port
  `PhotoProjectsTests`; Foundation's `Calendar` gives the first weekday), done on Windows.
- Inkvolt Print 4.18: a scan preset's PDF/A-2b and password (AES-256, revision 6) (`PdfArchive`, `PdfEncryption`, `IccProfiles` moved to
  the shared core; port `ScanArchiveTests`), and Print a PDF's pages per sheet, booklet and poster (`Sheets/PrintLayout`, moved from
  Inkvolt PDF, and `SheetPrint`; port `SheetPrintTests`; Inkvolt PDF for Mac's own `PrintLayout` stays as it is), done on Windows.
- Wave 4 Batch B, done on Windows, the Mac's waits: 4.17 proofreading marks (`Annotations.Proofreading.cs`: Insert Text,
  Replace Text as a caret and strike-out group, `AnnotationInfo.Grouped`; port `ProofreadingTests` first), 4.10 AI redaction suggestions (Pro;
  `RedactionSuggestions`, `RedactionTerms`; port `RedactionSuggestionsTests` first) and 4.20 save an AI answer
  (`AiAnswerExport`, `AiConversation`; port `AiAnswersTests`).
- Wave 4 Batch C, done on Windows, the Mac's waits: 4.9 two documents side by side (`DocumentWindows`, `TabDrag`; port
  `DocumentWindowsTests` first; on the Mac, NSWindow tabbing and a tab dragged out are AppKit's, so the port is the rules:
  a file open once, the window in use, what is remembered); 4.16 the Reflow view (`Reflow`, `ReflowPosition`; port
  `ReflowTests`; WKWebView with JavaScript off for page content, the same served page).
- Wave 4 Batch C, done on Windows, the Mac's waits: 4.12 calculated form fields and several fields arranged together
  (`FormCalculations`, `FieldCalc`, `FormDesign.CalculationOrder`/`SetCalculationOrder`, `FormDesignRules.Aligned`,
  `SizedAlike`, `Spread`, `WithCalculation`; the Mac's `FormDesigner` gains the anchor and Ctrl+click: port
  `FormCalculationTests` first); 4.22 turning a picture or paragraph to any angle (`ContentEditor.RotateImage`,
  `RotateParagraph`, `PageImage.Angle`, `ContentTurn`; port the tests in `ParagraphEditTests.Rotate.cs`); 4.19 rulers,
  guides, a grid and snapping (`LayoutAids`, `PageGuides`, `Snapper`, `FormDesigner.SnapFor`; port `LayoutAidsTests`);
  4.11 Ask Across Folders (Pro; `FolderAsk`, `FolderIndex.Rank` and `PageTexts`, the send window's file listing; port
  `FolderAskTests` first); 4.21 search by meaning (Pro; `AiEmbeddings`, `AiClient.EmbedAsync`, `MeaningIndex` and its file
  format, the send window before embedding; port `MeaningIndexTests` first); 4.24 a summary read aloud to a file
  (`AiAnswerSpeech`, `WavFile`; AVSpeechSynthesizer's `write(_:toBufferCallback:)` into an AVAudioFile, M4A where Windows
  makes MP3; port `AiAnswerSpeechTests`); 4.23 Edit by Asking (`AskEdit`, `AiClient.AskEditAsync`, the steps window; port
  `AskEditTests`).
- Microsoft Office as E12's converter: off until a person with Microsoft 365 signed in runs its checklist (above).
- "Windows ahead, to port" (under Compare): scans at another size or a quarter turn off, E15's links, folder search's
  phrase reading, the scan cleanup's which-way-up rule (`Upright.MaxLineRatio`).
- Inkvolt Print's Wave 4 Batch C (`print/ROADMAP.md`), done on Windows: 4.9 the print log (the Mac's would read CUPS's
  own job history, `cupsGetJobs` with `CUPS_WHICHJOBS_COMPLETED`, rather than watch a spooler); 4.10 sharing a printer with
  phones (macOS's own Printer Sharing does it; a sandboxed app may only point to it); 4.17 the new-printer Wi-Fi guide (CoreWLAN
  to list and join networks, which needs location access and a check of what the sandbox allows).
- Inkvolt Print: SNMP's "Windows ahead" (P12, 3.2); separator codes (QR code or barcode, PATCHT; "Inkvolt Print scope");
  P12's 2.1, 2.2, 3.1 and 3.3 need a real printer or scanner.
- Inkvolt Print Wave 4 (`print/ROADMAP.md`), done on Windows: 4.12 a camera as a scan source (`CameraSession`,
  `CameraFormats`, `CameraScanTests`; AVFoundation's capture session on the Mac); 4.6 phone as a scanner (`Core/Capture`: `PhoneSession`,
  `PhonePage`, `PhotoPage`, `CaptureScanner` and `PhoneScanTests`; on the Mac the server would be Network.framework's with
  scanner sharing's rules, and the firewall asks there too).
- An inline picture whose filters inflate then discard isn't bounded in time (a MuPDF patch: the owner's call; "A hostile
  file's time").
- Speed: the drawing set's first 20 pages and Find miss their targets, as on Windows (`mac/tools/bench/RESULTS.md`).
- Everything listed under "What a person must look at" and each section's "A person must look at" / "Not checked".
