# Inkvolt Print: roadmap

What Inkvolt Print builds next to do better than the apps people actually use for the same job: the makers' own
(HP app / HP Smart, Canon IJ Scan Utility, Brother iPrint&Scan, Epson Scan 2 and Document Capture Pro, Xerox Print
and Scan Experience, Lexmark's Print Support App), the operating systems' own (Windows' Printers & scanners and
Windows Scan, macOS's Printers & Scanners and Image Capture), the scanning tools (NAPS2, VueScan), the batch printer
(Print Conductor) and the fleet tools (PRTG's printer sensor, PrinterLogic / Vasion Print, Printix, PaperCut).
Written 2026-10-30 from a gap review against those apps and their vendors' current help pages; sources are linked
per item. What exists today: [README.md](README.md) (the feature table, "Not done / known limits"); the Mac app:
[../mac/docs/PLAN.md](../mac/docs/PLAN.md).

**Principles.** Free (MIT), local only: no account, no cloud service of ours, no telemetry, no driver download, no
shop links. Read-only toward the printer unless the person asks for a change, every write confirmed. Every claim is
checked: each item has acceptance criteria that a test, a fixture captured from a real printer, or a check on a real
printer can confirm.

**Ranking.** value × fit ÷ effort. Value: how many users miss it and how often reviews and forum threads name it.
Fit: how well it works locally, without a service, on what we already have (LEDM, CDM, IPP, SNMP, eSCL, WIA, the
imaging code, the presets, the alert rules). Effort: S (about a week), M (2-4 weeks), L (more than a month).

**Platforms.** Full parity, as [../pdf/ROADMAP.md](../pdf/ROADMAP.md) decided on 2026-10-27: an item is done only
when it ships on Windows and on the Mac. The Mac app is at parity with the Windows feature table (PLAN.md, P10), so
each item names its Windows and its Mac half; a Windows-only mechanism (WIA, the spooler, the Store package) gets its
Mac equivalent named (ImageCaptureCore, CUPS, the App Store build) or the reason there is none. One Pro key works on both.

## Free and Pro

Same model as Inkvolt PDF's (pdf/ROADMAP.md, "Free and Pro"): everything Inkvolt Print does today stays free, and so
does whatever a home or a small office needs to see its printers, scan, copy and print. **Inkvolt Pro** is one
one-time purchase, **$19**, one key for both apps (ECDSA P-256-signed, checked on the PC against the public key in the
app: no server, works offline, survives reinstalling; built in Inkvolt PDF on 2026-10-30, `pdf/tools/pro-key`, with the
gate switched off during launch). It unlocks the office features below, the ones the fleet and
batch tools sell per seat (Print Conductor at [$149 a user](https://www.g2.com/compare/equitrac-vs-print-conductor-vs-vasion-print-formerly-printerlogic),
VueScan Professional at [$199.95](https://www.hamrick.com/reg.html)). A feature without the licence shows what it
would do and where to get Pro, and never takes away a result already made.

| Item | Free | Pro |
|---|---|---|
| 1.1 Supply history | The chart, days left, pages per cartridge | CSV export across all printers |
| 1.2 Record a printer | All of it | |
| 1.3 PDF-only scanners | All of it | |
| 1.4 Alerts in the Store package | All of it | |
| 1.5 Firmware watch | All of it (the cartridge promise) | |
| 1.6 The Pro key | | The seam itself |
| 2.1 Print straight to the printer | All of it | |
| 2.2 Scan from the printer's button | All of it | |
| 2.3 Scan cleanup, Unicode OCR | All of it | |
| 2.4 Batch print | A list of files, copies, two-sided, the estimate | Folder drop, saved lists, command line, report |
| 2.5 TWAIN | All of it | |
| 2.6 Fleet page | The page | CSV and JSON, `inkvoltprint status --all`, Fix all |
| 3.1 Share a scanner on the network | | All of it |
| 3.2 SNMPv3 | A community per printer | SNMPv3 |
| 3.3 The printer's own copier | All of it | |
| 3.4 Job notifications | All of it | |
| 3.5 Open in Inkvolt PDF on the Mac | All of it | |

The seam (built with 1.6): the key format, its verification, the gate and the store are `ProKeys`, `ProCheck` and
`ProKeyFile` in `InkvoltPrint.Core/Suite`; each app's `Pro.Allows(feature)` (`InkvoltPrint.Core/Pro.cs`,
`InkvoltPdf.Core/Pro.cs`) sits on one `ProCheck` for its product, so both apps ask one check and read one key
(`%LOCALAPPDATA%\Inkvolt\pro-key.txt`); Inkvolt Print's Pro features ask it and nowhere else.

## Wave 1 (next)

### 1.1 Supply history, pages per cartridge, days left
- **Leader.** HP's app shows the level now and sells Instant Ink on it ([HP](https://www.hp.com/us-en/hp-app/overview.html));
  the history lives in HP's cloud, with the account. PRTG's printer sensor reads levels every poll but doesn't keep
  them ("The SNMP can monitor Toner Levels, BUT it does not record them!"; the special values −1/−2/−3 break its
  graphs: [Paessler](https://helpdesk.paessler.com/en/support/solutions/articles/76000079692-monitoring-pages-printed-per-toner)).
  PaperCut keeps them on its server ([PaperCut](https://www.papercut.com/help/manuals/ng-mf/applicationserver/printer-toner-levels/)).
- **Now.** Levels, states and page counts are read (LEDM, CDM, IPP `marker-*`, SNMP `prtMarkerSuppliesTable`),
  shown and alerted on; nothing is kept.
- **Beat it when:** each reading's levels and page count are kept on the PC (one row a day per supply, beside
  `state.json`, never sent); the supplies card shows a level-over-time chart and, from the last 30 days' slope,
  "about N days left" and "N pages since this cartridge went in" (a level that jumps up is a change of cartridge;
  −1/−2/−3 and no level draw nothing rather than a wrong line); the low-supply notification names the days left.
  Pro: Export… writes one CSV across all printers. Test: a year of fixture readings with two cartridge changes, a
  wobble at the threshold, a week offline and SNMP's −3 gives the right days-left, pages-per-cartridge and change
  dates, and the chart's data is the stored rows byte for byte. Mac: the same store and chart (PrintCore, Swift Charts).
- **Effort** S. Windows and Mac together.

### 1.2 Record a printer (fixtures from real hardware)
- **The gap.** Every brand but HP was "built and tested against fixtures written from the specs, not against real
  devices", and CDM, SNMP-only printers, WIA feeders, Print photos, Maintenance and the fixer's repairs are "untested
  on hardware" (README, "Not done / known limits"). The maker apps have the opposite problem: "Scanner Not Found"
  while printing works ([HP Community](https://h30434.www3.hp.com/t5/Printers-Archive-Read-Only/HP-Smart-Scanning/m-p/8106306)),
  Epson Scan 2 wanting the scanner added by IP by hand, no IPv6-only networks ([Epson](https://www.epson.eu/en_EU/faq/KA-01831)).
- **Build:** `inkvoltprint record <host> <folder>` captures every reply the app reads from a printer (LEDM, CDM, IPP
  as IppText, eSCL capabilities and status, SNMP as snmpwalk; nothing written), scrubbed as Report a problem scrubs
  (serials, UUIDs, addresses, host names out), into a folder `FixtureHandler` and `SnmpAgent` serve unchanged;
  `--scan` keeps one glass and one feeder page. A borrowed printer becomes a test forever; a bug report can carry one.
- **Beat it when:** the repo holds fixtures from at least one Canon, one Epson, one Brother, one SNMP-only laser and
  one CDM-only HP, each with the status, supplies, alerts and scan tests the demo fixtures have, and the README's "to
  try on hardware" lists shrink to what no fixture can show (a jam, a feeder's duplex order). Test: recording the
  M234dw reproduces the `m234dw` fixtures (same parsed reading); a recording with the scrubber's test strings planted
  contains none of them. Mac: the same command in the `--report` runner, reading the fixtures in place.
- **Effort** S-M. Windows and Mac.

### 1.3 Scanners that only give PDF
- **Leader.** Windows Scan takes JPEG, PNG, TIFF and bitmap only ([Microsoft](https://support.microsoft.com/en-ca/help/14088));
  Image Capture takes whatever the scanner offers. Some eSCL scanners offer only PDF from the feeder, and today we
  "say so instead of scanning" (README).
- **Beat it when:** a source that offers PDF and no JPEG is scanned as PDF and its pages rendered to JPEG at the
  requested resolution with the engine already used for Print a PDF (`Windows.Data.Pdf`; PDFKit on the Mac), so
  review, crop, straighten, skip-blank, batch split, OCR and presets work unchanged. Test: the demo inkjet's feeder
  set to PDF-only scans a six-page batch identical, page by page, to its JPEG run (same split, same OCR text).
- **Effort** S. Windows and Mac.

### 1.4 Alerts that survive the Store package
- **Leader.** The maker apps run at sign-in and show notifications with buttons; our Store package can't start with
  Windows (README: "the manifest's `StartupTask` extension, not built or tried yet"), and alerts are tray balloons, one
  at a time. The Mac has launch at login (`SMAppService`) and `UNUserNotification` alerts (PLAN.md).
- **Beat it when:** the Store package offers Start with Windows (`uap5:StartupTask`, off by default,
  `RequestEnableAsync`, the toggle reflecting Windows' own state); alerts are WinRT toasts with Open printer and Pause
  alerts buttons, one per printer, clicks handled in the packaged and the unpackaged copy. Test: `AlertTracker`
  decisions unchanged; the packaged build's smoke run (`packaging/smoke-msix.ps1`) sees the task in Task Manager's
  Startup apps and a `--simulate-alerts` toast whose button opens the printer. Mac: parity check in the release
  checklist.
- **Effort** S. Windows; the Mac has it.

### 1.5 Firmware watch and "keep my cartridges working"
- **Leader.** HP's Dynamic Security: cartridges "using a non-HP chip or modified or non-HP circuitry may not work,
  and those that work today may not work in the future" (HP's page, quoted by
  [Rossmann Group's wiki](https://wiki.rossmanngroup.com/wiki/HP_Dynamic_Security)); the 2025 settlement has HP
  "continue to provide printer users with the option to either install or decline to install firmware updates that
  include Dynamic Security" ([The Register](https://www.theregister.com/2025/03/19/hp_printer_lawsuit_settled/));
  Australia's regulator made HP compensate buyers in 2018 ([ACCC](https://www.accc.gov.au/media-release/hp-to-compensate-printer-customers)).
  Epson pushes firmware through its updater app ([Epson](https://epson.com/support/updating-your-printers-firmware-using-epson-software-updater)).
- **Now.** The version is shown; HP's automatic-update setting is read and written over LEDM, with the Dynamic
  Security explanation (README, Firmware).
- **Beat it when:** every printer's firmware version is kept with the date first seen, and a change shows a notice
  ("Firmware changed from X to Y on date") on the status card and, with alerts on, as a notification; the HP card has
  one button, **Keep my cartridges working**, that sets automatic updates off, reads the setting back and says what it
  did; CDM, IPP and SNMP printers get the printer's web page linked instead. Test: fixture readings with a version
  change produce one notice and one alert, never again for the same change; the LEDM write is byte for byte the
  existing settings write. Mac: the same (the Settings tab has the LEDM firmware mode already).
- **Effort** S. Windows and Mac.

### 1.6 The Pro key
- **Why.** Every Pro item below needs it. Inkvolt PDF has the key format, the check and the window since 2026-10-30
  (`pdf/tools/pro-key`; `products` in the key already names `print`); what was left was moving the check where both
  apps read it.
- **Now (built 2026-10-30, Windows).** The key format and verification (`ProKeys`), the check with the gate
  (`ProCheck`, `Enforced` off while the apps launch) and the key's home (`ProKeyFile`: `%LOCALAPPDATA%\Inkvolt\pro-key.txt`,
  a Store copy's redirected package folder looked in too) live in `InkvoltPrint.Core/Suite`; Inkvolt PDF's `Pro` sits on
  them unchanged for its callers (its 17 ProTests pass as they were), Inkvolt Print has its own `Pro` and `ProFeature`
  (`InkvoltPrint.Core/Pro.cs`: the Pro items below, all allowed while the gate is off) and Help › Inkvolt Pro… with the
  same two copy states; a key's `products` decide which app it licenses, a print-only key is refused by Inkvolt PDF in
  plain words and the other way round. `pdf/tools/pro-key` references the shared library. Tests (`ProTests` in
  `print/tests`, 12): the vector against the built-in key, every changed character refused, a test pair's key passes and
  another pair's fails, the products, the gate, a key installed by one app's check found by the other's, a settings key
  moved into the file, a packaged copy's redirected file, the newest copy winning. Pending on hardware: the Store copies
  of both apps sharing one key (README, "Not done"). Mac: not started.
- **Beat it when:** `Pro` lives in `InkvoltPrint.Core/Suite` (both apps reference it); a key is a short text (name,
  issue date, ECDSA P-256 signature; Inkvolt PDF's format) pasted or opened from a file, checked against the public key in the app, stored per
  user and found by both apps; a wrong or altered key says which; no network call exists in the code path. Test: keys
  signed by a test key pair pass, every bit-flip fails, a key from the other app's install is found. Mac: the same
  check in PrintCore (CryptoKit in PrintMac), the key in the app group container.
- **Effort** S. Windows and Mac.

## Wave 2

### 2.1 Print straight to the printer (IPP Everywhere, no queue)
- **Leader.** Windows is moving to the IPP class driver and protected print mode, where "all non-Mopria-certified
  print drivers will be disabled/deleted" ([Petri](https://petri.com/windows-protected-print-mode/)); the maker apps
  still print through their driver. Today Print a PDF, Print photos and Copy need a Windows (or CUPS) queue, which
  needs an administrator on a managed PC.
- **Beat it when:** a network printer with no queue, or one the person chooses, gets the pages as PWG raster, Apple
  raster (URF) or PCLm, whichever `document-format-supported` lists, rendered by the engine we already use (300 dpi,
  the printer's `media-col-database` sizes and margins), sent with Print-Job over IPP/IPPS, copies, two-sided and
  color mode as IPP attributes, progress and errors from Get-Job-Attributes; the print queue card lists the job; the
  Windows queue stays the default where one exists. Test: CUPS's `ippeveprinter` ("can be used to test client
  software", [CUPS](https://www.cups.org/doc/man-ippeveprinter.html)) accepts a 10-page PDF, a photo sheet and a copy
  in each raster format and the pages it saves match ours; the M234dw (PCLm / PWG / URF, no PDF) prints a page from a
  PC with no queue for it.
- **Effort** M. Windows; Mac the same code in PrintCore (today it prints through the CUPS queue).

### 2.2 Scan from the printer's button
- **Leader.** HP's "Scan to Computer" from the printer's panel "is available for Windows only" and needs HP's
  software ([HP](https://support.hp.com/us-en/document/ish_8903985-8904053-16)); Brother, Epson and Canon do the same
  through their desktop apps. People who removed HP Smart lose the button.
- **Beat it when:** the PC appears on an HP printer's panel under Scan to Computer (the LEDM walk-up scan
  destination interface: registered on connect, kept while the app or its tray icon runs, removed on exit) and
  pressing it runs the chosen scan preset here; a WSD scanner's `ScanAvailableEvent` does the same through WIA, and
  ICA's button events on the Mac; a printer with neither says so on the Scan tab. Test: a fixture printer's
  destination list shows the PC after connect and not after exit; a simulated walk-up event runs the preset and
  saves its file; the FakeWiaSystem's button event does the same. On hardware: an HP all-in-one that lists the
  walk-up interface (the M234dw's `DiscoveryTree.xml` doesn't: one that does, recorded with 1.2).
- **Effort** M. Windows and Mac (the HP part shared; WSD is Windows', ICA's button events the Mac's).

### 2.3 Scan cleanup and a Unicode OCR layer
- **Leader.** Epson Scan 2: Correct Document Skew, Edge Fill, color management ([Epson](https://www.epson.eu/en_EU/faq/KA-01830));
  Canon's Auto scan "detects the item type" ([Canon](https://ij.manual.canon/ij/webmanual/ScanUtility/W/G3010%20series/1.1/EN/SU/su-105.html));
  VueScan restores faded colors and removes dust ([Hamrick](https://www.hamrick.com/)); NAPS2 deskews, crops, adjusts
  brightness and contrast, OCR in over 100 languages ([NAPS2](https://www.naps2.com/)).
- **Now.** Straighten, skip blank pages, crop by hand, OCR through Windows' recognizer (Vision on the Mac) into a
  WinAnsi text layer where "non-Latin scripts degrade to `?`" (README).
- **Beat it when:** per scan and per preset: crop to the paper's edge (the lid level the glass-photos code finds),
  whiten the background and remove specks, descreen printed pictures, restore faded prints' colors, each shown in the
  review with Undo; the OCR layer is a CID font with a ToUnicode map, so Greek, Cyrillic, Arabic and CJK text is found
  by search in Inkvolt PDF, Acrobat and pdf.js. Test: a synthetic corpus (skewed, grey-background, halftoned, faded,
  with Cyrillic and Japanese text) gives a lower word error rate than today on every file after cleanup, and every
  planted non-Latin word is found by pdf.js. Mac: the same filters in `ScanImaging` (Core Image), the layer in `ScanPdf`.
- **Effort** M. Windows and Mac.

### 2.4 Batch print
- **Leader.** Print Conductor: drag-and-drop lists, folders and archives, per-document two-sided and tray, "Single
  print job mode", a print estimation report before printing and a results report after, a command line with saved
  settings and lists ([Print Conductor](https://www.print-conductor.com/features)), $149 a user.
- **Now.** One PDF at a time (drag-and-drop, Open with), pictures through the Photos tab.
- **Beat it when:** Print › Batch takes PDFs and pictures (a folder too), shows the sheet estimate per file and in
  all, per-file copies, range, two-sided and paper, sends them in order through the Windows queue (or 2.1) and lists
  each result; a stopped batch says where. Pro: saved lists, a dropped folder printed as it fills, `inkvoltprint print
  --list file --printer name`, the results as CSV. Test: 50 files (PDF, JPEG, PNG, TIFF, a locked PDF that asks for
  its password) print to the demo queue in order with the estimated sheet count; exit codes match Inkvolt PDF's. Mac:
  the same through the CUPS queue.
- **Effort** S-M. Windows and Mac.

### 2.5 TWAIN
- **Leader.** NAPS2 and VueScan scan through TWAIN as well as WIA ([NAPS2](https://www.naps2.com/)); film and
  older flatbeds often ship a TWAIN driver and no WIA one. The Mac's ICA covers those (TWAIN on macOS is gone).
- **Beat it when:** 64-bit TWAIN sources are listed beside WIA and eSCL scanners (matched to printers by
  `WiaMatch`'s rules), with feeder, duplex, color and resolution from their capabilities, pages into the same Scan
  tab, a hung source contained as a hung WIA driver is; 32-bit-only sources are named and declined. Test: a fake
  source (the FakeWiaSystem's twin) covers capabilities, a feeder run, an empty feeder, cancel, a hang; on hardware,
  a TWAIN-only flatbed scans at each resolution.
- **Effort** M. Windows; the Mac has ICA (parity check: the same flatbed through ICA).

### 2.6 Fleet page, export, command line
- **Leader.** PRTG's SNMP Printer sensor: toner per cartridge, cover, total page count
  ([Paessler](https://www.paessler.com/manuals/prtg/snmp_printer_sensor)); PrinterLogic's email alerts for "running
  out of paper, paper jams, missing trays, low toner" ([Vasion](https://docs.vasion.com/v/Print/SNMP/Alerts.htm));
  Printix "monitors printers" from its cloud ([Printix](https://printix.net/features-printix)). A small office has
  one person who walks over.
- **Now.** Every printer is read, alerted on and listed, one at a time; the offline fixer works on network printers
  only (the queue printers' fixer is in the backlog).
- **Beat it when:** a Fleet page lists every printer's state, each supply's level, page count, firmware and the last
  reading's time, sorted by trouble; the offline fixer runs on queue printers too (paused, Use Printer Offline, stuck
  jobs, without the network steps). Pro: Export CSV, `inkvoltprint status --all --json` for a script or a scheduled
  task, and Fix all (the fixer's safe repairs over every queue, each confirmed). Test: the demo PC's nine entries
  render in the right order; the JSON validates against a schema in the repo and carries no serial numbers or UUIDs
  (the scrubber's test); the queue fixer's diagnosis order in Core tests. Mac: the same page and JSON from `--report`.
- **Effort** S. Windows and Mac.

## Wave 3

### 3.1 Share a scanner on the network (eSCL)
- **Leader.** NAPS2 shares a scanner "over ESCL" so Image Capture, Mopria Scan and SANE-AirScan clients can use it,
  only while NAPS2 runs, over HTTPS with a self-signed certificate ([NAPS2](https://www.naps2.com/doc/scanner-sharing)).
- **Beat it when:** a WIA, TWAIN or ICA scanner (a USB flatbed, an all-in-one with no network scanning) is published
  as an eSCL scanner (`_uscans` over DNS-SD) from the tray icon, certificate fingerprint shown, off by default, private
  networks only; an iPhone, Image Capture and another Inkvolt Print scan from it with the driver's capabilities. Test:
  our own eSCL client scans a page through the shared endpoint identical to the direct scan. Mac: an ICA scanner
  shared the same way.
- **Effort** M. Windows and Mac. Pro.

### 3.2 SNMPv3 and a community per printer
- **Leader.** PrinterLogic reads v1/v2 by default and supports v3 per printer ([Vasion](https://docs.vasion.com/v/Print/SNMP/Alerts.htm));
  offices that turned `public` off get nothing from us (README: "for one added by address there is no setting yet";
  "SNMPv3 isn't spoken").
- **Beat it when:** Add a printer and the printer's menu take a community (kept in Credential Manager / the
  Keychain, never in `state.json`); Pro: SNMPv3 authPriv (SHA-256, AES-128) with USM discovery, still read only.
  Test: v3 messages written by hand from RFC 3414 / RFC 3826 in the BER tests; the made-up agent refuses a wrong
  key; on hardware, a printer with `public` disabled is read.
- **Effort** M. Windows and Mac (PrintCore's SNMP is the same code).

### 3.3 The printer's own copier, copy extras
- **Leader.** Brother's app has "copy preview" ([Brother](https://www.brother-usa.com/apps/printing-scanning/brother-iprint-scan-desktop));
  every all-in-one copies on its own, but ours "uses the PC: the printer's own copy function (LEDM `CopyConfig`)
  isn't driven" (README).
- **Beat it when:** an HP printer whose tree lists `CopyConfigCap` / `CopyConfigDyn` (the M234dw's does) copies on
  the printer, no queue needed; the PC path stays for the rest and gains 2-up and 4-up, collate and a preview. Test:
  the LEDM copy document byte for byte against a recording fake; layout tests; on the M234dw, one copy from the app.
- **Effort** S-M. Windows and Mac.

### 3.4 Job notifications
- **Leader.** The maker apps and the fleet tools tell you a job failed; Windows and macOS put a queue icon up.
- **Beat it when:** with alerts on, your own job's failure or stuck state (no progress for 5 minutes while the
  printer is ready) is one notification per job, naming the document and the printer, with Open the queue; off by
  default. Test: `AlertTracker` rules on the demo queue's made-up jobs; the demo fixer's stuck job raises one. Mac:
  CUPS job states through `QueueJobs`.
- **Effort** S. Windows and Mac.

### 3.5 Open in Inkvolt PDF on the Mac
- **Why.** "Not on the Mac: Open in Inkvolt PDF (no Mac Inkvolt PDF yet)" (PLAN.md); on Windows the hand-off is why
  the two apps install together.
- **Beat it when:** the Mac app finds Inkvolt PDF by bundle identifier and hands a saved PDF over through its URL
  scheme, with the same two switches as Windows. Test: the `--report` runner with a stub app registered for the scheme.
- **Effort** S. Mac (Windows has it); after Inkvolt PDF's Mac 1.0.

## Where we already win

Kept up with the same rule: a claim here has a test or a source.
- **No account, no promotions, no telemetry.** HP's app: "signing in with an HP account is required to access full
  functionality"; HP+ "requires an HP account, ongoing connection to the internet" and Original HP ink for the
  printer's life ([HP](https://www.hp.com/us-en/hp-app/overview.html)); its App Store label lists Purchases, Contact
  Info, Identifiers and Usage Data as data "used to track you" ([App Store](https://apps.apple.com/us/app/hp-smart-formerly-hp-all-in-one-printer-remote/id469284907));
  HP's setup had a data-collection screen on by default
  ([Robert Heaton](https://robertheaton.com/2019/09/15/hp-printers-send-data-on-what-you-print-back-to-hp/)). Brother's
  app has "Buy Brother Genuine Ink & Toner" built in ([Brother](https://www.brother-usa.com/apps/printing-scanning/brother-iprint-scan-desktop)).
  Ours: nothing leaves the PC (Report a problem is copied by hand, scrubbed; `Diagnostics` tests), alerts link
  nowhere, and the Mac App Store label is "Data Not Collected" (PLAN.md, P11).
- **No driver, no bloat, any brand.** Windows auto-installed HP Smart on PCs with no HP printer
  ([The Register](https://www.theregister.com/2023/11/30/windows_hp_software_uninvited/)); HP clean-up removes it and
  blocks the re-install (README). Set up in Windows pairs the IPP class driver queue, where Windows itself is going
  with protected print mode ([Petri](https://petri.com/windows-protected-print-mode/)). Canon, Epson, Brother and
  SNMP-only printers show status and supplies where Windows' Printers & scanners shows none for the class driver and
  macOS's Supply Levels tab goes blank on AirPrint queues ([Apple Community](https://discussions.apple.com/thread/1377138)).
- **A scanner that isn't "lost".** Identity before data: the printer is known by UUID, followed to a new address and
  never confused with the device that took its old one (`PrinterSession`, `PrinterId` tests; GLOSSARY), where HP's and
  Epson's forums answer "Scanner Not Found" with reinstalls and typed IPs
  ([HP Community](https://h30434.www3.hp.com/t5/Printers-Archive-Read-Only/HP-Smart-Scanning/m-p/8106306),
  [Epson](https://www.epson.eu/en_EU/faq/KA-01831)); a hung WIA driver holds up only its own scanner (README, WIA).
- **The offline fixer.** HP Print and Scan Doctor fixes "printer offline status, print jobs stuck in the queue" for HP
  printers on Windows ([HP](https://support.hp.com/us-en/help/printscandoctor-printing-problems)); ours diagnoses
  and repairs any brand's queue, port and spooler, each step shown, each repair confirmed (`Core/Offline` tests, the
  demo PC), and on the Mac re-points and resumes CUPS queues (PLAN.md, P9).
- **Batch scanning without the business suite.** Patch-code and blank-page separation and per-file naming are what
  Epson sells in Document Capture Pro ([Epson](https://www.epson.eu/en_EU/verticals/business-scanner-range/document-management)),
  tested on generated scans (`PatchCodes`, `BatchSplit`); several photos on the glass cut out straight
  (`PhotoFinder`), which Image Capture does and Windows Scan doesn't.
- **Scan to a cloud folder without the cloud.** Presets save into the OneDrive or Dropbox folder found on the PC and
  email through the installed mail app, no API or account (`SyncFolders`, `MailRoute`), where Brother's scan to
  Google Drive, Dropbox or OneDrive "requires Internet connection and an account with the desired service"
  ([Brother](https://www.brother.com.ph/en/solutions/scan-to-cloud-service-brother-iprint-and-scan-desktop)).
- **Dynamic Security explained, in the app**, next to the switch that turns automatic firmware updates off (README,
  Firmware); crash recovery for unsaved scans; native ARM64; a native Mac app with the same feature table.

## Not doing, and why

- **Remote printing, mobile fax, cloud scan destinations by API** (HP's Mobile Fax, Brother's and Canon's cloud
  uploads): they need an account with a service, ours or theirs. A synced folder on the PC does the job.
- **Ordering supplies, Instant Ink-style plans, shop links:** against the principles; the supplies card names the
  cartridge number and stops there.
- **Installing firmware from the app:** a failed install can brick a printer and HP's updates carry Dynamic
  Security; the printer's own page or the maker's updater does it, after 1.5's notice.
- **Email or SMS alerts through a server of ours** (PRTG, PrinterLogic): notifications stay on the PC; 2.6's JSON lets
  a script send what it likes.
- **Print release, quotas, accounting, driver deployment** (PaperCut, Printix, PrinterLogic): server products for IT
  departments, not a lean app.
- **Film scanning with infrared dust removal, IT8 calibration** (VueScan Professional): a niche that needs the
  scanner's infrared channel through a maker driver.
- **Vendor driver bidi and printer extensions** (Canon, Epson and Brother cleaning through their drivers): not a
  uniform interface; the Maintenance card drives what the printer advertises (LEDM, IPP Identify-Printer) and points
  at the panel for the rest.
- **Fax.**
