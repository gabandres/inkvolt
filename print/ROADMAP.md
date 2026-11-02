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
- **Now (built 2026-10-30, Windows).** Each reading's levels, states and the lifetime page count are kept on the PC
  (`Core/History/SupplyHistoryStore`: one tab-separated file per printer under the data folder's `history\`, one row a day
  per supply, about three years, 16 supplies and 64 printers at most, no identifiers, removed with the printer); the
  supplies card shows "About N days left · N pages since this cartridge went in" per supply and the last year's level
  chart (`Views/SupplyChartView`, the stored rows as they are), "not enough history" states with the days still needed,
  and the low-supply notification names the days left. The method is documented on `SupplyAnalysis` and in the README
  (a jump of 20 points is a change; least squares by calendar day over this cartridge's last 30 days; "more than two
  years" past 730 days). Pro: Export history… writes one CSV across all printers through `Pro.Allows`
  (`SupplyHistoryCsv`, formula-safe cells). Demo mode makes up a year per printer, so `--demo --snapshot` shows the
  chart. Tests: `SupplyHistoryTests` and `SupplyHistoryCsvTests` (the year with two changes, the wobble, the week
  offline and SNMP's −3; the chart's points equal to the stored rows byte for byte; bounds, damaged files, restart round
  trip; the CSV; the alert's wording; the demo year). Pages per cartridge need a lifetime count: LEDM only for now (CDM,
  IPP and SNMP counters not read). **Pending on hardware:** a cartridge change seen live on an LEDM, IPP and SNMP printer
  (README, "Not done"). Mac: PrintCore done (2026-11-02, mac/docs/PLAN.md P12: the store, the analysis, the chart's data,
  the card's lines, the alert's days left, the CSV behind Pro, the demo year; SupplyHistoryTests on the PC); the store's folder
  and the monitor feeding it, the Swift Charts chart, Export history… and demo mode's seeding wait for the Mac.
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
- **Now (built 2026-10-30, Windows).** `inkvoltprint record <address> <folder>` in the developer CLI (`--scan`, `--community`,
  `--escl` / `--ipp` hints, `--force`): `Core/Recording/PrinterRecorder` opens the printer through a recording handler that lets
  GETs and IPP Get-Printer-Attributes through and refuses anything else, drives the app's own readers (probe, reading, UUID
  check, LEDM documents by type and the firmware manifest, CDM's five, the maintenance probe, eSCL status) and walks SNMP's
  system, Host Resources device / printer and Printer MIB subtrees, then writes every reply under its fixture name
  (`IppText.FromResponse` for IPP, `SnmpAgent.FormatWalk` for SNMP) with `recording.tsv` (each request's milliseconds, status,
  file). `FixtureScrubber` replaces identifiers with stand-ins of the same shape, consistent across documents (serials, UUIDs,
  IPv4/IPv6, MAC, host names, e-mail, this PC's user and computer names; typed names, locations, contacts, users, jobs, SSIDs
  become words), so identity checks still agree on replay. Tests: `RecordingTests` (9: the M234dw, the demo inkjet, the CDM
  laser and the SNMP-only laser recorded through the fixture transport and served again read the same, interfaces, model,
  firmware, scanner, IPP attributes and reading; a recording sends only GETs and Get-Printer-Attributes; identifiers planted in
  LEDM, eSCL, IPP and SNMP replies, as Report a problem's tests use them, none left in any file, and the recording still one
  printer; versions, masks, models kept; `IppText` and the walk read back what they write). **Report a problem (built 2026-11-01):** the dialog
  has Record this printer, for the printer shown: `Core/Recording/ReportRecording` runs the same `PrinterRecorder`, so the same scrubbing and the same
  read-only rules, never scanned pages, into a new folder named by the clock (`Documents\Inkvolt Print recordings`) plus a .zip of it to attach; the details
  to copy get one scrubbed line (model, interfaces, the file's name); a failure's message is scrubbed; closing the window stops it and a failed or
  stopped recording leaves nothing. Fixed on the way, for the command too: a reply is kept only under a plain name of a fixture's kind (`PrinterRecorder.KeptName`),
  since a printer's discovery tree decides what gets asked for and "/C:/x" would have left the folder, and "/run.bat" would have put a script in it. Tests: `ReportRecordingTests`
  (the planted identifiers absent from every file, the .zip and the copied line; the demo printer; no scanning; nothing left after a failure or a cancel). Seen with
  `--demo --dialog report --record`: the zip made from the made-up printer, and on the demo office laser "Nothing answered at [ip]". **Not checked:** on a real printer; Show the file
  (not offered in demo mode). **Pending on hardware:** the five recordings the item asks for. Mac (2026-11-02): PrintCore's `PrinterRecorder` and `FixtureScrubber` with RecordingTests ported, on the Windows PC; the command in the `--report` runner over real sockets, and Report a Problem's recording, wait for the Mac (mac/docs/PLAN.md P12).
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
- **Now (built 2026-10-30, Windows).** `EsclClient` asks a source that offers PDF and no JPEG for `application/pdf` and hands
  each document's pages over as JPEG (`Core/Escl/ScannerPdf`): a page that is one DCT picture is taken out byte for byte (no
  re-encoding: the page a JPEG scan gives), anything else is drawn at the scan's resolution by `Windows.Data.Pdf`
  (`Windows/Printing/ScannedPdfPages`, set at start-up in the app and the CLI); one PDF per page or one per run. Each page
  remembers its PDF, so a PDF save of untouched pages, all of them in order, writes the scanner's own PDF (`KeepAsSent`), else
  it is made from the pages and the status line says why (`WhyNotAsSent`); the scan's status line says the scanner sent PDF.
  Demo mode: the inkjet's feeder offers PDF only, so `--demo --printer 2 --source feeder --split blank --scan --snapshot`
  shows the batch split, straightened and the note. `FixtureHandler` answers a PDF job with a PDF (the JPEGs embedded as they
  are; a feeder batch in one). `inkvoltprint scanpdf <file>` shows what the Scan tab gets from a PDF. Tests: `ScannerPdfTests`
  (13: the PDF-only feeder's six pages byte for byte its JPEG run, so the split, straightening, crop and OCR are the same; the
  settings ask PDF at the resolution; JPEG still asked where offered; a PDF-only glass; neither format said in words; pictures
  taken out byte for byte, a hand-written page tree with inherited resources and indirect lengths; turned pages, other
  encodings, masks and non-PDFs left to the renderer; rendering, no renderer and a failing one; keeping the scanner's PDF and
  when not). Pending: a real PDF-only scanner; WIA devices that offer PDF only. Mac: PrintCore done (2026-11-02,
  mac/docs/PLAN.md P12: the eSCL request, taking pages out, keeping the scanner's PDF, ScannerPdfTests on the PC); PrintMac's
  PDFKit renderer, the Scan tab's status line and save, and demo mode's PDF-only feeder wait for the Mac.
- **Effort** S. Windows and Mac.

### 1.4 Alerts that survive the Store package
- **Leader.** The maker apps run at sign-in and show notifications with buttons; our Store package can't start with
  Windows (README: "the manifest's `StartupTask` extension, not built or tried yet"), and alerts are tray balloons, one
  at a time. The Mac has launch at login (`SMAppService`) and `UNUserNotification` alerts (PLAN.md).
- **Now (built 2026-10-30, Windows).** The manifest template declares the startup task (`InkvoltPrintTray`, `Enabled="false"`);
  Settings › Notification area and alerts offers Start with Windows in the Store package too (`StartupTask.GetAsync`,
  `RequestEnableAsync`, `Disable`; the checkbox shows Windows' state and its note names Task Manager or a policy), and the
  app started by the task reads the StartupTask activation as `--background`. Alerts are WinRT toasts (`Core/Alerts/AlertToasts`
  writes the XML, `App/Tray/ToastAlerts` sends it): one per printer with Open printer and Pause alerts (one hour) buttons,
  tag and group so a newer alert replaces the showing one, clicks handled through the toast's Activated event in the packaged
  and the unpackaged copy (the latter under an AppUserModelId registered in HKCU with the app's name and icon, removed by
  `--unregister`), a toast clicked after the packaged app exited reopening it on that printer; balloons stay as the fallback
  (dev builds from bin\, demo mode unpackaged). Tests: `AlertToastTests` (the XML, escaping, grouping, arguments, tag, the
  manifest's task) and `ShellRegistrationTests` (the identity's removal); `AlertTracker`'s decisions are untouched (AlertTests
  as they were). **Pending on hardware:** the packaged smoke run seeing the task in Task Manager's Startup apps and a
  `--simulate-alerts` toast whose button opens the printer (README, "Not done"). Mac: the parity check in the release checklist.
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
- **Now (built 2026-10-30, Windows).** Every printer's firmware version is kept in `state.json` with the day first seen
  (`Core/History/FirmwareWatch`); a new version shows "Firmware changed from X to Y on date" on the status card (Firmware
  settings for an HP printer Inkvolt Print writes to, the printer's web page for CDM, IPP and SNMP printers, Dismiss; gone
  after 30 days) and, with alerts on, one notification (`AlertKind.FirmwareChanged` through `AlertTracker`: never told
  twice for one change, restarts included; it never colors the tray icon). The HP Firmware card has **Keep my cartridges
  working**: confirmed, automatic updates written Off (`Core/Ledm/CartridgeGuard`, the card's own write), read back, and
  what the printer kept said in plain words. Tests: `FirmwareWatchTests` (15: the record, the notice's life, the M234dw's
  fixture readings with a version change giving one notice and one alert and none after a restart, the tray level; the
  button's PUT equal byte for byte to the Firmware card's Off write, already off, read-only, a printer that keeps
  installing, the password step; all against captured documents in memory, no printer written to). **Pending on
  hardware:** a real update noticed, and the button on a printer set to install automatically (README, "Not done").
  Mac: PrintCore done (2026-11-02, mac/docs/PLAN.md P12: FirmwareWatch, the FirmwareChanged alert, CartridgeGuard,
  FirmwareWatchTests on the PC); the record in the state file, the status card's notice and the Firmware card's button
  wait for the Mac (the Settings tab has the LEDM firmware mode already).
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
  of both apps sharing one key (README, "Not done"). Mac: PrintCore done (2026-11-02, mac/docs/PLAN.md P12: format, gate,
  shared key file, 12 ProTests on the PC); PrintMac's CryptoKit verifier, the group container and Help › Inkvolt Pro… wait for the Mac.
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
- **Now (built 2026-10-31, Windows).** Per scan (Scan settings › Clean up) and per preset (`ScanPreset.Cleanup`, all off
  by default, free as the table says), and per page in the review's Clean up view (`--clean n`: the page large, Show as
  scanned to compare, All pages, Done is one step of Undo, as is a whole scan's clean up; the page's note names what was
  done; a page's filters are in its `PageEdits`, kept by crash recovery): **Crop to the paper** (`PaperEdge`, the lid's level
  along the scan's edges, in the straightened page, into the same `Crop` as a hand crop: it only ever removes lid, refused
  when anything but dust lies outside a solid rectangle, faint marks and a line of tiny letters included), **Whiten the
  background** (`PageBackground`, its own white point from the scan's noise; faint thin strokes kept; pictures and dark pages
  left), **Descreen printed pictures** (`Descreen`, blocks that repeat at a short period across and down; other pixels byte for
  byte), **Restore faded colors** (`FadedColors`; a scan of photos gets this and Descreen, per photo). Filters run off the UI
  thread on a copy; a preview cancels when a newer choice comes, a save has Cancel, a page over 300 million pixels is left as
  scanned and says so. `ScanCleanup` (Recognize Text, Compare) only gained cancel tokens: the ocr-corpus's rates are the
  same to the digit as its committed RESULTS.md, so that file wasn't rewritten. The OCR layer is a CID font with /ToUnicode (`OcrFont`, `OcrText`): one
  embedded glyph that paints nothing, one code per letter with its marks, surrogate pairs in one code, composed, broken
  characters out, right-to-left words in visual order; a Text language choice per scan and preset when more than one OCR
  language is installed. **Measured** (`ocr-corpus cleanup`, [RESULTS-cleanup.md](../pdf/tools/ocr-corpus/RESULTS-cleanup.md),
  today → cleaned, this PC's en-US and es-MX): skewed on a lid 5.9 → 5.7 %, grey 20.2 → 19.7 and 20.6 → 18.8, halftoned
  10.0 → 4.6 and 8.0 → 2.3, faded 4.9 → 3.4 and **2.7 → 3.0 (not lower, two words)**, so the roadmap's "every file" isn't met
  on that one. Tests: `PageCleanupTests`, `OcrLayerTests`, `OcrLayerSearchTests` (19 planted words in Greek, Cyrillic, Arabic,
  Hebrew, Japanese, Chinese, Korean, Devanagari, Thai and beyond the first plane, found by Inkvolt PDF's search and pdf.js; the
  layer draws nothing; survives a save through PDFsharp), `CleanupCorpusTests`; `ocr-corpus layer` goes the whole way with
  Latin text (a cleaned page's JPEG, Windows' recognizer, this writer, every word read found again by MuPDF). veraPDF's PDF/A-2b font rules (6.2.11) pass; the
  file isn't PDF/A otherwise. **Not checked:** Acrobat isn't installed here; Cyrillic and Japanese error rates couldn't run
  (no such OCR languages installed, none added: their words were planted, and their corpus files wait in the tool), so what Windows' recognizer gives
  for those scripts' word boxes is unseen; no scanner was used, only synthetic pages and the demo; Undo in the review was
  checked by snapshot, not a test (the view models have no test project). **Known limits:** a white sheet under a white lid
  shows no edge and stays whole, and a dark lid isn't cropped; pdf.js finds each word of a right-to-left line but not a phrase across two (it drops the
  space); MuPDF finds a word mixing right-to-left letters and digits only in parts; Inkvolt PDF's Scan dialog ignores a
  preset's clean up. Mac: not started, on hold since 2026-10-31.
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
- **Now (built 2026-10-31, Windows; the Mac is on hold since that day).** **Print › Batch** (`ViewModels/BatchPrintViewModel`, `Views/BatchPrintView`; the palette; a folder or several PDFs dropped on the window) takes PDFs and pictures or a folder, in Explorer's name order; each file has its copies, pages, side and paper, and shows its pages and sheets, the batch its sheets in all. It sends them in order, a job per file, through `IBatchQueue`: `WindowsBatchQueue` on the XPS path of Print a PDF, `DemoBatchQueue` in demo mode, and the seam 2.1 will implement. Each result is listed, and a stopped batch says where ("Stopped at file 7 of 50 (report.pdf): Paper jam. 6 sent, 44 not sent."). Pro, through `Pro.Allows(ProFeature.BatchPrintAutomation)`: saved lists (`BatchPrintList`), a folder printed as it fills (`BatchPrintFolder`, on `Suite/DropFolder`, now shared with Inkvolt PDF's watched folder, one lock file for both), `inkvoltprint print --list file --printer name` in the app itself (`BatchPrintCommandLine`; exit codes 0, 1, 2, 3 as Inkvolt PDF's), results as CSV (`BatchPrintCsv`). Range and paper per file are free, as this item's first sentence asks. **Checked:** `BatchPrintTests` with a fake engine and queue on real temporary files: a file that changes or vanishes between estimate and print, held against writing while it prints; a half-written, growing or cut-off file in a folder not printed early, nothing printed twice after a restart, a crash's leftover going to `failed`; a wrong password stopping at three tries; list paths (devices, streams, web addresses, leaving the folder, another computer); formula cells; a wrong range, paper or side never changed quietly; a driver's ticket that doesn't keep what was asked; a job over its estimate stopping the batch; hangs in the engine and the spooler; Stop; resuming sending nothing twice. `BatchPrintEndToEndTests` runs the built app's command line on real files through Windows' real PDF engine and WIC with every page drawn: 50 files (PDF, JPEG, PNG, TIFF, a locked PDF with its password) reach the demo queue in order with the estimated sheets; no password, a wrong one, damaged and disguised files, a picture claiming 40,000 × 40,000 pixels. By hand with the dev aid: snapshots (wide, 1024 × 700, stopped), the accessibility audit (no findings), and in the window resuming after a jam, Stop and a saved list reopened. On this PC, read only: an unknown printer, Print to PDF refused, a dry run against a real queue. **On real Windows queues (2026-11-02, no printer involved):** three temporary queues on local file ports, with no elevation, removed afterwards: the inbox Microsoft Print To PDF, HP LaserJet Mono PCLmS Class and Microsoft PWG Raster Class drivers. `WindowsBatchQueue.SendAsync` spooled through the command line (the class drivers; Print To PDF is refused there, exit 2) and through `BatchPrintViewModel` (all but PWG, by a temporary dev aid that wasn't committed). Each job was held, let through alone and its file read: every test page carries a mark, decoded from the rendered output. Against a same-page render of the source the mean grey difference is 0.17 to 0.24 of 255, against the wrong page 1.56. Right on all of these: a mixed folder (PDFs, JPEG, PNG, a landscape PDF turned to fit) in name order, a job per file with the file's name; copies, collated (`1,3,1,3,1,3`); ranges; A4 on a Letter default (PCLm's ticket says `iso_a4_210x297mm`, the page is 8.27 × 11.69 in); two-sided (`two-sided-long-edge`, backs in place, blank back after an odd last page, sheets as estimated) once the test queue's `Config:DuplexUnit` was on; a list with its own settings per file, its CSV; 30 PDFs, 120 pages, 0 of 30 wrong; a name in Spanish and Japanese; RC4 and AES-128 locks with the password; `--watch --once` moving the sent files to `done`. Refused with nothing sent: no password or a wrong one, a corrupt, empty or disguised file (the rest of the batch prints, exit 1), a paper or range the file or queue hasn't got, two-sided on the PWG queue, and two-sided where the driver lists it but its validated ticket drops it (the class driver with no duplex unit: "wouldn't print this two-sided", exit 1). Exit codes seen: 0, 1, 2 (no such queue, Print to PDF, `--max-sheets`, nothing to print), 3 (Ctrl+C after the first file: 1 job in the queue, 4 not sent; a queue set offline: none). Stop in the view model after two files: 2 jobs, then Print again sent the other two and nothing twice. A paused queue isn't a problem to the batch: it takes the jobs. **Bugs this found, fixed:** with its output piped the app had no console, so Ctrl+C never reached it and it printed on behind the prompt (`Ctrl_C_stops_a_run_whose_output_is_piped`); an AES-256 PDF, Acrobat's usual lock, which Windows' engine can't open with any password (0x80048040), said "may be damaged", and Print a PDF's message was empty (`A_lock_windows_cant_open_says_so_and_isnt_called_damaged`). **As they are, not bugs:** `--pages 3,1` prints 1 then 3, since `PageRange` sorts, as its summary says. Printing to a queue moves Windows' managed default printer to it, as any app's job does: the app doesn't touch it. **The Qualcomm crash, explained:** 21 access violations in the log on 2026-10-31, all `qcdx11arm64xum.dll` 31.0.133.1 at +0x1614e8. Stack from a small debugger (no dumps were kept by Windows): the main thread, every other thread gone, `LdrShutdownProcess`, `Windows.Data.Pdf.dll`'s C runtime exit table, `d3d11.dll`, the driver; no Inkvolt frame. A static in Windows' PDF engine holds a Direct3D device; once its documents are collected, that static is the last holder, so the device is destroyed while the DLLs unload, and that faults (sometimes as a fail-fast, 0xC0000409, from the same stack; on the command line, that one only). It's not WPF's GPU rendering (it is off), a bitmap or window, or MuPDF (Print doesn't use it): a 40-line WPF program with no Inkvolt code crashes 10 of 10 when its `PdfDocument` is dropped and collected, 0 of 5 when the program keeps it. The trigger in the app is a garbage collection after a batch; the snapshot's large bitmap very likely caused one (inferred: not measured on its own), hence "some runs": 7 of 16 with the sample batch, 15 of 15 with one PDF, none with no snapshot and no collection (0 of 8). Normal close of the window after a batch with a forced collection: 8 of 8. So it reaches users who print PDFs and close the app later. **Harm:** after everything had saved and closed; no WerFault window on this PC (watched on one crash, Windows' error settings at their defaults); the process stays about 6 s for the report, and a crash goes into Windows' log and reports. On the command line it replaced the exit code (3 of 25 with a forced collection, 0 of 8 on 30 PDFs without), which a script may read as not printed and send again. **Fix:** `App.OnExit` ends the process (`TerminateProcess`, with the exit code) once all is saved, before DLLs unload. After: 0 of 15 (one PDF), 0 of 15 (sample batch), 0 of 8 (close with collection), 0 of 25 (command line). It avoids the fault, it doesn't cure the driver. No automated test catches this one: it needs Qualcomm's driver, and a test with a small GC budget didn't fail without the fix. To check by hand on a Snapdragon PC: `InkvoltPrint.exe --demo --batch --batch-run --snapshot out.png` several times, and the exit code. **Not checked** (README, "Not done"): **a physical printer still hasn't printed a page**: no paper, no real device's answers, no jam; drivers here wrote files only, and the IPP class driver this PC's real printers use wasn't among them. Inkvolt Print's Print a PDF and other jobs weren't spooled in this run. Two-sided needs the driver saying it has the unit, as it was set on the test queue. A damaged PDF in `--watch --once` stays in the folder and isn't reported, with exit 0, as a file possibly still being written (10 minutes to `failed`): a call to make. A native crash in Windows' PDF engine isn't contained (no worker process in Print, only timeouts). The file dialogs, drag-and-drop and watching a folder from the window; the over-100-sheets and network questions; a screen reader; HEIC and WebP; the Store alias. Mac: not started.
- **Beat it when:** Print › Batch takes PDFs and pictures (a folder too), shows the sheet estimate per file and in
  all, per-file copies, range, two-sided and paper, sends them in order through the Windows queue (or 2.1) and lists
  each result; a stopped batch says where. Pro: saved lists, a dropped folder printed as it fills, `inkvoltprint print
  --list file --printer name`, the results as CSV. Test: 50 files (PDF, JPEG, PNG, TIFF, a locked PDF that asks for
  its password) print to the demo queue in order with the estimated sheet count; exit codes match Inkvolt PDF's. Mac:
  the same through the CUPS queue. Mac's PrintCore done (2026-11-02, mac/docs/PLAN.md P12: the estimate and bounds, passwords, the run
  and its stops, the printer's answer checked, a folder's files, the results CSV); saved lists, watched folders, `print --list`,
  PrintMac's PDFKit pages and CUPS queue and the Batch window wait.
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
- **Now (built 2026-10-31, Windows).** The sidebar's **Fleet** button (also the palette) shows `Views/FleetView`: every entry of the
  printer list, most trouble first (`Core/Fleet/FleetOrder`: error, warning, can't be reached, not known yet, fine, as the tray ranks
  them, then by name), each with its state and problems, each supply's level, page count, firmware and last reading. It reads no
  printer: each printer's own loop keeps its view model current and the page looks at them every 2 s, so a printer that hangs holds
  up only that loop; for one that hasn't answered, the supply history gives its last levels, day and count, marked last known. Every
  string a printer writes is cleaned and bounded once (`FleetText`, `FleetPrinter.Of`: no control or invisible characters, no bidi
  overrides, no half surrogates, 240 characters, 16 supplies and problems). The offline fixer runs on queue printers
  (`OfflineDiagnosis`, `OfflineDevice.ForQueue`): spooler, that queue by its exact name, its state; no network step or port repair;
  a read that doesn't answer in 10 s says so instead of calling the queue gone; a printer shared from another PC gets steps, never a
  UAC prompt. Resume and Use Printer Offline now ask first on every printer's fixer. Pro, through `Pro.Allows`: **Export…** (CSV, a row
  per supply, formula-safe cells in `Suite/CsvCell`, which the supply history export now uses too; or JSON), `inkvoltprint status --all
  [--json] [--out file]` in the app itself, since the developer CLI isn't packaged (`Core/Fleet/FleetCommand`, `FleetReader`: read only, a
  printer gets 30 s, eight at a time, exit codes as Inkvolt PDF's), and **Fix all** (`FleetFixAll`: resume and Use Printer Offline over
  every queue known to be a printer's, each confirmed by name, the queue read again after the yes). Exports go through
  `Diagnostics.Scrub` and hold no address, serial number or UUID field (`print/schemas/fleet-status.schema.json`). Tests: `QueueFixerTests`
  (the diagnosis order, no network step, no other queue, gone against unreadable, a hung read, the shared printer),
  `FleetTests` and `FleetReadTests` (the demo PC's nine entries in order, read through the real readers over the fixtures; the JSON against the
  schema with a small checker, as no package is added; what the scrubber's test plants in LEDM, IPP and SNMP replies out of the JSON and CSV;
  formula starts including fullwidth and hidden ones; hung, throwing and vanishing printers; another device at the address; Fix all's
  questions, a queue renamed or fixed while one was open, refusals, the gate). Seen: `--demo --fleet --snapshot` (light, dark, 900 wide, Text size 150%),
  `--fleet fix`, `--printer 6 --fix`, `--a11y-audit` (no findings); `--demo status --all --json` and `--pro-enforce` (exit 2, nothing on standard
  output); `status --all` on the development PC, whose one printer was away, in 7 s with `state.json` unchanged. **Not checked:** any real
  printer or real queue repair (paused, Use Printer Offline, a printer shared from a PC that's off, access denied); the Pro window opening
  from the page with the gate on; the Save dialog (the snapshot aid writes the file directly); Excel opening the CSV; a screen reader, and Tab
  through the rows by hand; a Store package's alias, and the command printing to a console it attaches to (piped and to a file ran). Fix all leaves stuck jobs, ports and the spooler to each printer's fixer. Mac: PrintCore done
  (2026-11-02, mac/docs/PLAN.md P12: the entries, the order, the page's words, the CSV and JSON against the schema, `status --all`,
  and `Diagnostics.scrub`, which they need); the reader over CUPS and the readers, the page, Export… and Fix all wait for the Mac.
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
- **Now (built 2026-11-01, Windows).** Settings › Notification area and alerts has "Tell me when my own print job fails or gets
  stuck", off by default. With it on, the tray reads each printer's Windows queue every minute, window open or not (`WindowsJobQueue`,
  winspool: a local call; a queue that can't be read is skipped, never taken as empty), and `AlertTracker.ObserveJobs` decides.
  **Failed:** the job has Error, Blocked or Needs attention for a minute, whatever the printer says; out of paper or offline alone is the
  printer's state and its own alerts tell that. **Stuck:** your first job in the queue, nothing in the queue moving, the queue neither paused nor
  on Use Printer Offline, and the printer's own read, taken after the wait: 5 minutes with it saying it's ready, idle or asleep, or 15 minutes with
  it saying it's printing, worded "hasn't moved for 15 minutes and may be stuck". The times and the cap are in one place, `AlertRules`. Moving (`JobProgress`,
  from JOB_INFO_2) means pages printed, pages or bytes spooled or the job's stage going past the furthest seen, someone restarting it, or a job
  leaving (someone else's too), so a job waiting its turn isn't stuck, and flicker neither passes for progress nor hides a hung job. **Your own:** the job's owner is the Windows user, and if
  it names a domain or a PC, this one; when in doubt it isn't yours. A toast for each job (Open the queue, Pause alerts), naming the
  document and the printer, more than three at once from one printer sharing one; Open the queue scrolls to the queue card. Quiet hours,
  a pause and alerts off work as for other alerts. Free, as the table says: no Pro check.
- **Decisions.** Stuck is told once per episode: told again only after real progress since the last alert, at most 3 times per job. Failed is told once
  per job, also after it was told stuck; a stuck alert after a failure needs real progress too. An alert a pause swallowed ends the episode without using up the cap. All of it
  survives a restart and alerts being turned off and on. A resubmitted job is a new job: a job is its id plus the moment it was submitted, so an id the spooler uses again
  is new too. Only your first job is told stuck: those behind it wait for it, and get their own wait when it's gone. Jobs don't color the tray icon, which
  shows printers. A failure on a paused queue or a printer that isn't ready is still told; only "stuck" asks that the printer be ready or printing.
  **Accepted:** a slow big job on a driver that reports no pages and no growing size, with a printer saying Printing, or someone else's such job ahead of yours, can raise one false "may be stuck" after 15 minutes.
  The name: controls, invisible and right-to-left override characters and broken pairs out, a path or address cut to the file's name, 48
  characters at most, in quotes, so it can't pass for the app's own words. It's kept in memory only: `state.json` holds `Job|id|time|failed told|stuck told|pages, size and stage when last told`, the log the alert's kind.
- **Checked.** `JobAlertTests` on a fake clock, on the demo queue's made-up jobs (`DemoFleet.CardJobs`) and the demo fixer's stuck job
  (`DemoFleet.OfficeStuckJob`, on a Use Printer Offline queue and an unreachable printer: raises one). Seen: `--demo --tray --simulate-jobs
  --tray-shot alert` (two toasts from their XML), `--dialog settings` (the checkbox, off), `--open-queue 1` (the card scrolled into view), and
  `--demo --tray --simulate-jobs` showing the real balloons, with only `JobFailed` in the log. `WindowsJobQueue.Read` read this PC's
  Microsoft Print to PDF queue (empty, not paused). In demo mode Open the queue shows the card's one made-up queue, not the fixer's, as the card always has.
  **One real spooler run (2026-11-01):** a temporary queue (Microsoft Print To PDF driver, no elevation needed) on a TCP port at 192.0.2.1, a 23-byte job, read through `WindowsJobQueue` and the
  rule. The real reads: None, then Printing | Retained about 30 s later, then Error | Printing | Retained at about 90 s and steady for the 10 minutes watched, with the queue's own status going to error (0x2); pages 0 of 1,
  size 23 throughout, `pStatus` empty, `Time` a fixed number, so no moving signal there. Owner `gabri` and machine `\\THISPC` matched `JobOwner`. **It found a bug:** Retained counted as finished, so
  that failed job raised nothing and the card would have said Printed; fixed, and the second run raised one `JobFailed` a minute after first seen, and no stuck alert for the job waiting behind it. Queue and port removed afterwards and confirmed gone.
  **Beware repeating it:** this PC has Windows managing the default printer, so printing to the test queue and removing it moved the default to another queue; it was set back by hand. Set it back after any such run.
- **Not checked.** One real failure was seen (above), on a dead TCP port only. No real printer here, so no real jam, no real shared queue, and neither stuck rule has fired from a real spooler: the
  dead port went to Error, not to a long Printing or a long wait on a ready printer, so the 5 and 15 minute rules are tested on a fake clock only. Also unproven: what `pMachineName` and the owner look like on a shared queue (an owner written as an e-mail address, or a PC
  given as an IP address, counts as someone else's, so such a job stays silent); which status bits Windows really sets on a jam; a job that fails and vanishes between two reads (never seen).
  WinRT toasts: the XML is tested, the toast itself not run here, as for 1.4. A printer with two Windows queues: only the one the app finds is read. Mac: not started.
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
