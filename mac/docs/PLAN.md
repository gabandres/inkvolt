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

Not on the Mac: HP clean-up (nothing like it on macOS), WIA. Separator sheets marked with a QR code or barcode saying
PATCHT, and the QR code on the printed sheet (2026-11-23, Windows' 4236623b): PrintCore's `SeparatorCodes` has Windows'
rules (any case, trimmed, at most 64 characters; a copy over 1,700 px read reduced; a page with more than 3,000 QR
corner-square marks not searched for a QR code, counted on a black-and-white copy made as ZXing's hybrid binarizer makes
it; pixels that don't match the size no code) and the sheet's QR code (version 1, level H, 21 × 21, made once with Core
Image's generator and kept as its modules: PrintCore has no QR encoder). **Mac difference:** the codes are read by
Vision's `VNDetectBarcodesRequest` (PrintMac's `VisionSeparatorCodes`, a `SeparatorCodeReader`: QR, Code 128 and plain
Code 39, no check digit or full-ASCII mode, as ZXing is asked on Windows; Vision returns every QR code on a page where
ZXing's reader decodes one, so a page with a separator code beside another code splits on the Mac), where Windows uses ZXing.Net; `SeparatorCodeTests` (PrintCore, a fake reader) has Windows' rules and
names, `VisionSeparatorCodesTests` (PrintMac) the cases that decode a drawn code (Code 128 from Core Image's generator;
macOS has none for Code 39, so Code 39 is read but not tested). The demo batch has Windows' QR-only sheet (7 pages,
3 files). Not checked: a printed sheet scanned on a real scanner, a Paperless-ngx separator page, a Code 39 sheet.

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
| P12 | The roadmap's items after 1.0 (`print/ROADMAP.md`): PrintCore halves on the PC, PrintMac and the app on the Mac | ProTests and each item's below | Done: 1.1, 1.2, 1.3, 1.5, 1.6, 2.1, 2.3, 2.4, 2.6, 3.2, 3.4, 3.6, 3.7 (3.5 Open in Inkvolt PDF came with Inkvolt PDF for Mac). Left: 2.2, 3.1, 3.3, which need a real printer or scanner |

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
  readings. Pages left and a full cartridge's yield come from LEDM, CDM's capacity, IPP's `printer-supply` and the
  Printer MIB in impressions or sheets, and the page count from IPP's `printer-impressions-completed` and
  prtMarkerLifeCount too (Windows' printer-data work of 2026-11-20, ported 2026-11-23: `IppSupply`, `SupplyPagesTests`). Not checked: the card and chart on screen (light, dark, Increase Contrast, VoiceOver), the save panel, a
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
  Report a Problem has no log ("(no log yet)"). Recordings keep IPP collections and dateTimes (IppText's nested form) and
  SNMP Counter64 and Opaque (2026-11-23, as Windows' f405402a); the Mac's `IppCodec.decode` reads collections and dates
  since then too (before, a collection's member names and values landed on the attribute before it). Not checked: a
  real printer's recording, the window on screen.
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
  **The refused state as Windows' (2026-11-23, Windows' 4e63ad92 and 5a2eea81; what was "Windows ahead"):** a refusal
  is the printer's only from the engine ID its signed answers came from, remembered with its `SnmpDevice` (`engineId`, in
  the state file, not a secret; the monitor takes it at each signed connection, `SnmpDevice.answered`, `isItsEngine`), so
  a switch or UPS that took the address, or a printer never read over SNMPv3, is offline (`PrinterSession.connect`; the
  Fleet page and `status --all` too), and SNMP Access…'s check lets such a refusal be saved anyway
  (`SnmpLoginCheck.refused(_, fromThisPrinter: false)`, Save Anyway); once an agent has answered signed a client takes no
  refusal from it (`SnmpClient.signedEngineId`, `SnmpAccessError.engineId`), so a refusal on a connection whose login has
  answered is offline and the next connection's refusal decides (`aLoginRefusedOnAConnectionReadsAsRefusedNotOffline`
  takes two checks, as Windows). A refused printer alerts as itself (`AlertKind.loginRefused`, an error, after the error
  hold; `PrinterSnapshot.loginRefused`, not reachable, so what was known stands); offline's hold runs on through it and
  offline isn't told once the refusal was (`AlertTracker.outranked`), so refusals spoofed every other check can't silence
  offline; the menu bar's list shows it red (`TrayText.lineLevel`) and the Fleet page counts it an error, not offline
  (`FleetReader.refusedStatus`, the app's rows too). A refusal keeps whether another device answered
  (`PrinterView.anotherDeviceAnswered`, This Is My Printer stays offered: `PrinterMonitor.canAcceptDevice`). Editing SNMP
  Access…'s fields asks again even when the same login is typed back (Windows' `SnmpLoginSave.Edited`; the sheet's
  `onChange`). Tests: SnmpLoginTests, SnmpV3Tests, AlertTests, FleetReadTests (Windows' names; Windows'
  `The_cards_own_offline_state_drops_the_refused_one` reads its view model's source: the Mac's view has one phase, so
  there's nothing to drop). `--report --snmp` says the engine is remembered from a signed answer and a refusal from it is
  the printer's. Not checked: the refused alert, the red line and Save Anyway on screen. **Other protocols (2026-11-23, Windows' dd508526):** SHA-1 and MD5
  (HMAC-…-96), AES-192, AES-256 and CBC-DES, the protocol chosen beside each passphrase, kept with the login as Windows
  keeps it; a short AES key lengthened as Blumenthal's draft, then once as Reeder's. `SnmpCrypto` gives hash and HMAC
  (MD5, SHA-1, SHA-256), AES's block (16, 24, 32-byte keys) and DES's block; DES's weak keys are refused by PrintCore
  (`Usm.isWeakDesKey`; Windows: .NET's DES throws); the PC's stand-ins are in TestSnmpCrypto and TestCryptoMore.
  `--report`'s SNMP lines read the 12 pairs and a Reeder agent with the system's crypto. Not checked: a printer's SNMPv3
  agent, net-snmp's agent, a printer with `public` disabled, any real agent with MD5, SHA-1, AES-192/256 or DES, the
  protocol pickers and the weak note on screen.
- **The printer's panel text, queue change notices (2026-11-23, Windows' 974bf8e5, 003a8648 and 58a35482's fixes).** The
  status card shows "On the printer's panel: …" when the panel says more than the status (`PrinterStatus.panelText`,
  `panelNote`; the Printer MIB's console lines, IPP's `printer-state-message`, LEDM's LocString; `PanelTextTests`).
  Queue change notices: **Mac difference: polling.** macOS's cupsd has no subscriptions (Create-Printer-Subscriptions is
  0x501, not supported, on the build Mac's macOS 27.1), so PrintMac's `CupsQueueNotices` reads the queue list with
  CUPS-Get-Printers (names, device URIs, models only) on a thread of its own, a change from the last read a notice; it
  asks for CUPS's subscription first and would pull its events where a cupsd has them. The pace is
  `QueueNoticePolling`'s (PrintCore): every 2 s while the window shows, every 6 s on battery or in Low Power Mode, and not
  at all while it's closed (the thread waits; the 60 s read of the queues goes on, and cupsd, which launchd starts on
  demand, may exit when idle); opening the window reads the list at once. The thread holds only its `PollingLoop` (a
  stop flag and a wait `stop` and `wake` cut short) and state, not the notices: `stop`, or letting them go, ends it
  (review fix 2026-11-23: it used to poll every 2 s for the app's whole life, window closed or on battery, and the loop
  held the object, so nothing could stop it). `--report … --window-closed 150` closes the window for 150 s and counts
  cupsd's questions. On the build Mac (on power), the polling thread asked once in the first 3 s open, none in 90 s
  closed, and once in the second after it reopened (a first run asked once while closed: a wait already running when the
  window closed; such a wait now asks nothing). cupsd (one pid throughout a 150 s closed run) stayed up and exited 30 to
  60 s after the app quit: the app's
  60 s read of the queues while the window is closed still keeps it up. **Open:** a longer closed-window read,
  or one read only when the menu bar asks, if cupsd should exit with the window closed. A burst is read as one
  (`QueueChangeNotices`, 750 ms quiet, 3 s at most, as Windows); the report's "Queue change notices" line says which way
  and how many queues the last read found. Windows' spooler tests (which notice means a relist, the refresh after lost
  notices) have no Mac counterpart. Not checked: the panel line on screen, a queue added,
  renamed or deleted by hand while the app runs (no queue was changed on the build Mac).
- **A printer's web server on a port of its own (2026-11-23, Windows' 34eac81a and 58a35482).** A web address typed with
  its port in Add a printer (`http://host:8080`) is where its web server is (`PrinterAddress.web`; port 631 or an `/ipp/`
  path is the IPP server, not the web server), and an IPP service's `adminurl` TXT key on a port of its own says the same
  (`DnssdJoin.webRoot`, only when it names the service's host or address; `DiscoveredPrinter.webRoot`). `DeviceHttp`'s
  http or https base moves there (its `web`; the admin password goes to that https port), so LEDM, CDM and the web page
  are asked there, and eSCL on port 80 as well. It travels as `PrinterWhere.webHint` through the session (connect, upgrade
  from SNMP, a look at another address), the monitor's announcements, Report a Problem's recording and `--record … --web`,
  and is remembered as `KnownPrinter.webRoot` in the state file and `printers.json` (`SuitePrinter.webRoot`, read back as a
  scheme and port on the printer's address only). It is kept only where LEDM or CDM answered (`ProbeResult.webRootKept`,
  on Add and at each connection), so a plain address or a port left resets it. The printer's web page opens there.
  `PrinterWebPortTests` (Windows' names). `--report --demo --web-port`: the demo laser typed with `:8080`, probed, kept,
  connected again and remembered, then typed plainly and let go (the made-up network answers on every port). Not checked:
  a real printer whose web server is on a port of its own, an announced `adminurl` on a real network.
- **2.1 Print straight to the printer (2026-11-23).** PrintCore has Windows' encoders (`Printing/Raster`: `RasterPage`,
  `RasterJob`, `RasterWriter` with `PwgRasterWriter`, `UrfWriter` and `PclmWriter`; PCLm's Flate is PrintCore's `Deflate`, one
  block of fixed Huffman codes, where Windows uses .NET's ZLibStream) and the plan and job (`Printing/Direct`: `IppPrintCaps`,
  `IppCapsCache`, `DirectPrintPlan`, `DirectJob`, `PrinterJobs`, `PrintRoutes`; `IppRequest` and the job operations in
  `IppClient`; `IppCodec` now reads resolutions, ranges and every group). Print a PDF on a network printer macOS has no queue
  for, whose IPP lists PWG raster, Apple raster or PCLm, asks copies, paper, both sides and color from the printer's own
  attributes, asks the printer whether it can print, draws the pages off the main thread (PrintMac's `DirectPrintPages`:
  PDFKit at the plan's drawing resolution, fitted inside the paper's margins, a landscape page turned a quarter) and sends
  them with Print-Job; a small window follows the job to its end, with Cancel (the app's `DirectPrinting`). **Mac
  differences:** a plan's problem is a `DirectPrintProblem` where Windows has
  an out string; the job's Print-Job body (its attributes, then each page as it's encoded) goes to a temporary file that
  URLSession uploads and that's deleted after, as Windows streams its raster file, but a job past 1 GB is refused before
  anything is sent with the printer's too-large words (`DirectJobFile.maxBytes`; Windows has no limit), and the PDF is
  opened again from its file off the main thread; the printer that
  wants a signed-in user is sent to Set Up in macOS; Get-Jobs' jobs keep their IPP `job-state` where Windows maps them to the
  spooler's status bits; `DirectPrintTests`' Photo_names_map_both_ways and the AppState file check aren't ported (Windows'
  Print Photos and state file). Proved without a printer as Windows did: libcups' raster reader takes our PWG and Apple
  raster with their header fields and pixels, Core Graphics draws our PCLm's strips back to the same pixels, and CUPS's
  `ippeveprinter` (macOS ships it) takes a Print-Job of each format from PrintCore's client and keeps the bytes sent
  (PrintMacTests' RasterCupsTests and IppEvePrinterTests; research file). Tests: RasterEncoderTests and DirectPrintTests
  (Windows' names), DirectPrintPagesTests (Mac only). `--report --demo --direct-print`: the demo inkjet routed straight, its
  caps and plan, three pages drawn into the job file and sent, the job followed; then the window's own flow
  (`DirectPrinting.run`) cancelled the moment the job has its id, the made-up printer seeing Cancel-Job for it. The review
  (2026-11-23, fixed as Windows does): Cancel-Job and Print-Job run in tasks of their own, so a cancel neither stops the
  Cancel-Job it asks for nor cuts a job halfway (it's Cancel-Job once the printer gave an id); "page N of M" counts
  `DirectPrintPlan.impressions` (Windows' PagesPerCopy × Repeat × Copies) and the state Print-Job answered is used; a watch
  ends after 2 hours however the printer's count goes (`DirectJob.watchLongest`, Windows too) and says so.
  **The rest of 2.1 (2026-11-27).** Print routing as Windows has it (PrintCore's `PrintRouting`, `PrintRouter` with
  `RoutedBatchQueue` and `RoutedJobQueue`, `RouteRead`; PrintRoutingTests, RouteReadTests and DirectPrintTests.Queues.cs
  ported under Windows' names): a network printer's jobs go to its macOS queue, straight to it when it has none, when the
  person chose that (the Print menu's Print straight to the printer (no macOS queue), shown where the printer has a queue and
  takes jobs straight, kept per printer in the state file's `directPrinters`, Windows' `DirectPrinters`), or when macOS can't
  print through its queue (Windows' broken driver, master 09a33387: `RouteChoice.queueBroken`, `PrintRouteNote.directQueueBroken`).
  The command line's `print --printer` decides the same way (`BatchPrinterLookup`): a queue's name, a printer's name in
  Inkvolt Print (its queue, or straight to it), or an `ipp://`/`ipps://` address, straight with the pins kept for it, read
  only (`ReadOnlyPins`).
  The Print menu and the print queue card say where the pages go (`PrintRouteNote.text`, Windows' words with macOS's queue).
  Every print goes where the router says, decided afresh for each: Print a PDF (one page a sheet; its Layouts laid out by
  `SheetPrintView` on the paper the printer's plan chose and printed on the whole sheet, a booklet asking for both sides and
  going by hand on a printer that prints one side), Copy, a scan preset's print step, an ID card copy, the clipboard, a
  recent scan and a separator sheet (`Printing.print`), Print Photos (the sheets on their own paper, borderless where asked,
  a card with a message on both sides), Batch print (a network printer with no queue is listed; a queue a network printer
  claims is routed file by file: `DirectBatchQueue` through PrintMac's `DirectBatchJobs`, each job followed to its end before
  the next) and two-sided by hand (its fronts and backs through the same routed queue, `PrinterModel.batchQueue`). Every
  kind goes through PrintMac's `DirectPrinter` (Windows' `DirectPrinter.PrintAsync`: the PDF drawn into the job file,
  Print-Job, followed, Cancel-Job; a batch's job finishes whatever Stop says once sent), with `DirectPrintPages.Layout`
  saying whether a page is fitted inside the printer's margins (`.fitted(sizing)`) or is a sheet laid out for the whole paper
  (`.sheet`, as Windows' paginators lay out on the whole paper). Job alerts read a direct printer's own job list
  (`DirectJobWatch`, following the last route decided), and the print queue card lists it with Cancel-Job. The batch runner
  now asks the queue for its no-answer words, its time limit and whether a job sent ends on its own (`BatchQueue.noAnswer`,
  `sendLimit`, `endsOnItsOwnOnceSpooling`, Windows' `IBatchQueue`). **Mac differences:** a queue macOS can't print through
  (Windows' driver Windows can't load) is one cupsd stopped because its driver failed: `printer-state` stopped with
  `cups-missing-filter` or `cups-filter-failed` among its reasons, or a "Filter failed" message, as the last read of the
  queues says (`PrintRoutes.queueWorks`); one macOS no longer lists has no queue. A queue someone paused in Printers &
  Scanners or set to reject jobs (`cupsreject`) keeps the queue's route, with macOS's own words for it: they did that on
  purpose, its jobs wait there as on Windows, and printing around it would print what someone tried to hold; `PrintRouting`'s calls
  return the decision's task (Swift's starts once the caller yields: its tests await it, RouteReadTests wait for a read to
  start) and its listeners are closures (`listen`), Windows' event; the router's lookups are async (the app reads its
  printers on the main actor); a direct printer's job list says no other computer prints there, so a job that doesn't name
  its computer, or names it by address (the printer names this Mac so), is yours when its user is, as on Windows (a macOS
  queue's rule is stricter); a failed direct job's alert gives the printer's words (`QueueJob.problem`, Windows'
  `Problem`); the command line's queues are CUPS destinations (by name or the name System Settings shows, never a virtual
  one), a remembered printer's queue the one the printer list claims for it, and its printers, pins and choices the app's
  own state file (the command runs inside the app); a layout's copies are made by the printer or sent again as one job, where macOS's panel made them. Tests: PrintRoutingTests
  (and the Mac's queue check: paused, rejecting, a failed filter, gone), RouteReadTests, DirectPrintTests+Queues (with the
  command line's printer and the state file's choice); PrintMac's
  DirectPrinterTests send each layout, a stop before sending and a batch to `ippeveprinter`, and read its job lists; its
  opt-in `INKVOLT_DIRECT_PRINTER=ipp://…` sends one page to a real printer (2026-11-27, the build Mac and the HP M234dw
  with no queue used: PWG raster at 300 dpi on Letter, followed to Printed).
  `--report --demo --direct-print` then sends each kind to the demo inkjet through the app's own route (`kindsCheck`: the
  note, Print a PDF, Copy, a booklet laid out on the printer's paper, a 4 × 6 photo sheet borderless, a batch of two files
  through the printer's routed queue, job alerts' read; all printed, 2026-11-27). Not checked: the app's own prints on a
  real printer (the M234dw printed DirectPrinter's page; its PCLm and Apple raster weren't tried), the options dialog, the progress window, the
  Print menu's choice and the card's note on screen and with VoiceOver, Cancel mid-job on a real printer, a long document's
  memory, a real queue stopped by a failed filter giving way to the printer.
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

### Wave 4 (print/ROADMAP.md): what differs and what's left, per item

Ported test-first from the .NET tests (same names in lower camel case); PrintCore on the PC, the app on `buildmac`.

- **4.1 Two-sided scanning on a one-sided feeder.** PrintCore `TurnedStack` (`TurnedStackTests`), the preset's
  `turnStack` (Windows' field name `TurnStack`), `PresetPlan.turnStack` (`turnsStacks:`, Inkvolt PDF's Scan leaves it off),
  `ScanChoices.offersTurnStack`; the review's pairing is `ScanPages.pair`/`unpair` with `StackScan` (Windows keeps it in its
  view model; `aTurnedStacksPagesPairAndUndoInTheReview` is Mac only). The question is an `NSAlert` (Scan the Backs / Only
  the Fronts); `--report … --turn-stack` answers it yes. **Mac differences:** a negative count reads as none and
  `separatorBacks` answers nil for flags that don't fit (Windows throws); only patch code sheets are separator sheets (no QR
  or barcode sheets on the Mac yet); a scan stopped during the backs keeps them in order, as Windows does, but a preset then
  doesn't save by itself (Windows saves); the review's Undo, which held only clean ups, now also takes the stack's order and
  Backs in the Other Order back (each one step, as Windows, and each with its own copy of the stack and its marks, as
  Windows' steps hold its `StackScan`: `ScanPages.swapBacks`/`undoSwap` with `StackSwap`, so a scan since, which lets the
  review's stack go, loses no sheet's mark), still not turns, crops or moves by hand; the demo's stack comes
  from the USB demo laser (`DemoScanDevice`, a one-sided feeder; the eSCL demo inkjet's feeder scans both sides). Not
  checked: a real one-sided feeder, either kind of output tray, the alert and the button on screen, VoiceOver.
- **4.3 Pages turned upright on their own.** PrintCore `PageUpright` (`find`, `orient`, `straightenBy`, `suitsLanguage`),
  `PageEdits.checked`/`turnedUprightBy`, `ScannedPage.uprightTurns` and `ScanPages.undoUpright`, the preset's `turnUpright`
  (on unless turned off, Windows' `TurnUpright`); `UprightTests` (PC), `PageUprightCorpusTests` (PdfCoreTests on the Mac:
  the OCR corpus's typeset pages fed each way round). Inkvolt PDF's `ScanCleanup`, `Deskew.measure`, `PageRotate`,
  `PaperLevel`, `Upright` and `GrayImage` moved into PrintCore (Windows has them in the shared core), so the scan review and
  Recognize Text read a page alike, `Upright` with Windows' newer reading (pictures and rules left out); PdfCore keeps its
  `CancelToken` wrapper (`ScanCleanup.clean(…cancel:)`, `Despeckle`). `Deskew.angle` is `measure`'s angle now, as on Windows
  (the Mac's had its own copy). **Mac differences:** the language a page is read in when none is chosen is the Mac's first
  preferred language (Windows: its OCR's default); `suitsLanguage` asks Foundation's `Locale.Language` for right-to-left
  where Windows asks CultureInfo; Undo turns back only pages still as the check left them (a turn by hand since stays: the
  Mac's review has no Undo of its own for turns); a page restored after a crash reads "Edited", not "Turned upright" (the
  recovery folder keeps no check turns). Not checked: real feeder scans, pages in scripts it leaves alone, the note on
  screen.
- **4.4 Small black-and-white PDFs.** PrintCore `BitImage`, `Bilevel`, `CcittG4` (the same bytes as Windows' encoder) and
  `PdfWriter.Page.blackAndWhite`/`oneBit`, so Inkvolt PDF for Mac's 4.8 can write such pages too; the preset's `smallerFile`
  (Windows' `SmallerFile`), `ScanPresets.savesSmallerFile`, `PresetPlan.oneBit` (scanned in grey), the summary's "black and
  white, N dpi, smaller file"; a page's `oneBit`, kept for crash recovery (`KeptPage.oneBit`, as Windows' `ScanKeeper`);
  PrintMac `ScanImaging.bits` (the saved page decoded grey at full size) and `ScanPdf.Page.bits`.
  `BlackAndWhitePdfTests` (PC; Windows' T.6 decoder ported as the test's own) and `CcittG4RenderTests` (PdfCoreTests on the
  Mac: MuPDF reads G4 and Flate pages bit for bit; a corpus text page against its JPEG). **Mac differences:** Flate is
  PrintCore's own `Deflate` (one block of fixed Huffman codes, LZ77 through a 3-byte hash; Foundation only, so the PC tests it,
  read back by an inflater the tests write from RFC 1951), where Windows uses .NET's `ZLibStream` and Inkvolt PDF for Mac's
  exports Apple's Compression; it is only the fallback for pages G4 codes badly (fine, even patterns), so it needn't match
  zlib's size. The Mac scans no black and white (`ScanColor` is color or grey), so only a preset's smaller file saves one bit
  (Windows' `ScanChoices.SavesOneBit` has no Mac use); a size refused throws `BitImage.SizeError`; a page that can't be made
  black and white (past `BitImage.maxPixels`) is saved as its JPEG. `--report … --smaller-file` saves the demo feeder's pages
  both ways and has PDFKit draw the 1-bit page. Not checked: a real scanner's pages, Preview and other readers on screen, a
  printed copy.
- **4.7 Drop a color, remove punch holes.** PrintCore `DropColor`/`ColorDropout`, `PunchHoles`, `PageFilters.dropColor` (16)
  and `.punchHoles` (32) among the pixel filters (Windows' numbers, so presets read alike), `PageCleanup.apply(…drop:)`,
  `for(_:grey:)`, `describe(_:drop:)`, `CleanedPage.holes`, `PageEdits.drop` (`withFilters(_:drop:)`, `cleanedUp(…drop:grey:)`;
  the init sets red with the filter, so a color is never without it), `KeptPage.drop`, the preset's `dropColor` (Windows'
  `DropColor`, "#RRGGBB"); `CleanUpMarksTests` (PC). The app: the four clean up switches become six (Scan settings, each preset,
  the review's Clean Up… view) with Color to drop (Red, Green, Blue, a picked color with its swatch); the Clean up view's Pick
  from the Page shows the page as scanned and takes the colour of the 5 × 5 pixels clicked (grey, black or paper is said and
  the next click tried); a grey scan is never said to have a colour dropped; the demo glass holds a punched order form
  when a scan drops a color or removes holes (`DemoScan.punchedForm`); `--report … --cleanup-marks`. **Mac differences:** RGB
  where Windows has BGR (the tests build their pages as RGB); a page is grey when its JPEG has one component (Windows asks
  its decoder); the Mac's 2.3 tests that ran `.pixelFilters` on a grey page now name the three 2.3 filters (a grey page has
  no colour to drop and no holes). Not checked: real punched sheets from a feeder and a flatbed, a real pen's and a form's
  colours, picking a colour on screen (the crosshair, VoiceOver).
- **4.8 Join two halves.** PrintCore `HalvesJoin` (`find`: normalized cross-correlation on coarse copies of at most 400
  pixels a side, every side either way up, the six best refined, sure only when well ahead of the next; `find(…dpi:)` on the
  full-size halves, through grey copies of about 100 pixels an inch (`analysisFactor`), the placement back in full-size
  pixels; `previewFactor` for the preview's copies; `join`, `gray`,
  `shrink`, `fromCopy`/`toCopy`, `edgeToEdge`), `JoinPlacement`, `JoinFound`, `ScanPages.join`/`unjoin` (the joined page keeps
  the first half's new-file mark); `HalvesJoinTests` (PC). PrintMac `JoinImages` (each half as saved, RGB at full size; the
  joined page as JPEG). The app: the page's Join with the Next Page… (refused for the last page, separators, photos, pages
  being checked or at another resolution, each said), a sheet that shows the joined page, arrows to move the second half (a
  fiftieth of an inch, ⇧ and an arrow key or a ⇧-click a fifth), Turn the Second Half, Other Side, Join (one step of Undo:
  the halves come back); the second half starts where it was found, sure or not, whatever its score (as Windows); the
  preview joins copies made once when the sheet opens, the halves side by side at most about 900 pixels (Windows 1600).
  `--report … --join` joins the demo glass's two halves of a 14-inch plan (`DemoScanSetup.hold`). **Mac differences:** a
  nudge is a fiftieth of an inch, a fifth with ⇧ (Windows a twentieth and a half: the Mac's preview is smaller, and a
  fiftieth is a pixel or two of it at 300 dpi); a stop is a `BatchStop` (`CancellationError`); the coarse search's
  placements are put in a fixed order before the best are taken (Windows' come from parallel rows in any order), so the same
  halves always give the same answer; the halves are RGB whatever was scanned (a grey and a colour half join), where Windows
  keeps the channels both have; a join placed past Int's range is refused. Not checked: a real A3 drawing on a letter or A4
  glass, the sheet on screen (the arrows' keys, VoiceOver).
- **4.11 Name the file from its contents.** PrintCore `PageText.lines`/`withoutStrays` (`TextLine`), `TextFinds` (`find`,
  `dayFirst`), `FoundInText`, `TextDate`, `NameContext.found`, `FileNameTemplate`'s `{text-date}` (with a format),
  `{text-title}` and `{text-number}` (what the page doesn't say takes its separator with it) and `readsText`, `PresetPlan.ocr`
  for a name read from the page (a PDF preset's file becomes searchable, as on Windows); `NameFromTextTests` (PC). The app:
  `ScanModel.showsSaveName`, `saveName` (filled once the scan's pages are checked and again when the first page changes,
  unless typed: `editSaveName`), the first page read by Vision as it will be saved and kept for the save (`foundFor`, by the
  page's id and edits), the first file of a save named as typed; the save bar's File name field beside Save (preset); the
  editor's caption for the tokens; the demo glass's made-up invoice (`DemoScan.invoice`); `--report … --name-from-text`.
  **Mac differences:** a locale where Windows has a culture (`Locale.current`; day or month first from its short date as ICU
  writes it, the month names from `DateFormatter`'s lists); a found date is a `TextDate` (a day, no clock) written with UTC's;
  lengths count characters where .NET counts UTF-16 units, and a name is also cut to 200 UTF-8 bytes
  (`FileNameTemplate.maxNameBytes`: APFS allows 255 bytes, so a long Chinese or Japanese title would not save); a name's
  reserved characters are found scalar by scalar (a '/' with a combining mark after it is still a separator); the field shows for a preset that stops on the review, as on
  Windows, beside Save rather than above the pages. Not checked: real invoices and receipts, the field on screen (VoiceOver).
- **4.14 Scan straight to Word or text.** PrintCore `PageText.paragraphs` (`TextParagraph`), `ScanDocPage`, `ScanDocx`,
  `ScanText`, `PresetFileType.word` (3) and `.text` (4) (Windows' numbers), `ScanPresets.isPdf`/`fileExtension`, the
  summary's "Word document" and "Text", `PresetPlan`'s notes without text recognition; the Office parts Inkvolt PDF for Mac
  wrote with (`XmlOut`, `OpenXmlParts`: `xml`, `clean`, `cut`, `contentTypes`, `coreProperties`, `appProperties(application:)`,
  `relationships`) moved from PdfCore into PrintCore (`Office/OpenXmlParts.swift`), as Windows moved them to the shared core;
  PdfCore keeps its `ZipWriter` (Apple's Compression deflates), `entry`, its own `appProperties`, `twips` and `emu`, so its
  exports are byte for byte as before. `ScanToDocumentTests` (PC). The app: the editor's As list gains Word document and
  Text, with the text language and a note when the preset opens in Inkvolt PDF; a preset save writes the file
  (`ScanModel.writeDocument`: each page read by Vision as saved; a page of photos as its photos, one with no text read as
  the page itself), Print a copy prints the pages; `--report … --word-text`. **Mac differences:** the .docx's parts are
  stored, not deflated (PrintCore's `Deflate` is a fixed-Huffman fallback and the tests read stored entries with
  `ZipArchive.entries`; the pictures are stored on Windows too), so a page of text makes a few kilobytes more; the
  misread-text test's lone surrogate is U+FFFF (a Swift string holds none); a Word or text preset's scan reads as a
  searchable PDF in the tab while it is on screen (its Save… saves one). Not checked: Word and Pages on this Mac opening the
  file, real letters and forms. PrintCore's `PageText`, `TextParagraph` and `ScanText` share their names with PdfCore's
  (as Windows' two cores do): a file that imports both names PdfCore's in full (`PdfCore.PageText`).
- **4.9 A print log.** PrintCore `PrintLog` (`PrintLogEntry`, `PrintLogMonth`, `PrintLogTotal`, the month totals, the CSV,
  `demo`), `PrintLogFile` (`print-log.jsonl` beside the state file, Windows' JSON lines and rules: appended, written again a
  fifth past 10,000, a file it couldn't read never written over), `PrintLogRecorder` and `PrintLogKeeper`, `FinishedJob` and
  `FinishedJobAttributes` (the Get-Jobs attributes as hostile input), `FinishedJobHistory`; `ProFeature.printLogExport`;
  `PrintState.printLogOff`/`printLogSince`; `PrintLogTests` (PC). PrintMac `LibCups.finishedJobs` (IPP Get-Jobs over cupsd's
  socket for every queue, `which-jobs=completed`, the newest 100 each minute, all it keeps at launch; `jobGroups` shared with
  job alerts' read). The app: Window › Print Log (⌥⌘L; `PrintLogWindow`: the switch, the month, By printer, By person, the
  month's jobs, Export… behind Inkvolt Pro, Clear the Log…); `--report … --print-log`. **Mac differences:** the Mac reads
  CUPS's own history of finished jobs where Windows watches the spooler's notices, so no job is followed while it prints: a
  job is logged once it has finished, by its id and creation time (`FinishedJob.key`, kept in the file as `Job`), and jobs
  printed while Inkvolt Print was closed are logged at the next read while CUPS still lists them (Windows logs only while it
  runs). The switch is a moment (`since`): jobs that finished before the log was turned on (the first launch that keeps one,
  the switch, Clear) aren't logged, as Windows doesn't log jobs printed before it watched. How it ended: a completed job, or
  one cancelled or aborted after a page printed, printed; cancelled before, cancelled; aborted before (CUPS gave up), left.
  Pages are `job-impressions` when CUPS knows them, else the pages printed over the copies; printed is
  `job-impressions-completed` (copies included), else `job-media-sheets-completed`; color and two-sided come from the job's
  `print-color-mode` and `sides` (not known when the printing app set them in its driver's own options). The printer is the
  queue's name as macOS shows it; a job from this Mac (`localhost`) names no computer. cupsd leaves out other users' names
  and documents: they total under "(not known)". There is no command palette, so the menu item is the way in. The demo's
  three months come from a generator of its own (Windows' `System.Random` can't be reproduced). The file tests that make a
  file unreadable or its folder read-only (Windows holds it open) run on the Mac only. Not checked: a person watching a week
  of real jobs against the printers' own counts, the window by eye and with VoiceOver.
- **4.12 A camera as a scan source.** PrintCore `Capture/`: `CameraSession`, `CameraFormats` (`choose`, `rgb`), `Cameras`,
  `CameraFeed`, `CameraFrame`, `DemoCameras`; the photo-to-page step 4.6 shares: `CapturedPhotoInput` (Windows' `PhotoInput`, renamed beside Print Photos' own; a photo's header read as
  hostile input), `PhotoPage` (EXIF orientation, the page found and warped, its paper, `captureResolution`), `PhotoCodec`,
  `CaptureScanner` (a `ScanDevice` over a `PhotoChannel`); `Imaging/Trapezoid` (`Homography`, `Perspective`, the page on a
  desk, ported from Windows' `PageWarp.cs`; its book-curve half isn't). PrintMac `AVCameras`/`AVCameraFeed` (a discovery
  session over the built-in, external, Continuity and Desk View cameras; the format `choose` picks; 32BGRA frames, one
  copied only when Capture asks, a capture with no frame in 5 s none), `ImageIOPhotoCodec`. The app: Use a Camera… beside
  Scan (its menu: with a preset), the camera window (`CameraWindow`: the camera picker, AVFoundation's live picture,
  Capture Page with Space, Done; closing it ends the scan), `ScanModel.scanWithCamera`/`CaptureScan` (the capture's pages
  through the scan's own checks, review and preset save); the entitlement `com.apple.security.device.camera` and
  `NSCameraUsageDescription` (English and Spanish), in `pkg-preflight.sh` too; `--report … --demo --camera`. Tests:
  `CameraScanTests` and `PhoneScanTests`' photo half (PC). **Mac differences:** pixels are RGB (Windows BGR), AVFoundation's
  BGRA rows read with their own stride; the live picture is AVFoundation's preview layer, so the feed sends no preview
  frames (Windows copies one ten times a second); a capture that gets no frame in 5 s gives up; the window's Capture Page
  is Space as on Windows; the capture is a button beside Scan on a printer's Scan tab (Windows also has a page with no
  scanner, the sidebar's), and it adds to the pages there as Scan More does, a preset's too (Windows starts a preset's
  afresh after asking); demo mode's document camera is a made-up page lying at an angle on a desk, its window shows that
  still frame. Not checked: a real camera's picture and a page captured through the window (the build Mac is used over
  SSH, so the camera permission's alert and the live picture need a person), a document camera, an iPhone as Continuity
  Camera, VoiceOver on the window.
- **4.6 Phone as a scanner.** PrintCore `Capture/`: `PhoneSession` (the token, pairing, the cookie bound to the phone's
  address, photos bounded and checked before they're decoded, into a `PhotoChannel`), `PhonePage` (Windows' page and script),
  `PhoneScan` (`open`, `statusText`, the address and URL), `PhonePeers` and `PhoneConnections` (scanner sharing's rules and
  limits), `PhoneHttp` (HTTP/1.1 over a connection whose TLS is done: Kestrel's limits, read as hostile input),
  `PhoneCertificateDer` (the self-signed X.509 for an ECDSA P-256 key, .NET's `CertificateRequest` output, through SNMP's BER
  encoder). PrintMac `NetworkPhoneHost` (Network framework's TLS listener on 9781, `acceptLocalOnly`; refused devices
  cancelled before TLS), `PhoneCertificateKeychain` (the key and certificate in the app's keychain, made anew 30 days before
  the end), `KeychainFile` (a keychain file of its own for a run), `SystemPhoneNetworks`, `PhoneQrCode` (CoreImage's
  generator), `LoopbackPhone` (a phone on this Mac, for checks). The app: Use Your Phone… beside Use a Camera… (its menu: with
  a preset), the phone window (`PhoneWindow`: the code, the address, the certificate's first bytes, the phone's state, Done;
  closing it ends the scan), `ScanModel.scanWithPhone` through the camera's `CaptureScan`; `--report … --demo --phone`.
  Tests: `PhoneScanTests` (all of PhoneScanTests.cs, PC) and `PhoneServerTests` (over HTTPS on loopback, Mac).
  **Mac differences:** macOS has no Private/Public network setting, so a served network is an Ethernet or Wi-Fi IPv4 one
  (Search my network's interfaces: no VPN tunnel, bridge or AirDrop) whose address is private (RFC 1918) with a /8 to /30
  subnet; IPv6 devices aren't served (the code holds the IPv4 address) and the "set it to Private" advice is "join your
  home or office network". Network framework serves TLS, PrintCore speaks HTTP/1.1 itself (no Kestrel): a body sent with a
  transfer coding is refused (411; the page's `fetch` always gives a length). The certificate is the phone scan's own
  ("Inkvolt Print phone scan"; Windows' is scanner sharing's, which the Mac doesn't have), in the sandboxed app's keychain;
  demo mode and the tests make theirs in a keychain file of their own in a temporary folder (never the login keychain or the
  search list), deleted after (owner's decision, 2026-11-23). The port is open only while the window is; a refused device's
  connection is cut before TLS, and checked again once it's up for the address of this Mac it reached. macOS's firewall:
  off by default; when on, "Automatically allow downloaded signed software" (on by default, and on on the build Mac) lets
  the signed app listen with no question; with that off, macOS asks once "Do you want the application "Inkvolt Print.app"
  to accept incoming network connections?", and Deny leaves the phone unable to reach the page (it says the Mac can't be
  reached). Listening and accepting don't need Local Network access (TN3179). Checked on the build Mac (2026-11-24,
  `--phone-hold` and `mac/tools/phone-client.sh`, curl as the page): a wrong code 404, pair without the page's header 403,
  two photos in as pages, not a photo 415, a chunked body 411, a second device 403, Done, the port closed after (an
  answer to a body left unread, 411 or 403, reached curl as a reset 3 times in 4: the connection closed with the body's
  bytes unread and Darwin reset it; fixed: `PhoneHttp.drain` reads and drops such a body after the answer, up to its
  length within 5 s, as Kestrel does); the Mac
  closing the window mid-upload cuts the photo's connection (the page says the Mac can't be reached), keeps no page and
  closes the port; with the app in Spanish the page is too (its language is the app's, not the phone's Accept-Language,
  as on Windows). No simulator or emulator was driven: T3's device tools had no build-Mac host. Not checked: a real phone on Wi-Fi (Safari
  past the certificate warning, several pages, Done; an Android phone's Chrome), the app's own keychain on a user's Mac
  (the build Mac's account isn't touched: only keychain files of the test's own), the firewall's question with automatic
  allowing off, VoiceOver on the window.
- **4.15 Recent scans.** PrintCore `RecentScan`, `RecentScans` (`add`, `clean`, `present`, `remove`, `day`, `usable`),
  `RecentScanDay`, `PrintState.recentScans`; `RecentScansTests` (PC). The app: every save (Save…, a preset's) goes on the list
  with the scanner's and preset's names (`ScanModel.finishSaving`, `AppModel.noteRecentScan`); the save bar's Recent Scans…
  opens a sheet listing them (`RecentScansSheet.swift`), the files gone checked off the main thread and dropped from the
  list as it is by then, each with Open, Show in Finder, Email Again (the Mail sharing service), Print… and Remove from
  List, and Clear the List…; `--report … --recent-scans`. **Mac differences:** an entry keeps an app-scoped security
  bookmark of the folder it was saved in (or of the one file the save panel named) in `access`, the sandbox's way back to
  it in a later run (Windows needs none); a file whose bookmark no longer resolves counts as gone. A usable path is a
  full POSIX path (`/Users/…`, `/Volumes/…`), not `/dev/…`, with no `.` or `..` part or control character (Windows: a
  drive or share path, no device path or alternate stream); a quote is allowed (a Mac name may hold one). Print sends
  several PDFs as one job through the print panel (Windows opens them in Batch) and isn't offered for a Word or text scan
  (Windows sends those to Print photos, which can't read them); pictures go to Print Photos with their folder held open
  until the next. The list is reached from the Scan tab only (Windows also from the sidebar, without Print). The demo has
  no stand-in for Open or Email (Windows' demo says what would happen). Not checked: the sheet on screen, Open, Email
  Again and Print with a real mail app and printer, a network volume's files, VoiceOver.
- **4.13 Print the clipboard.** PrintCore `ClipboardPrint` (`choose`, `prefersPicture`, `layout`, `pages`, `expand`, `wrap`,
  `width`, `name`), `ClipboardContent`, `ClipboardWhat`, `ClipboardPlan`, `ClipboardTextLayout`, `PixelSize`;
  `ClipboardPrintTests` (PC). The app: the Print menu's Print the Clipboard (⇧⌘V; `ClipboardPrinting.swift`): files copied in
  Finder as they are (one PDF through `Printing.printPdf(_:on:app:)`, split from Print a PDF's panel; pictures to Print
  Photos; several to Batch Print), a picture (its size read from the PNG or TIFF's header before it is decoded) saved as an
  opaque PNG for Print Photos, text laid out on Letter, or A4 where the region is metric, and printed through the print panel
  at its own size; what can't print said in an alert. `--report … --clipboard` (on a pasteboard of its own).
  **Mac differences:** the text PDF is vector text (Menlo drawn at the size whose advance is the layout's column, Windows'
  Consolas measure) where Windows draws 1-bit pages at 300 dpi; lengths and columns count Unicode scalars (.NET UTF-16
  units; a character past the BMP is two columns on both); a Swift string holds no lone surrogate (that test line has no
  counterpart); text whose UTF-8 is past 4 × `maxChars` bytes is said too big before it's read (`ClipboardPrint.textTooBig`);
  the choice, the text's pages and a picture's PNG are made off the main thread, with no Cancel (300 pages take well under a
  second); a text cut
  past 300 pages is said in an alert before the print panel (Windows' message line); the made files go in the app's
  temporary folder, cleared of anything a day old. Not checked: Finder's copied files read from the clipboard in the sandbox
  (macOS grants a pasted file), Word's and Excel's text-and-picture copies, the print panel's preview, VoiceOver.
- **4.2 Two-sided printing by hand.** PrintCore `HandDuplexPlan` (`plan`, `fronts`, `sheetBacks`, `backs`, `reload`),
  `HandDuplexReload`, `OutputFace`, `HandDuplex` (`offered`, `faceOf`); `BatchPrintLine.byHand`, `BatchPrintOptions.turnStack`
  and the runner's by-hand path (the fronts, the prompt, the backs, each pass held to the estimate, the fronts said printed
  whatever stops the backs), page 0 a blank side in `DemoBatchQueue` and PrintMac's `CupsBatchQueue` (the size of the page
  before it), `CupsBatchQueue.outputFace` (cupsd's `output-bin-default` and `printer-output-tray`); `HandDuplexTests`,
  `HandDuplexBatchTests` (PC). The app (`HandDuplexPrinting.swift`): the prompt (an alert: which way up the sheets came out,
  starting from the face chosen last for the queue, else the printer's, else face down; the steps follow it; Print the Backs
  or Stop); Batch Print's Two-sided always on offer, a file two-sided on a one-sided queue printed by hand; the Print menu's
  Print a PDF on Both Sides by Hand… where the queue can't print both sides (copies asked, then straight to the queue as Batch
  sends a file); Print a PDF's booklet on a one-sided queue printed by hand as Windows' `SheetPrinting.PrintAsync` does
  (`HandDuplexPrinting.printSheets`: copies asked, the sides drawn by `SheetPrintView` into a PDF of their own at the queue's
  default paper with two-sided on the long edge, so each turned back is half-turned, then the runner's by-hand path, the
  prompt naming a set-aside sheet by the document's page, `BatchPrintLine.pageNumbers` from `SheetPrint.sideNumbers`);
  `--report … --hand-duplex`. **Mac differences:** Print a PDF by hand and a booklet by hand go straight to the queue at its
  default paper (Windows' Print tab keeps its own options), not through macOS's print panel, which runs one job; a PDF that
  needs a password isn't asked for one there (it's said and left out; Batch asks); no Copy (the Mac's Copy is the ID card's,
  one side); the printer's face is cupsd's copy of the printer's attributes. Not checked: paper on a real one-sided printer,
  face down and up (`--hand-duplex` answers the prompt), the alert on screen, VoiceOver.
- **4.16 Cards, calendars and collages in Photos.** PrintCore `PhotoProjects` (`cards`, `cardBox`, `panel`, `message`,
  `needsTwoSided`, `firstDay`, `dayNames`, `monthName`, `weeks`, `monthAt`, `monthSheet`, `yearSheet`, `monthGrid`,
  `arrangements`, `lines`, `collageCells`, `collages`, `swap`), `SheetLine`, `PhotoText`, `PhotoTextAlign`,
  `CollageArrangement` (`Placement`'s `right`, `bottom`, `centerX`, `isEmpty`, `intersect` as 4.18 added them); `PhotoLayoutKind`'s
  `card`, `monthCalendar`, `yearCalendar`, `collage`, `PhotoLayoutOptions`' `cardMessage`, `calendarYear`, `calendarMonth`,
  `locale`, `collage`, `collageSpacing`, `collageBorder`, `PhotoSheet`'s `lines`, `texts`, `inside`; `PhotoProjectsTests` (PC).
  PrintMac `PhotoSheets.draw` draws a sheet's lines (hairline grey, dashed fold marks) and text (Helvetica, wrapped from the
  top of its box, bold titles, grey day names). The app: Print Photos' Layout gains Folded card (Message inside), Month and
  Year calendar (Year, First month), Collage (Arrangement, Spacing, Border), Save as PDF… for every layout; a card with a
  message is sent with `sides=two-sided-long-edge` only to a queue that says it prints both sides, else one-sided with
  Windows' note (each inside a sheet of its own; `PhotosModel.cardTwoSided`); `--report … --photo-projects`. **Mac differences:** Windows'
  `SheetText` is `PhotoText` (PrintCore's `SheetText` is the separator sheet's); a culture is a `Locale` (the interface
  language's, `AppLanguage.current`, without a region; Foundation's `Calendar` gives the first weekday), a week day .NET's
  `DayOfWeek` number; with no locale the names are English (Windows: the invariant culture's, also English); a month's
  weeks count the proleptic Gregorian calendar's day numbers (`Day.dayNumber`), never a date; `monthAt` clamps the index
  first (Swift's Int is 64-bit, so `Int.max` would overflow where .NET's int fits a long); a collage's photos swap from a
  photo's Swap With menu (Control-click), since dragging moves the crop; a card printed through the print panel (no queue)
  takes the panel's two-sided setting. Not checked: a card printed two-sided and folded, a calendar on A4 in Spanish on
  paper, the controls on screen, VoiceOver.
- **4.18 A PDF preset's PDF/A-2b and password.** PrintCore `PdfArchive` (`PdfWriteOptions`; the XMP packet, its text
  escaped by hand as .NET's XElement writes it; `pdfDate`/`isoDate` in the Gregorian calendar, UTC), `PdfEncryption`
  (AES-256, the standard security handler's revision 6: algorithm 2.B, /U /UE /O /OE /Perms, every string and stream
  encrypted with its own IV, `encryptStrings`, NFKC passwords cut at 127 bytes on a character, `checkNew`) over a
  `PdfCrypto` (SHA-256/384/512, AES-CBC), `IccProfiles` (moved from PdfCore: `srgb()` named for Inkvolt PDF, as it was,
  `srgbForPrint()`), `PdfWriter.write(…options:)` (PDF 1.7 with Adobe's extension level 8 when protected, the output
  intent, metadata and file ID for PDF/A, a CMYK picture refused, PDF/A with a password refused);
  `ScanPreset.pdfA`/`password` (`PdfA`, `Password`, the Windows names), `ScanPresets.savesPdfA`, `savesWithPassword`,
  `withPdfA`/`withPassword` (the last ticked wins), `passwordsToForget`, `writeOptions` (throws rather than save a
  protected preset's PDF open), `isPdf`; `ScanArchiveTests` (PC, 20). PrintMac `ApplePdfCrypto` (CryptoKit's hashes,
  CommonCrypto's AES-CBC; installed at launch with SNMPv3's, `PdfCryptoTests`), `PresetPasswords` (the login keychain by
  preset id, memory in demo mode). The app: the preset editor's Save as PDF/A and Put a password on the
  PDF (a PDF type only, each clearing the other), the password asked the first time the preset saves (typed twice; Use it
  for this preset from now on keeps it in the keychain), forgotten when the preset goes or its option is turned off; such a
  file is always the app's own PDF, never the scanner's as sent, and the status says Saved as PDF/A or It asks for its
  password to open. PdfCoreTests `PrintScanArchiveTests` (Mac, the Windows names): Inkvolt PDF for Mac's PDF/A check passes
  the PDF/A scan, MuPDF opens the protected one only with its password (a Spanish one too) and finds its text, Remove
  Protection takes the password off. `--report … --demo --scan-archive` saves the demo laser's feeder through each preset
  into the container and has PDFKit open the protected one with its password (an ASCII one opens it; "Contraseña 2026"
  doesn't: PDFKit, Preview's engine, takes only ASCII for AES-256, where MuPDF takes any, so the prompt says so once before
  keeping such a password, as Windows' README names its own engine's limit). **Mac differences:** the password is in the
  keychain (Windows: Credential Manager); the preset's Print a copy step opens the protected file with its password through
  PDFKit (Windows' own PDF engine can't open these files); the crypto is the system's behind `PdfCrypto`, the PC's tests a
  stand-in of their own (`TestPdfCrypto`: FIPS 180-4 and 197, a table cipher fast enough that the suite doesn't hold up the
  Mac's timing tests); DatesAreGregorianWhateverTheRegionalCalendar can't switch Foundation's calendar for the process, so
  it checks the dates written don't follow the region. Found here: PdfEngine draws every page of a document opened with its open password white (Inkvolt PDF's own Protect
  output the same, AES-128 or AES-256; owner-only files draw), so AProtectedScanDrawsAsThePlainOne is off ("Open"). Not
  checked: a protected scan in Acrobat, veraPDF on the PDF/A scan, the password sheet on screen (VoiceOver).
- **4.18 Print a PDF's pages per sheet, booklet and poster.** PrintCore `Sheets` (`PrintLayout`, `PrintSetup`, `PrintPlan`,
  `PrintSheet`, `PlacedPage`, `CutMark`, `PrintHandling`, `PrintSizing`, `PagesOrder`: the Windows core's `Core/Sheets`, moved
  there from Inkvolt PDF, ported over `Placement`, which gains `right`, `bottom`, `intersect`, `inflate`), `SheetPrint`,
  `SheetChoice`, `PdfLayout`, `SheetRoute`; `SheetPrintTests` (PC, 14). PrintMac `LibCups.printsBothSides` (the queue's
  `sides-supported`). The app (`SheetPrinting.swift`): Print a PDF's open panel has a Layout row under the file list (one page
  per sheet as before, several pages per sheet with 2 to 16, a booklet, a poster with its size and cut marks); a layout other
  than one page per sheet prints `SheetPrintView` through the print panel: the plan laid out for the panel's paper as it
  changes, each page drawn by PDFKit (vectors, annotations included) into its place, a poster's part clipped to its box, cut
  marks; more than 1000 sheets (counted on Letter or A4 by region) is refused with Windows' words; a booklet on a queue that
  says it prints one side only goes by hand (4.2). `--report … --pdf-layout` prints the sample to PDFs in the container and says where
  PDFKit finds each page's words. **Mac differences:** Inkvolt PDF for Mac's PdfCore keeps its own `PrintLayout` (Windows
  moved Inkvolt PDF's into the shared core), so PrintCore's are nested in `Sheets` (PdfCore imports PrintCore, and two
  `PrintSetup`s at the top level would collide in every file that imports both); `grid` takes a count that isn't a choice
  as 2 (Windows throws); lengths are in DIPs as on Windows and drawn in points (`SheetPrint.pointsPerUnit`); copies and two
  sides are the print panel's (macOS makes the copies, so `SheetPrint.order`'s blank back between copies isn't used); a
  booklet asks the panel for two-sided on the long edge, and a back is drawn half-turned only while the job prints on the
  long edge (on the short edge it needs no turn); pages are vectors, not pictures at `renderDpi`; the layout is picked before the panel (Windows: in
  its Print a PDF view, with a count of the sheets). Not checked: a booklet and a poster on paper (fold, trim), the open
  panel's Layout row on screen (VoiceOver), a printer with no queue picked in the panel for a booklet.
- **4.5 Ready for a printer with no driver.** PrintCore `DriverReadiness` (`assess`: a raster format answered over IPP is
  ready, no answer when asked is not ready, a printer not asked is not known; `mopria-certified`, `mopria-certified-scan` of
  1 to 16 characters; AirPrint when it takes `image/urf`; `isMakerModule`), `DriverReadiness.Readiness` (nested: PrintCore's
  `Readiness` is the Suite's), `PrintReadiness`, `ScanReadiness`, `PrinterView.readiness` (set when a network printer
  connects), `SystemScanner.makerDriver`, `IppClient.statusAttributes` asking for Mopria's two; `DriverReadinessTests` (PC).
  PrintMac `SystemScanners` reads each device's `modulePath`. The app (`PrinterReadiness.swift`): Details' Printer answers
  ("IPP (AirPrint, Mopria certified), eSCL (Mopria certified)") and Driver ("None needed: macOS prints to it driverless", or
  "Its maker's…"), and a warning under them for a scanner only its maker's driver reaches; the demo photo flatbed is on a
  maker's driver, so `--report … --demo` lists the warning. **Mac differences:** Windows' half is about Windows' queue
  drivers (IPP class driver, Microsoft's, a maker's version 3 or 4) and protected print mode; on the Mac CUPS sets up a
  printer that answers IPP driverless (AirPrint, IPP Everywhere) and macOS has no protected print mode, so there is no
  driver kind, no "can move" and no Set up with Windows' driver (Set Up in macOS already makes a driverless queue); a queue
  printer's own driver (a maker's PPD) isn't told apart (CUPS's PPD drivers are deprecated, not gone); a scanner's maker's
  driver is an ImageCaptureCore module outside `/System` (Apple's AirScan is inside), where Windows asks for WIA or TWAIN;
  4.2's output tray isn't asked for yet (two-sided by hand waits on the Mac). Not checked: a Mac with a maker's scanner
  driver installed (the build Mac has no scanner), the lines on screen (VoiceOver).
- **4.10 Share a printer with phones.** PrintCore `PrinterSharing` (`canShare`: not a `file:` or PDF writer's queue, a fax,
  a class, another computer's or a temporary one; `state`: CUPS's `printer-is-shared`), `QueueSharing`;
  `PrinterSharingTests` (PC). PrintMac `SystemSettings.printerSharing` (the Sharing pane at Printer Sharing, research file
  Q7). The app (`PrinterSharingCard.swift`): a queue printer's Share with phones card (shared, not shared, or not said,
  with Open Sharing Settings) and File › Share a Printer with Phones… (how macOS shares printers, which are shared now,
  Open Sharing Settings and Open Printers & Scanners); `--report … --share` gives its text and where its buttons go, each
  queue printer's line its sharing. **Mac differences:** no server of ours: macOS's Printer Sharing shares the queue
  (IPP, Bonjour, AirPrint), so Windows' `PrinterShare`, `SharedPrinter`, `RasterReader`, its mDNS responder and every test
  of PrinterSharingTests.cs but the one ported have no Mac counterpart; nothing is turned on from the app (a switch per
  queue would need cupsd's admin right, and the sandbox runs no server); whether Printer Sharing itself is on isn't read
  (cupsd's `_share_printers`, admin only), so a queue cupsd marks shared is said to be shared "while Printer Sharing is
  on"; the card names iPhones, iPads and other computers (AirPrint), not Android, which Windows' names (not checked with
  macOS's sharing). Not checked: the URL landing on the Printer Sharing row (System Settings was in use on the build Mac),
  a phone printing to a shared queue, the card and the alert on screen (VoiceOver).
- **4.17 Setting up a new printer's Wi-Fi.** PrintCore `SetupNetworks` (`classify`, `find`, `show`, `setupPage` of a dotted
  IPv4 string), `WifiNetwork` (`quality(rssi:)`), `SetupCandidate`, `SetupNetworkKind`, `WifiNow`, `WifiLocationError`,
  `WifiReading`, `SetupStep`, `SetupState`, `SetupText`, `PrinterSetupGuide` (an actor: `look`, `connect`, `returnHome`,
  `checkBack`, `foundPrinter`; `pause` and `onChange` injected), `DemoWifi`; `PrinterSetupTests` (PC). PrintMac `CoreWifi`
  (CoreWLAN: the interface's network name, `scanForNetworks(withSSID: nil)` off the main thread, RSSI as quality, open when
  it supports no security; the gateway from SystemConfiguration's dynamic store for the Wi-Fi interface's service;
  `reportLines`) and `WifiLocation` (CLLocationManager, asked only from the guide). The app: File › Set Up a New Printer's
  Wi-Fi… (`PrinterSetupWindow.swift`: the printers' networks with maker, kind, open or not and signal, Use This Network,
  the steps' words, Open the Printer's Setup Page, Done, Check Again, Add a Printer… and the new printer once found);
  the entitlement `com.apple.security.personal-information.location` (the owner approved it for this), Info.plist's
  `NSLocationUsageDescription` and `NSLocationWhenInUseUsageDescription` (Spanish in InfoPlist.xcstrings),
  `pkg-preflight.sh` expecting both; `--report … --setup-wifi` (demo: each step on the made-up Wi-Fi; else this Mac's
  Wi-Fi as the guide reads it, no names). **Mac differences:** the app joins and leaves no network: the person does it in
  macOS's Wi-Fi menu and the guide waits to see it (up to 3 minutes each way; Windows joins an open network itself and
  goes back by Windows' saved profile), so there is no Connecting step, no temporary profile (`OpenProfile` and its test
  are Windows only) and no disconnect (a Mac that was on no network is told to leave the printer's); CoreWLAN's
  `associate(to:password:)` wasn't tried from the sandbox (on the build Mac it would take the Mac off the network its SSH
  comes over) and Apple documents no sandbox support for it (research file, Q7), so joining in steps is the design, not a
  fallback; `PrinterSetupGuide` is an actor whose call while another runs is ignored and whose wait stops with its task
  (Windows serializes calls on a semaphore and takes a token); closing the window while away (`SetupClosing`, Windows'
  `MayClose`) stops the wait and, since the app can't go back itself, says at once how to (`returnOnClose`): the window
  stays open saying it, and the next Close closes; macOS's location alert gets a minute (then the guide says how to turn
  location on) and the window's Cancel; the menu item is in File (Windows: Add a printer's Set up a
  new printer… and the palette). Seen on the build Mac: with location access not yet asked (no one at the screen), `scanForNetworks(withSSID: nil)` from the sandbox returned 23 networks, none with its name, and the current network's name came back nil, as the sources say; the Wi-Fi gateway was read (a private address); the installed app carries the entitlement and the usage text. Not checked: a new printer's setup network (no new
  printer there), the location prompt and the window on screen (no one was at the build Mac's screen to answer the
  prompt), VoiceOver.

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
  offset). Polling backs off on battery and on a constrained network (macOS's Low Data Mode) rather than Windows' metered one;
  the queue list's polling (queue change notices, above) on battery and in Low Power Mode, and stops while the window is
  closed.
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
  tests time the IPP step alone. Since 2026-11-23's scan items (HalvesJoin, Upright, SeparatorCode, the B/W PDF, phone
  scans) the CPU-heavy suites run off the pool too (`@Suite(.offThePool)`, an operation queue as `offPool`): on CI's 3
  cores they had held all three pool threads for ~150 s, and every timing test beside them failed. InkvoltPdfKit's
  CompareAlignTests too (2026-11-24, sampled on CI: its cases held the three threads 11 minutes, and LtvTests or
  AiLoopbackTests lost one answer a run to a reset, read after the server's side was dropped; the transport now reads
  an answer as it arrives, on the connection's queue, and the loopback server half-closes), and PageCheckTests'
  UnregisteringWaitsForAHandlerCancelIsRunning (2,000 semaphore waits, 740 s on a pool thread).
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
- An IPv6 address typed with its zone (`[fe80::1%25en0]`, `ipp://[fe80::1%25en0]/`; hostile-input review, 2026-11-23,
  where Apple's URLComponents trapped on the `%`) keeps it: the printer's host is `fe80::1%en0`, and its IPP and web
  addresses write it `%25` (`PrinterAddress.urlHost`, which `DeviceHttp` uses too; a host no URL can hold gets the base
  `unusable.invalid`, never a trap). Windows drops the zone (.NET's `Uri.Host`). A zone that isn't RFC 6874's unreserved
  characters is no address. Not checked: connecting to a link-local printer by its zone (the transports' scope, above).
  The same review: Print a PDF's layouts refuse a PDF past `SheetPrint.maxSides` on its page count first
  (`SheetPrint.tooMany(_:pages:)`), then measure its pages once (off the main thread past 200 pages); `{n:D<n>}` pads to
  32 digits at most in both apps (`FileNameTemplate.padsTooWide`, refused by `problem` and `normalize`) and a preset's
  counter goes from Int32.max back to 1; the queue notices subscribe again when cupsd's sequence numbers reach Int32.max; a
  recovery list naming a page twice restores it once (`ScanPages(restoring:)`, `TurnedStack.inPlaces`).
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
| 3.6b | A hostile file's time: page checks (Windows' `PageChecks`, 2026-11-05), in process; inline pictures' filters through MuPDF's patch `inline-image-filter-budget.patch` (2026-11-23) | PageCheckTests |
| 3.5 | Indexed folder search (roadmap 3.5's Mac line): Edit › Find › Search Folders… (⌥⇧⌘F, the command palette) over folders indexed on this Mac | IndexTermsTests, FolderIndexTests, FolderIndexerTests |
| 3.3 | Compare: Office files, scans and formatting (roadmap 3.3's Mac line), on E3's Compare Files | CompareChangesTests, CompareAlignTests, CompareContractTests (and CompareTests, E3's, unchanged) |
| 2.1 | Paragraph text editing (roadmap 2.1's Mac line): Edit Text & Images rewrites a paragraph in its box, characters its font lacks from fonts on this Mac, looks for a selection, text in form XObjects, turned text | ParagraphEditTests, ContentEditorTests, ContentEditFontTests |
| 3.1 | Translate side by side (roadmap 3.1's Mac line): Tools › AI Assistant › Translate with AI…, a translated copy beside its original, through the user's own AI endpoint | TranslationReplyTests, TranslationRunTests, TranslationLooksTests, TranslationMarkupHostileTests, TranslationCopyTests, TranslationLinkTimingTests |
| CB | The command bar (Windows' 1.12 design, docs/design/command-bar.md): the toolbar's groups Edit, Convert, Comment, Fill & Sign, Organize, Protect, Scan & OCR as split items, the icon-only pointer tools, the one-click jobs, the bar's colours | CommandBarLayoutTests (the table), BarColorsTests, ExportTargetTests → `CommandBarTests`, `ExportTargetTests`; ReservedFileNamesTests (PrintCore) |
| W4A | Wave 4's paper commands (roadmap Batch A, "Wave 4: paper commands" below): Page Labels, Interleave Pages and Scan the Backs, Remove Blank Pages and Split at Blank Pages (and their Batch actions), Bookmarks from Headings, Resize Pages, Replace Pages | PageLabelEditTests, InterleaveTests, BlankPagesTests, HeadingBookmarksTests, ResizePagesTests, ReplacePagesTests; BatchAutomationTests' preset round trip |
| 4.20 | Save an AI answer (roadmap 4.20): an answer (its card's Save, Tools › AI Assistant › Save AI Answer…) or the conversation (the pane's Save, Save AI Conversation…) as a Word document through `DocxWriter` or a PDF (opened in a window), or one answer as a note on the page it cites (one undo step); the conversation kept with the document's session (`AiConversation`, `AiExchange`, `AiAnswerExport`, `DocumentSession.aiConversation`; `AiSave.swift`; `--edit --only-ai` drives it) | AiAnswersTests |
| 4.10 | AI redaction suggestions (roadmap 4.10, Pro): Tools › Redact › Suggest Redactions… (Protect on the toolbar), the user's own AI endpoint asked for names, organizations, addresses, account and ID numbers or a description, the send window always shown, the answer read as data and kept only where the text sent holds it; the names and terms list (Edit List…, no AI); both into Redact by Pattern's review list, apply, read-back, check and report, each hit named by where it came from (`RedactionSuggestions`, `RedactionTerms`, `RedactionMatch.label`, `PatternRedaction`'s labelled read-back; `RedactSuggest.swift`; `--edit --only-ai` drives it) | RedactionSuggestionsTests |
| 4.8 | Smaller black-and-white scans (roadmap 4.8): Reduce File Size codes 1-bit pictures again as lossless JBIG2, CCITT G4 or Flate when smaller, and makes grey scans of text black and white when asked (the sheet's and Batch's check box, the preset's `blackAndWhiteScans`); Recognize Text's cleaned page of a black-and-white scan stays 1 bit (PrintCore's `Jbig2Generic`, `PdfWriter.oneBitData`; PdfCore's `OneBitImages`, `Optimizer`, `ScanPage`) | Jbig2RenderTests, OneBitImagesTests |
| 4.18 | Mark All Matches (roadmap 4.18): Edit › Find › Highlight, Underline and Strike Out All Matches, after a search with the Find bar (`SearchMarks`, `MarkMatches.swift`; `--edit --only-text-tools` drives it) | SearchMarksTests |
| 4.15 | Links from Addresses (roadmap 4.15): Tools › Annotate › Links from Addresses…, the addresses listed to untick, the ticked ones made links in one step (`AddressLinks`, `Links.putOnTexts`, `LinkAddresses.swift`) | AddressLinksTests |
| 4.6 | Copy Text from Area and Copy Area as Table (roadmap 4.6): Edit's two commands on the last Snapshot box, or the next one drawn; the snapshot's notice offers Copy text; a box without text read with Vision (`AreaCopy`, `AreaCopyActions.swift`) | AreaCopyTests |
| 4.1 | Spell check where people type (roadmap 4.1): the paragraph editor, notes, text boxes, callouts, replies, the inspector's text, a run of page text and form fields; suggestions, Ignore Spelling, Add to Dictionary; Settings › Check spelling as I type (`SpellChecker` in PdfCore/Text, the app's `SpellCheck`, `SpellingField`, Spelling.swift) | SpellCheckerTests |
| 4.9 | Two documents side by side (roadmap 4.9): AppKit's window tabs (Window › Move Tab to New Window, a tab dragged out or onto another window, Merge All Windows) kept in step with `DocumentWindows` by the app's `WindowHub`: a file open once (in any window, by any spelling of its path, never read twice at once), documents opened join the window used last, File › New Window and the Dock menu's New Window give the next document a window of its own (`--edit --only-windows` drives it) | DocumentWindowsTests |
| 4.16 | The Reflow view (roadmap 4.16): View › Reflow (⌘3), the document's text as one column in place of the pages, Export's HTML in a WKWebView with page scripts off at `Reflow.address`, the look following the view's zoom and Dark Pages, the page kept both ways, links to the browser, read-only but for its commands (`Reflow`, `ReflowPosition`, ReflowView.swift; `--edit --only-reflow` drives it) | ReflowTests |
| 4.2 | Find and Replace across the document (roadmap 4.2): Edit › Find › Find and Replace…, a sheet listing every match with its page and the words around it as it is typed, Replace and Replace All (one undo step, one save, what couldn't be replaced as asked listed) (`TextReplace`, `ContentEditor.paragraphsOf`/`replaceParagraphIn`, ReplaceSheet.swift) | TextReplaceTests (with `ReplacedTextReadsTheSameInPdfJs`, opt-in) |
| 2.2b | Better OCR, the rest (roadmap 2.2's Mac line; Vision only, no Tesseract): photographed pages (PrintCore `Trapezoid`, `CurvedLines`, `ScanCleanup`'s `CleanupSteps`; Recognize Text's two check boxes); Make Text Editable (`EditableText`; Tools › Make Text Editable…, Scan & OCR's bar item); mixed languages (`MixedRecognizer`, Recognize Text's Second language); unsure words (`SuspectReasons.unsure`, `unsureBelow`) | PageWarpTests, EditableTextTests, MixedLanguagesTests |

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
- E15's links (Windows' 722013bb and its reviews dfc3570d, 1445b1c0, 44e875b5, 05074119): `ExportSpan.link`, read in
  `PdfEngine.exportPage` (`ExportLinks.swift`: a character linked when its middle is in a link's /QuadPoints' boxes, from
  `Links.readForExport` through `ExportOptions.source`, or its area when that holds one line; 500 links a page carried,
  64 boxes a link; a space at a link's edge left out), `ExportLink.web` (http, https and mailto through `Links.normalize`,
  then quotes, angle brackets, backslashes, carets, backticks, braces and bars escaped as .NET's `Uri.AbsoluteUri` does; at most 2,048 characters), DocLayout's spaces, tabs and
  joins kept outside a link, HtmlWriter's `<a href rel="noopener noreferrer">` and `#page-N`, PptxWriter's `a:hlinkClick`
  (external hyperlink relationships, slide jumps). Ported: ExportHtmlTests' 11 link tests and ExportPptxTests' 2, with
  Windows' names. ExportCorpusTests allows only such links in the HTML (and counts them); the corpus wasn't run (its PDFs
  aren't on the build Mac). Not checked: a link clicked in PowerPoint for Mac or Keynote.
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
- 4.20: no spoken recording among the choices (Windows' Save AI Answer offers one through 4.24; the Mac's 4.24 is Summary to Audio… only). The
  conversation moved from the window's `AiState` to the session, as on Windows. The PDF's text past WinAnsi (Cyrillic,
  say) is drawn in Type 3 fonts (`TextPainter`), which MuPDF reads back as regular even where drawn bold (it takes bold
  from a FreeType font's style or name only); Latin text uses Helvetica and Helvetica-Bold and reads back bold, so
  `Pdf_HasTheSameText_AndFlowsOntoMorePages` checks bold on a Latin answer. The note's date has a plain space before
  AM/PM (macOS writes a narrow no-break one). Saving over a PDF open in a window is refused, as Windows refuses one open in
  a tab. Not checked by a person: the sheet and the Save buttons by eye and with VoiceOver, the .docx in Word or Pages.
- 4.10: the command is in Tools › Redact beside Redact by Pattern… (Windows: Review › Suggest Redactions…), and on the
  toolbar's Protect. A model's JSON is read by PrintCore's `Json` (comments and trailing commas as Windows'
  `AllowTrailingCommas`, depth 16); its object's members have no order once read, so a list under another name than
  "redact" is the first by name where Windows takes the first written. A bulleted answer is read by hand in one pass
  (Windows: a linear regex with a time limit). The names and terms list is kept in Application Support's `Inkvolt
  PDF/redaction-terms.txt` with LF line ends (Windows: the data folder, CR LF); either is read. The sheet's pages are the
  AI assistant's Pages box ("All", or 1-3, 5) where Windows has its page range. Not checked by a person: the sheet and
  the list's editor by eye and with VoiceOver, a real model's suggestions.
- 4.8: PrintCore's `Jbig2Generic` (ported as is, the same bytes as Windows') sits beside `CcittG4` and `Bilevel`, which
  Inkvolt Print's 4.4 brought, and `PdfWriter.oneBitData(_:jbig2:)` chooses among the three as Windows' `OneBitData`;
  PdfCore uses them, nothing duplicated. MuPDF's objects belong to the document's thread, so `OneBitImages` works in three
  steps where Windows has two: `recodeJob`/`thresholdJob` read a picture on the document's thread, `run` draws and codes
  it (several at once, each in an engine of its own), `apply` makes the change back on the document's thread. File ›
  Scan has no black-and-white mode on the Mac (2.3 above: color or grey only; Print for Mac's 4.4 made a preset's smaller
  file instead), so it saves no page at 1 bit and `ScannedInBlackAndWhiteAPageIsSavedAtOneBitAndInGreyAsItsJpeg` isn't
  ported; Recognize Text and Reduce File Size are as Windows. `Jbig2IsClearlySmallerThanG4OnTextPages` has no "as
  typeset" case (the Mac's corpus has no clean page). Not checked by a person: a real black-and-white scan reduced, the
  sheet's new check box by eye and with VoiceOver.
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
  outlined after it's drawn (Windows outlines it); as there, it and a copy waiting for a box go when another tool is
  chosen or the document changes (`clearSnapshotArea`). Copy Text from Area with no box picks Snapshot and the next box copies words instead of a
  picture. The notice says Numbers, Excel or Pages where Windows says Excel or Word. Not checked by a person: pasting
  into Numbers and Excel for Mac.
- 4.1: the dictionary is `NSSpellChecker` (`MacSpelling`, the closest dictionary the Mac has for the language; Add to
  Dictionary is macOS's Learn Spelling, the self-test's kept for its run only). The app draws the underlines itself (a
  temporary spelling attribute on the editor's layout manager, from `SpellChecker.check`, the editors' own continuous
  checking off) and puts its items at the top of the editor's menu (macOS's own spelling items taken out), so every editor
  follows PdfCore's rules where Windows' plain text boxes use WPF's speller and then drop the words ignored: on the Mac one
  path for all. A text field's field editor is shared by the window, so `SpellingField` clears its underlines when editing
  ends. Ignore is "Ignore Spelling" (macOS's name), for the session in every editor. The document's /Lang is read off
  the main thread once for each version of its bytes, and not at all with spell check off; an editor opened before it is
  in uses the interface's language. `SpellChecker` never holds its lock while it asks the dictionary (NSSpellChecker
  answers on the main thread). The third language tried is the Mac's
  (`Locale.current`) where Windows tries Windows' display language. Not checked by a person: the red underline's look,
  the menu by Control-click and from the keyboard, VoiceOver reading a misspelled word.
- 4.2: matching is Foundation's (`NSString.range(of:options:)`, case-insensitive unless Match case) where Windows uses the
  invariant culture's `CompareInfo`; offsets are UTF-16 as on Windows. `ContentEditor.replaceParagraph` now opens the
  document and calls `replaceParagraphIn` (Replace All's per-paragraph path), as Windows' does. The command has no key
  (Windows: Ctrl+H; ⌘H hides the app, ⌥⌘F is Prepare Form's) and is off while Organize Pages shows. Replace from the sheet
  shows no progress (one paragraph); Replace All shows it page by page with Cancel. `nextAfter` gives nil where Windows'
  gives -1. Not run here: `ReplacedTextReadsTheSameInPdfJs` (INKVOLTPDF_PDFJS, needs Node on the Mac). Not checked by a
  person: the sheet's look, VoiceOver on its list.
- 4.9: a "window" of Windows' rules is a group of AppKit's window tabs, and a tab one document's window. AppKit draws,
  drags, tears off and merges the tabs; `WindowHub` reads its groups (`tabbedWindows`) whenever it asks the rules, so
  `DocumentWindows` follows what AppKit did. A tab carries its window whole (sheets, progress, a running job, the Reflow
  view), so no move is refused as busy: `canMove` and `canTearOff` aren't asked, and `TabDrag` (ported with its tests)
  isn't used, AppKit having its own drag. What is remembered for the next start stays macOS's window restoration
  ("Mac differences"): after Quit it reopens every window with its tabs (unless macOS's "Close windows when quitting an
  application" is on) and a window closed by hand is forgotten, as `remember` does, except the last one (Windows
  remembers its files); `remember` is ported, unused. File › New Window shows the start page and the next document
  opened gets a window of its own (Windows opens an empty window with its own start page); closing the start page
  forgets it. The Dock menu's New Window is the jump list's; `WindowLaunch` (`--new-window`) is ported, unused (files
  reach a running Mac app by Apple Events, not a second launch). A path is compared ignoring case with its links
  followed (`WindowHub.fullPath`), where NSDocumentController compares URLs. Not checked by a person: a tab dragged out
  and onto another window by hand, the tab bar with long names, VoiceOver on the tabs.
- 4.16: the page is put in the WKWebView with `loadHTMLString` at `Reflow.address` (Windows serves it there through
  WebView2's request filter; WebKit keeps https for itself), with page scripts off, a data store nothing outlives,
  pop-ups, link previews, media and the online list of bad sites off; the app's scripts (the page at the top, a scroll,
  the look) run in their own world (`.defaultClient`), sharing only the page's elements. The text size follows the
  view's zoom alone: the Mac has no Text size for apps (Windows' `TextScale`), so `ReflowLook.textScale` is 1. The
  commands that run are `Reflow.runs`' by the Mac's menu actions (`Reflow.runsAction`, `macActions`: those the Mac has,
  with Page Setup, Share and Dark Pages, which are commands here; Show in Folder, Close All, Export Images, Back and
  Forward aren't on the Mac's menus), checked in the window's menu validation and the command bar; Copy and Select All
  are the web view's own. Entering Reflow closes the organizer and the Find bar (as Windows); Organize Pages leaves
  it. A message (preparing, nothing to reflow, couldn't be made) shows in its place with Back to Pages; nothing to
  reflow says Recognize Text where Windows adds Scan & OCR. The column has the PDF's links (E15's, below), followed
  through `follow` (`ExportLink.web`, as Windows). Not checked by a person: the
  column's look in light and dark, VoiceOver reading it, a trackpad's scrolling, a real web link opening the browser.
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
  An inline picture's filters run inside that one parse, reading no byte of the file and never looking at the cookie,
  and the page checks don't see them: `/F [/Fl /Fl /Fl /AHx]` over a few dozen bytes inflated 4 GB of zeros that
  ASCIIHex skips as white space (9 s for a 1 x 1 picture, and Cancel couldn't stop it). Since 2026-11-23 the Mac's
  MuPDF has one patch, `Vendor/mupdf/patches/inline-image-filter-budget.patch` (applied by `build.sh`; the report for
  MuPDF's tracker beside it, `inline-image-filter-budget.md`): what all the filters of one inline picture produce is
  stopped at 8 times its decoded size plus 1 MB, as data cut short (the picture pads, the page draws and reads, in
  10 ms). **Mac difference:** Windows' prebuilt MuPDFCore has no such patch; its check process ends such a page at 10 s.
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
- **Phrase reading** (Windows' bd81b98e, 13e554c7, 93f82ba4, fbd4b21d, 05074119 and 38123b6b): a search round is 256
  pages, cut into chunks of one file's pages (`FolderIndex.chunks`: 32 at most; in a round of fewer files than threads,
  shared among them, 4 at least) for all processors but two (12 at most; the Mac had half, 6 at most). A file's list of
  pages is read once a round, by whichever thread asks first (`PageDirectories`), each page's place from running sums
  (the Mac's reader summed the lengths before it for every page), and a thread reads a file's text 256 KB at a time
  (`Cursor.read(_:_:ahead:)`; the Mac's reader read a megabyte on every miss, and its threads took a file's pages one by
  one). A phrase is told on a plain-ASCII page's bytes (`sideBySideAscii`: the last term found with `memmem` where a word
  starts, the words before it read backwards; nil for anything else, a "-\n" or a term that may be cut, which go to
  `sideBySide`), and a page's run longer than 1,024 units may end in any first term. A phrase with a word longer than a
  term (Windows' 09f2ac7a): a term of 47 units or more may be its word cut (`mayBeCut`; 48, or 47 before a surrogate
  pair, as `sideBySideAscii` already took it), a term between matches its page word cut the same way (`cutToTerm`), and
  a first term that may be cut matches anywhere inside its word (Knuth–Morris–Pratt over UTF-16 units; the Mac had
  taken only 48-unit terms as cut, so a phrase with a 61-unit word cut to 47 before a pair was missed; its `LongWords`
  case is in `A_phrase_with_a_word_longer_than_a_term_is_side_by_side`). FolderIndexTests'
  `The_quick_phrase_reading_agrees_with_the_full_one` (a seeded SplitMix64 for .NET's `Random(7)`),
  `Pages_of_many_files_and_long_pages_read_back_in_order`, `A_big_files_pages_are_shared_among_the_threads_in_chunks`,
  `A_phrase_whose_first_word_ends_a_run_longer_than_is_read_is_still_found`, and `Side_by_side_reads_a_phrase_as_terms`
  with the quick reading. Not measured on the Mac (Windows' bench has no Mac port: `index-make`, `index-run`).
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

Windows' scans at another size or a quarter turn off (0950dc5a) are ported: `PageAlignment.scale`, and `CompareAlign`
tries each quarter turn whose ink box has the old one's proportions on 4-pixel cells, sizes the best at 2 pixels (±5 %,
then ±0.6 %), then finds skew and shift in that frame as before, kept only when the ink agrees better (CompareAlignTests'
`aScanAtAnotherSizeOrAQuarterTurnOffIsLinedUp` with Windows' 7 cases, `whatReallyChangedStillShowsOnAScanAQuarterTurnOff`,
`aScaledAlignmentGoesThereAndBack`; a zero scale stands for .NET's default value). `--only-compare` compares a scan with
the same scan fed sideways.

Windows' scans read with the language's dictionary (0950dc5a's `PageOcr.Recognize`) are ported (2026-11-27):
`PageOcr.compareRecognizer` reads each scanned page through `ScanText` cleaned (straight, upright), no suspect words
marked, nothing written back, with Recognize Text's language's dictionary (`MacSpelling`), which says which way up a page
reads when the cleanup isn't sure: without it, words read upside down pass for words. Before, the Mac's Compare handed
Vision the page as rendered. ScanTextTests' `compareReadsAScanTheWayUpTheLanguagesDictionarySays` (Mac only: Windows has
no test of `PageOcr.Recognize`); `--only-compare` compares a typed page with a scan of it fed upside down, read with
Vision (only the amount changed). Vision alone turned out to read that page the right way up as well (the case passes
with the page handed to it as rendered), so the self-test checks the cleaned reading's words, not the dictionary. Ported with Inkvolt Print's 4.3 (Wave 4, above): the scan cleanup's which-way-up test leaving out a run of ink rows
over 3 times the page's lines' height (`Upright.maxLineRatio`, `minLineRows`; `ScanCleanup` now lives in PrintCore, as on
Windows in the shared core, and PrintCoreTests' `UprightTests` run on the PC), and ScanTextTests'
`aPageWithALargeShadedPictureIsTurnedTheRightWayUp` (the Mac's `ExportTestPdf` already had Windows' picture, 40 × 30 drawn
at 160 × 120 points).

- **That page isn't sure the right way up, or turned 270°, on the Mac** (a known issue in the test, which fails if it
  goes away): it is turned the right way up all four ways, as on Windows. macOS's Arial (the Mac's `ExportTestPdf` embeds
  it; PDFsharp embeds Windows') draws two rows of ink, under the first paragraph's first line and over the second bullet's
  ascenders, at 18 and 16 pixels where Windows' draws 15 (at 100 dpi), just past the 3 % of the fullest row (15.06) that
  keeps a line going: the lines measured with them have 1.39 times more ink above than below (706 to 509; Windows 669 to
  435, 1.54), under the 1.4 that is sure. Turned 90° or 180° the Mac's measure says sure. Not a difference in the cleanup
  (the same code, and the same numbers from the same rows); Windows' result rests on those rows as much (15 against
  15.06). A page the cleanup isn't sure of is read both ways, the dictionary deciding.

**Mac differences.**
- **Office files through E12's converter** (Microsoft's app when installed, else LibreOffice): `Converting.pdfForCompare` runs E12's `OfficeConversion`
  (its precheck, the question for a file from the internet, the converter's own process, time limit and Cancel) behind a
  progress sheet, and nothing is opened. Without either the message says so.
  LibreOffice lays a .docx out a little differently from Word, so an Office file is best compared with a PDF LibreOffice
  made too (or two Office files): against Word's PDF, line breaks and fonts may differ. **Not checked:** a real .docx.
- **Scans read with Vision**, in Recognize Text's language (`SavedOcr.language`), through `PageOcr.compareRecognizer` (each
  page rendered at 300 dpi within 60 million pixels, under the page checks, and cleaned by `ScanText`), one page at a time,
  on this Mac; Compare Without Reading Them stops it (the pages read so far count). A page Vision fails on counts as not
  read, and the summary says how many. The words come back on the page as scanned, each at the page's skew and quarter
  turns (`ScanFrame`), which `CompareScan.pageTextOf` reads along. Without a Mac dictionary for the language
  (`MacSpelling` nil) a page the cleanup isn't sure of is turned over only for clearly more words of three letters or more,
  as Windows without one. Windows rereads the lines its recognizer left out (`MissedLines`, `RereadMissed`); the Mac's
  `ScanText` has no rereading (Recognize Text's difference, above). Windows' recognizer skipping a line
  (`couldBeALostLine`) is kept as the heuristic it is.
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

- The accessibility audit (2026-11-24, `sh mac/tools/ax-audit.sh [pdf|print|both]` on the build Mac; PrintCore `AxAudit`,
  `AxAuditTests`; PrintMac `AxWalk`): Inkvolt PDF's `--ax-audit` walks the windows and every dialog of `--ux-shots`
  (Wave 4's Replace Pages, Remove and Split at Blank Pages, Bookmarks from Headings, Grid Spacing, Scan the Backs, Ask
  Across Folders, Search by Meaning, Edit by Asking and its Steps Proposed, Summary to Audio, the rulers) and Inkvolt Print's
  `--report … --demo --ax-audit` its main window and Wave 4's (print log, camera, phone, Wi-Fi setup, Recent Scans, Join,
  Print Photos, the sharing, turned-stack, hand-duplex and preset-password alerts), in English and Spanish: names,
  pictures, values, raw keys, English in Spanish, controls VoiceOver can't reach, titles, Tab's order (as the Mac's
  keyboard setting is: with Full Keyboard Access off, fields and lists only). Inkvolt PDF's first runs: 61 windows each
  language, fixed the start page's icon and the blank pages' pictures (cells reported though the views were left out),
  the progress sample's English. After the review's walk fix (a loop ends on any stop seen again): 5 findings in English,
  10 in Spanish. Inkvolt Print's (14 windows each language): its first run hung on the turned stack's question (opened
  inside a main-actor Task, its runModal held the main queue; now opened from a run-loop call), then named the alerts'
  fields on their cells (preset password, hand duplex's copies and sides): 15 findings each language. Open, for a person
  with VoiceOver: one toolbar pop-up without a name (an `NSMenuToolbarItem`'s, AppKit's own); Tab never reaching Redact by
  Pattern's two fields, and in Spanish only the page thumbnails and Batch's actions and two fields (a wider layout?);
  Print's SwiftUI sheets (Recent Scans, Join Two Halves, Print Photos) with no title; Tab never reaching the print log's,
  the Wi-Fi setup's and the main window's lists; SwiftUI's hosted buttons, lists and switches the walk sees outside the
  tree (SwiftUI gives VoiceOver its own elements: likely the walk's limit, a person confirms). Not checkable by a machine: whether names read well aloud, VoiceOver's own order inside SwiftUI, the
  announcements as things change, popovers (Insert Text, Turn to Angle), Calculation Order's sheet (needs a form with two
  calculated fields).

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

### Gotcha: MuPDF's key after a wrong password

MuPDF keeps one key per document, and every failed `fz_authenticate_password` overwrites it; `fz_needs_password` itself
tries "". `PdfEngine` asked it again after the password had opened the document (`isEncrypted`), so its main instance read
every stream with a wrong key and drew each page white, while text (its own instance) and Remove Protection worked. In
every release up to 1.12.1, for any file opened with its open password (RC4, AES-128, AES-256, Inkvolt PDF's own Protect
output). **Fixed 2026-11-23 in `MuPDFShim`:** whether a document needs a password is asked once, at open
(`inkv_needs_password` returns that), and a failed try after a good one authenticates the good password again (kept,
zeroed when the document goes), so a wrong guess in `authBits` (Sanitizer, PdfRepair) can't do the same. Tests:
`EncryptedRenderTests` (each method, Protect's output, the engine's sibling, text and saved pictures, the print copy, a
wrong try after the right one); the self-test's Protect step draws page 1 as before, in the window and reopened (`--only-passwords` with `--edit
--synthetic` runs it alone).

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

### Wave 4: paper commands (roadmap Batch A)

Ported from Windows' modules and tests (2026-11-23, on `buildmac`), each command in the Pages menu (and the organizer's
and thumbnails' context menu), one undo step through the edit transaction, a signed file's change appended. PaperTest
(`--edit --only-paper`, on the synthetic text document) runs each edit the way its sheet runs it, checks the document
and undoes it.
- **4.14 Page Labels…** (`PageLabels`, `PageEditor.editLabels`; `PdfStructure.writeRanges` split out of `writeLabels`
  as on Windows). The sheet is an alert with the range, numbering, prefix, first number, "Number the pages after them 1,
  2, 3…" and a live preview; Use Plain Numbers is its third button, shown only when the document has labels (Windows
  disables its button instead). Mac difference, from before: the Mac shows labels in Go to Page only, not in a page box
  or the thumbnails, so What's New says Go to Page takes them.
- **4.3 Interleave Pages…** (Pages menu, the command bar's Organize) **and Scan the Backs…** (File menu, the bar's Scan &
  OCR): `PageEditor.interleaveOrder`, `interleave`, `interleaveWith` (the backs grafted as Insert grafts pages, their
  annotations copied, as the Mac's Insert does where PDFsharp's import brings them). Scan the Backs is the Scan window in
  a backs mode: "Leave out blank pages" off and unavailable (a back left out would put every later back beside the
  wrong front), not remembered as the scan choice, and a preset saved there keeps the remembered choice (Windows'
  review fix); with "Make the text searchable", only the backs are read afterwards (the Mac reads scans after they
  become pages; Windows reads them in its dialog). `AppTest` drives it with the demo scanner. The signed-file test uses
  `IncrSignatureTests.signedForm(twoPages:)`, signed for real, so its status is verified as on Windows.
- **4.4 Remove Blank Pages… and Split at Blank Pages…** (Pages menu, the bar's Organize; Batch's Remove blank pages and
  Split at blank pages, presets `removeBlankPages` and `splitAtBlankPages`, no longer refused): `BlankPages` judges each
  page drawn at 1,100 px by PrintCore's `BlankPage` (the Mac's picture is RGB, so the grey weights are Windows' in RGB
  order); a page out of range is checked before it is drawn (Windows catches the engine's exception; Swift would trap).
  The search runs off the main thread with the progress sheet (Cancel stops it); the found pages are a grid of pictures,
  each with a "Page N" checkbox, in an alert with Delete them / Split the document at them. Batch's Bates numbers that
  continue go on from the pages stamped when blank pages are removed after (`batesPages`, Windows' `BatesPages`). The
  UX review's dialog shots don't open these two (the search comes first).
- **4.5 Bookmarks from Headings…** (Pages menu, by Add Bookmark; the Bookmarks list's context menu, where Windows also has
  a button in its pane): `HeadingBookmarks` over `DocLayout.analyzeForTags`, as Windows. Titles are cut at 200 UTF-16
  units (.NET's `Length`) between characters as shown (Swift's `Character`s are grapheme clusters, so an emoji or a
  letter with its accent is never split). The headings are read off the main thread with the progress sheet; the
  preview is a read-only text view, the levels a pop-up (Windows' choices), Replace them / Keep them and add these after
  when the document has bookmarks. The signed-file test uses `IncrSignatureTests.signedForm(twoPages:)`, so its status
  is verified (modified after signing) as on Windows. PaperTest makes them only if the synthetic document has headings.
- **4.7 Resize Pages…** (Pages menu, the bar's Organize): `PageEditor.resize`, `resizeTransform`, `moveDestination` over
  `forEachDestination` (the walk Replace Pages shares), as on Windows; the content wrapped in a `q … cm … re W n` / `Q`
  pair of streams around the page's own. A box of no size (MediaBox [0 0 0 0], with or without a CropBox) is left as it
  is and the other pages resized, as on Windows. Mac difference: MuPDF reads ±1e308 written out as 0 (and reals past
  about 1e10 wrongly), where PDFsharp reads 1e308, so such a box is skipped as one of no size rather than refused; a
  box past any page that MuPDF does read (±1e17) is refused as on Windows. Moved points are kept within a float's range, the largest number MuPDF writes. The sheet: the six paper
  sizes (A4 first where the system is metric, as Windows), a custom size in inches or millimeters, scale or margins,
  the pages.
- **4.13 Replace Pages…** (Pages menu, the bar's Organize): `PageEditor.replace`, `retargetDestinations` over
  `forEachDestination`; the new pages grafted after the pages they replace and their annotations copied, as the Mac's
  Insert does (PDFsharp's import brings them on Windows), each taking the replaced page's label. The other PDF is
  chosen first (an open panel), then the two ranges.
- Not checked by a person: the sheets by eye and with VoiceOver, the blank pages' picture grid, a real scanner's backs.
  The UX review's dialog shots open Interleave Pages, Resize Pages and Page Labels; the others start with a search or a
  file to choose.

### Wave 4's AI items (roadmap Batch C, Pro)

Ported from Windows' modules and tests (2026-11-23, on `buildmac`), through the Mac's AI client and its send window
(`AiConfirmSheet`, E11's), against stand-in models on loopback in the self-test (`AiLoopbackServer`, as `--only-translate`).
- **4.11 Ask Across Folders** (Edit › Find, after Search Folders; Windows also lists it under Review › AI Assistant):
  PdfCore `FolderAsk` (`build`, `withMeaning`, `citations`, `sentList`, `safeName`, `copyRestricted`, `readFiles`) and
  `FolderIndex.rank` and `pageTexts` (FolderIndexPages.swift), `FolderAskTests` under their names. The window is
  `FolderAskWindowController` (FolderAsk.swift): the indexed folders or chosen PDFs, the question, the answers as the AI
  pane's cards, whose citations of a page sent open that file at the page (`AiAnswerCard`'s `links`: `AiAnswerMarkup.runs`
  takes the citations a caller finds). The send window lists each file and its pages (`AiOutgoing.listing`) and says what
  only goes (`onlyNote`). `--only-folder-ask` (`FolderAskTest`): an index of its own, the assistant off then on, the
  listing, the request (files named within their folder, pages sharing no word left out), the link opening the file,
  chosen PDFs declined, a question sharing no word. Mac differences: paths are "/"-separated as the Mac's index keeps them;
  a file's name cut at 120 UTF-16 units is cut between characters, never inside one (an emoji, a letter and its accent);
  a question over the folders that no page shares a word with says so (Windows says the pages have no text, since the
  index proposed none).
- **4.21 search by meaning** (Search Folders' By meaning and Meaning…, Ask Across Folders' Also find pages by meaning):
  PdfCore `AiEmbeddings` (`requestJson`, `urlFor`, `parse`: one finite vector per text, all one length, or refused),
  `AiClient.embed` (a chat model asked for embeddings said in words), `MeaningIndex` (FolderIndex/MeaningIndex.swift: the
  Windows file byte for byte, `.meaning` beside the folder index; pieces, 8-bit vectors, bounds, a stop keeping whole
  files), `MeaningIndexTests` under their names, `ProFeature.meaningSearch`. The app: FolderMeaning.swift
  (`MeaningSettingsSheet`: on or off and the embedding model, kept in the settings as `MeaningEnabled`, `MeaningModel`;
  `FolderMeaning.search`: what each folder lacks, the send window listing every page before it goes, shown always when
  pages go, then the query), each folder's meaning index held by `FolderSearches.Folder` and deleted with it.
  `--only-meaning` (`MeaningTest`): the settings asked first, the listing, the requests (the model and the texts, no file
  name), the closest page first and opened at its page, a second search sending its words only, Ask Across Folders
  bringing in a page sharing no word, Remove deleting the meaning index. Mac differences: a file's paths are compared as
  written (the Mac's index keeps them so), where Windows ignores case; "busy just now" is a file this user can't read
  (`MeaningIndexTests` makes it so with chmod), macOS having no FileShare.None; a boolean in a vector is refused.
- **4.23 Edit by Asking** (Tools › AI Assistant › Edit by Asking…; Windows has it under Review › AI Assistant): PdfCore
  `AskEdit` (`messages`: the request, the page count and the page in view, no document text; `requestJson` with the six
  tools, not streamed; `parse`: only calls of those tools with values that check out become steps, at most 10, the rest
  said; `afterDelete`; `isNoToolsError`), `AiClient.askEdit`, `AskEditTests` under their names. The app: AskEdit.swift
  (`AskEditRequestSheet`, the send window with the tools in its preview (`AiOutgoing.previewExtra`), `AskEditStepsSheet`
  with each step ticked, the steps run in order through the commands the menus use: `go`, `rotatePages`, `removePages`,
  `addBookmark`, a highlight of every match through `SearchMarks`, Redact by Pattern's marks (`runPatternRedaction`), each
  one undo step). `--only-ask-edit` (`AskEditTest`): the assistant off then on, the send window (the tools, no document
  text), four steps ticked and a fifth tool said, Run (a page turned, a bookmark following the deleted page, the highlight,
  the deletion), four Undos, a model that can't call tools. Mac difference: redaction's step marks the matches as
  Redact by Pattern does on the Mac (marked for review, applied only by Apply Redactions), where Windows opens its review
  list.
- **4.24 a summary read aloud to a file** (Tools › AI Assistant › Summary to Audio…; Windows also reads saved answers
  aloud from Save AI Answer, which the Mac's doesn't offer): PdfCore AiAnswerSpeech.swift (`AiAnswerSpeech.paragraphs`,
  `spoken`; `WavFile.read`, `join`; `WavParts`; the answer's lines from 4.20's `AiAnswerExport.blocks`, `plain`, `note`),
  `AiAnswerSpeechTests` under their names. The summary read is the conversation's last exchange (`DocumentSession.aiConversation`,
  so the model named is the one that answered); the joining, coding and writing run off the main thread, Stop checked
  between paragraphs and on each chunk written, its partial file deleted (Windows' `SaveAsync`). The app: SpeechFile.swift (each
  paragraph through `AVSpeechSynthesizer.write(_:toBufferCallback:)` with Read Aloud's voice and speed, its buffers as
  16-bit samples, joined with 0.35 s between paragraphs, then an M4A (AAC, `AVAudioFile`) or a WAV; the summary first,
  with its send window, as Summarize with AI). `--only-summary-audio` (`SummaryAudioTest`): an M4A and a WAV, each as long
  as the speech. Mac differences: M4A where Windows makes MP3 (macOS has no MP3 encoder; no fallback note is needed);
  the WAV's rate is the voice's own (22,050 Hz for the English voice here, 16,000 Hz for the Spanish one), and the AAC
  encoder picks its own bit rate (a set 64 kbit/s is refused at 16 kHz). A paragraph ends at the synthesizer's empty last
  buffer, not at `didFinish` (which came before the last buffers and cut recordings short), with a watchdog for a voice
  that never sends it (5 s without a buffer, 30 s before the first).
- Not checked by a person: listening to a recording; the windows and the send window's listing by eye and with VoiceOver; a real model (Ollama or
  LM Studio on this Mac), and a real embedding model (nomic-embed-text); Edit by Asking with a real model that calls tools
  (qwen3).

### Wave 4: proofreading, forms and layout (roadmap Batch B and C)

Ported from Windows' modules and tests (2026-11-23, on `buildmac`).
- **4.17 Insert Text… and Replace Text…** (Tools › Annotate, the command bar's Comment, the pages' context menu):
  `Annotations.addInsertText`, `addReplaceText`, `caretAt`, `asListed`, `groupHead`, `replacedCarets`
  (`AnnotationsProofreading.swift`), `AnnotationInfo.grouped`; a group's member deleted takes the whole group
  (`groupHeadIn`), an imported caret gets its chevron from its rectangle, and Summarize Comments lists each mark once by
  what it asks. Insert Text goes at the selection's end or where text was clicked (a click on text, as Windows' last
  click), or where the context menu opened over text (`insertProofTextHere:`, its place on the item, so the menu bar's
  command keeps its own rule); its words are asked in the popover the notes use, with Windows' line saying what they
  become. The Comments list shows a group as its head, a caret by its mark ("Insert text", "Replace text"), and a
  strike-out selected on the page selects its group's row. `TextToolsTest` (`--edit --only-text-tools`) drives both
  from the menu bar, the list's rows, Delete of the strike-out and Undo. Not checked by a person: the popover and the
  blue chevron by eye.
- **4.12 calculated fields and several fields together** (Prepare Form): `FormCalculations` (`CalcKind`, `FieldCalc`;
  .NET's `CalcKind.None` is `notCalculated`, as `.none` would read as an Optional's), `DesignField.calculation` read from
  and written to the field's or its widget's own /AA /C, `FormDesign.calculationOrder`/`setCalculationOrder` (/CO),
  `FormDesignRules.withCalculation`, `calcSources`, `calcIndex`, `movedInOrder`, `aligned`, `sizedAlike`, `spread`,
  three more number formats; `FormDesigner`'s anchor, `toggle`, `selectAll`, a group drag (`.movedAll`) and nudge
  (`flushNudgeAll`), `canDelete`. The panel's Calculate section (text fields and dropdowns: the kind, the fields to tick,
  the notation, Calculation order…), and with several selected the arrange buttons and Delete; Tools › Forms ›
  Calculation Order… (a sheet: the list, Move Up and Move Down, ⌥↑ ⌥↓) and Arrange Fields (eleven commands, on with two
  or three selected). `FormCalculationTests` and the 4.12 half of `Wave4CReviewTests` ported; `PrepareFormTest`
  (`--edit --only-prepare-form`) picks a sum and a notation in the panel, fills, changes the order, then ⌘-clicks, aligns,
  drags and deletes two fields. Mac differences: ⌘-click where Windows has Ctrl+click (the Mac's add-to-selection); the
  menu is under Tools › Forms, where the Mac's Prepare Form lives (Windows: Edit › Forms). The arrangements follow the
  view's turn, as Windows' (`DesignPage.rotation`).
  Not checked by a person: the panel's new rows and the sheet by eye and with VoiceOver.
- **4.19 rulers, guides, a grid and snapping** (View › Rulers ⌥⇧⌘R, Grid ⌥⌘', Guides and Snapping: Snap to Guides, Grid
  and Objects, Grid Spacing…, Ruler Units, Clear Guides): PdfCore `LayoutAids` (ticks, `fromRuler`, the grid),
  `PageGuides` on the `DocumentSession` (never written into the PDF; `keys` and `remap` follow pages through moves and drop
  a page's guides when it is turned, resized, replaced or deleted), `Snapper`, and `FormDesigner`'s `snap` (passed with
  each press and drag, where Windows' designer holds a `SnapFor`) and `snapLines`. The app (`Layout.swift`): the rulers
  are the pages' scroll view's `NSRulerView`s (`PageRuler`, counting from the current page as shown, in the page's
  measuring scale, else the region's unit, unless Ruler Units says), a press on one drags a guide onto a page; the hand
  and select tools (and Prepare Form with no field tool) pick a guide up, and dropping it off its page removes it; the
  grid, the guides and what a press snapped to are drawn on the pages (a split's second pane shows the same guides).
  Snapping, off with ⌥: Prepare Form's fields (drawn, moved, resized), shapes, lines, text boxes and callouts drawn,
  comments moved, stamps, pictures and signatures placed, measuring points. `LayoutAidsTests` and the 4.19 half of
  `Wave4CReviewTests` ported; `LayoutTest` (`--edit --only-layout`) drives the menu, a guide from the ruler, a rectangle
  and a field snapping to it, Snap to Guides off, Grid Spacing…, Ruler Units, a page turned and Clear Guides. Mac
  differences: the keys (⌘R turns pages here, ⌘' switches panes); a guide dragged from a ruler shows as a line where the
  pointer is until it is let go over a page. Not checked by a person: the rulers' look and their labels at every zoom
  and turn, dragging guides by hand, VoiceOver on the rulers.
- **4.22 a picture or paragraph turned to any angle** (Edit Text & Images): PdfCore `ContentEditor.rotateImage`,
  `rotateParagraph` (`ContentEditor+Rotate.swift`: about the middle of its box, one undo step; a paragraph's show
  operators drawn again from a turned text matrix, the text position put back after each, so what follows stays),
  `PageImage.angle`, `ContentTurn` (the handle, a drag's angle, Shift's 15° steps, the box's parsing and format). The
  app: the selected picture's round handle out from its top-right corner (a drag shows the turned outline), the
  paragraph editor's Angle box (Return turns it; a change to the text must be applied first, as Windows), Edit › Turn
  to Angle… (the selected picture, asked in a popover; the open editor's Angle box). The tests of
  `ParagraphEditTests.Rotate.cs` ported (`ParagraphEditTests+Rotate.swift`; the pdf.js one opt-in as the other);
  `ParagraphEditTest` (`--edit --only-paragraph-edit`) turns the paragraph 5° from the Angle box and back through the
  menu. Mac differences: a paragraph has no on-page handle (its editor is a popover over the page, so the Angle box
  turns it), and the Mac's paragraphs have no pictures in their flow yet (Windows' `InlinePicture`), so none turn with
  them. As on Windows, a paragraph turned so far that its box takes in other text (a heading above) can't be edited or
  turned again until Undo takes the turn back. Not checked by a person: the handle and the turned outline by eye, dragging it by hand.

### Better OCR, the rest (roadmap 2.2's Mac line)

The owner's decision (2026-11-27): **no Tesseract on the Mac**. Everything reads with Apple's Vision (`VisionRecognizer`
through `PageOcr` and `ScanText`), no new package. Tesseract's optional download stays Windows-only: Vision reads about
30 languages where Tesseract reads over 100, but Vision skips no line on the OCR corpus (`VisionProbeTests`), so
Windows' `MissedLines` and `ReadOnes` aren't needed either. The download (`TesseractStore`, `TesseractCatalog`,
`TesseractRecognizer`, `Lzma`, `BoundedProcess`) can be ported if Mac users ask for a language Vision lacks: Inkvolt PDF
for Mac is unsandboxed and signed with Developer ID, so it could keep the files in Application Support and run them.

- **Photographed pages** (Windows' `Imaging/PageWarp.cs`, shared): PrintCore's `Trapezoid` (`Homography`, `Perspective`,
  ported for Inkvolt Print's camera, 4.12) gains `Perspective.apply` and `PageWarp.fit`/`eval`; `CurvedLines` and
  `LineCurve` are new (`Imaging/CurvedLines.swift`), so PrintCore builds them on the PC too; `ScanCleanup.clean(…steps:)`
  takes `CleanupSteps` (`.trapezoid`, `.curvedLines`) and returns the `perspective` and `curve` it used, with Windows'
  order (the trapezoid first; a page tilted up to 3° looked at for bent lines as it is, flattened in place of being turned;
  else straightened, then flattened). PdfCore: `RecognizeOptions.trapezoid` and `curvedLines` (`steps`), `ScanFrame`'s
  `perspective` and `curve` (a word mapped back through the warps takes its box's middle lines' length, height and
  slant). The app: Recognize Text's two check boxes under cleaning (on by default, saved, off without cleaning), and
  `AppSettings.ocrOptions()` gives Batch, Scan, export and a watched folder the same choices, as Windows'
  `PageOcr.OptionsAsSet`. PageWarpTests ported with Windows' names (14 tests, 19 cases) over `PhotoCorpus` (Windows'
  ocr-corpus PhotoCorpus.cs, the same seeds; `ScanCorpus.cleanPage` added); `WordsReadOnAStraightenedPhotoLandOnThePhoto`
  without `RereadMissed` (the Mac has none). Limits as Windows': letters squeezed near a spine aren't widened, a page with
  no desk around it has no edges for the trapezoid, two facing pages aren't split.
- **Make Text Editable** (Windows' `EditableText`, `FontMatch`, `ScanLook`): PdfCore's `EditableText` (Ocr/EditableText.swift,
  EditableTextLook.swift), the same planning (words by angle round the circle, `Angles`, then bands and lines; line boxes
  told from word boxes; sizes by width unless the height disagrees; paragraphs by size, step and left edge, made even;
  the family by class, measure, then look; each paragraph's face and ink colour; headings among the short list), the
  same constants and thresholds; `TextLayer.remove` takes the invisible layer out, and its spaces now join words round
  ±180° too. The app: Tools › Make Text Editable… and Scan & OCR's Make Text Editable on the bar (the pages, Keep the scan
  showing behind the text, saved; with no recognized text, Recognize Text offered), one undo step (`MakeEditable.swift`);
  `--only-ocr` makes the stand-in recognizer's words editable and checks Edit Text & Images can edit them. **Mac
  differences:** a glyph's ink is Core Text's glyph box (Windows: HarfBuzz's extents), and the words to compare are drawn
  by Core Graphics one by one at 40 pixels to the em (Windows draws them on one PDF page through MuPDF); the text is
  written in Type 3 fonts from Core Text's outlines, as every Mac edit writes installed fonts (`Type3FontWriter`), under
  paragraph editing's stand-in names (`InkFbE…`), so Edit Text & Images edits them (Windows embeds CIDFontType2
  subsets); the families are Core Text's, a common family's metric twin (Helvetica, Times, Courier) counting as it (Arial,
  Times New Roman, Courier New), and families made for another script (a Bengali, Thai or CJK family, by the languages
  Core Text says it supports) aren't tried: macOS's "Bangla Sangam MN" has Helvetica-like Latin letters and read as
  closer to the Helvetica page than Arial. The notice has no Edit Text button (the Mac's notice bar has only Undo); it
  says how. EditableTextTests ported with Windows' names (10 tests, 11 cases; the speed test's limit is Windows' Debug
  one, 10 s a page, as `swift test` builds for debugging).
- **Mixed languages** (Windows' `MixedRecognizer`, `EitherSpelling`): PdfCore's `MixedRecognizer` reads the page with two
  recognizers (Vision in one language each) and keeps each line from the reading that looks more like real words, the same
  union of lines by place and the same plausibility (dictionary words, else the engine's confidence, garbage a tenth); its
  `language` is both tags ("en-US+es-MX", Windows' `PageRecognizer.Language`), which the text layer now keeps (its first
  line takes "+"), and `MacSpelling.of` answers with both dictionaries (the Suspect Words pane's suggestions too).
  `TextRecognizer.read` gives words with their lines and confidence (`RecognizedWord`, Windows' shared type): Vision's
  own lines, a default that puts a stand-in's words in lines by place. The app: Recognize Text's Second language (None,
  or one of Vision's languages; only with a language chosen, as Vision detecting the language reads one), saved at once
  (Windows saves its languages once installed, `PageOcr.Choose`; Vision needs nothing installed); `SavedOcr.reader()`
  reads with it for Recognize Text, Batch, Scan, export, a watched folder, Compare and Redact by Pattern.
  MixedLanguagesTests: TesseractTests.cs's "two languages" tests with Windows' names (the mixed recognizer's
  `language` names both, adapted; no re-reader), and `wordsWithoutLinesArePutInLinesByPlace` (Mac only).
  `OcrLanguages` (Windows' list of its languages then Tesseract's, and the plan of which engine reads what) has no Mac
  counterpart: Vision's languages are the list.
- **Words the engine was unsure of** (Windows: Tesseract's words under 60, `SuspectReasons.Unsure`): `SuspectReasons.unsure`
  (16, Windows' value, so a layer reviewed on either platform reads the same), `TextRecognizer.unsureBelow` (Windows'
  `SuspectWords.unsureBelow`, 60, by default), `ScanText` marking each word whose confidence is under it, the Suspect
  Words pane's "the recognizer wasn't sure of it". **The threshold, from the corpus:** Vision's confidence is a line's (its
  top candidate's), and at the accurate level with language correction it was 1.0 on every line of the OCR corpus and the
  photographed pages: 6,152 words read right and 63 read wrong, all at 1.0 (`VisionProbeTests.visionConfidenceOnTheCorpus`,
  opt-in, 2026-11-27). No threshold tells those apart, so Vision keeps Windows' 60: it marks the rare line Vision itself
  scores low and nothing on the corpus. For the same reason the Mac still reads the page as scanned to compare (the
  read-differently words): Windows skips that for an engine that scores each word (Tesseract), Vision scores none.
  MixedLanguagesTests' `aWordTheEngineWasUnsureOfIsASuspectAndNothingIsReadAgain` (Windows' name, adapted: the comparison
  stays).
- **The corpus** (Windows' `pdf/tools/ocr-corpus` has no Mac tool; its Mac counterpart is `VisionProbeTests`, opt-in
  `INKVOLTPDF_VISION_PROBE=1`, over the same generated pages). 2026-11-27, Vision cleaned (stage A), word error rate per
  page against Windows' RESULTS.md per file (stage A): en-skew3-light 0.0 / 0.8 % (Windows 1.3 %), en-skew6-noisy 2.0 /
  6.0 % (12.9 %), en-skew10-shaded 0.6 / 1.6 % (3.8 %), es-skew4-noisy 6.0 / 4.8 % (8.0 %), es-skew8-shaded 0.8 / 1.1 %
  (4.3 %), en-turned 0.5 / 2.0 % (3.7 %); no line skipped. Photographed pages (`visionOnThePhotographedPages`, against
  RESULTS-photos.md), stage A → straightened: en-trapezoid 0.3 → 0.0 % (Windows 1.6 → 0.8 %), es-trapezoid 3.0 → 3.0 %
  (0.0 → 0.0 %), en-book 0.2 → 0.2 % (100 → 1.7 %), es-book 0.0 → 0.0 % (99.5 → 1.6 %): Vision reads a book's bent lines
  well unstraightened, where Windows' recognizer read the page upside down; straightening is no worse on any file.
  10-30 s a photo on the build Mac with other jobs running.

## Open decisions

None.

Decided: development builds are signed with an Apple Development certificate of the team's, made through the App Store
Connect API key (`dev-cert.sh`) and kept in `~/Library/Keychains/inkvolt-dev.keychain-db` (its password in `.env.local`,
not in git), so they keep their permissions (Screen Recording, Local Network) between builds. It lasts a year
(`NEW-MAC.md`).

## Open

No Mac since November 2026: these wait for the next one (`NEW-MAC.md`).
- Microsoft Office as E12's converter: off until a person with Microsoft 365 signed in runs its checklist (above).
- Inkvolt Print's printer-data work of 2026-11-20: all on the Mac (the web server on a port of its own since
  2026-11-23); SNMP for WSD queues has no Mac counterpart (macOS has no WSD queues).
- Inkvolt Print: P12's 2.2, 3.1 and 3.3 not started on the Mac (2.1 done 2026-11-27; separator codes, the last code item besides these,
  on the Mac since 2026-11-23: "Inkvolt Print scope"). What fixtures could prove and what needs a device, as of
  2026-11-23:
  - 2.2 Scan from the printer's button. The HP half (`LedmWalkupScan`, `ScanToComputer`, the demo's
    `FakeScanToComputer`; `ScanButtonTests`, 33 tests, about 1,100 lines of .NET with a preset's Scan button setting and a
    background long poll in the app) can be ported from the demo manifest's documents alone, but every walk-up name in it
    is Windows' assumption (`LedmWalkupScan.Names`): no HP all-in-one that lists the interface has been recorded (the
    M234dw's tree lists none), so a port would prove only that it matches an assumption. The ICA half (a scanner's button
    events through ImageCaptureCore, Windows' WIA events) needs a USB scanner with buttons on the build Mac.
  - 2.1 Print straight to the printer: done (P12 above; the M234dw printed a page straight from the build Mac). Left: the
    app's own prints on a real printer, and a queue stopped by a failed filter giving way to it; on screen, the options dialog, the progress
    window and the Print menu's choice.
  - 3.1 Share a scanner on the network: an ICA scanner served over eSCL; needs a USB scanner and a second device to scan
    from.
  - 3.3 The printer's own copier: LEDM's copy start names (`LedmCopy.StartNames`) are an assumption until a recording
    confirms them, as on Windows.
- Speed: the drawing set's first 20 pages and Find miss their targets, as on Windows (`mac/tools/bench/RESULTS.md`).
- Everything listed under "What a person must look at" and each section's "A person must look at" / "Not checked".
