# Inkvolt Print: roadmap

What Inkvolt Print builds to do better than the apps people actually use for the same job: the makers' own (HP app /
HP Smart, Canon IJ Scan Utility, Brother iPrint&Scan, Epson Scan 2 and Document Capture Pro, Xerox Print and Scan
Experience, Lexmark's Print Support App), the operating systems' own (Windows' Printers & scanners and Windows Scan,
macOS's Printers & Scanners and Image Capture), the scanning tools (NAPS2, VueScan), the batch printer (Print Conductor)
and the fleet tools (PRTG's printer sensor, PrinterLogic / Vasion Print, Printix, PaperCut). What exists today:
[README.md](README.md) (the feature table; "Not done / known limits" lists what only real hardware can confirm); the Mac
app: [../mac/docs/PLAN.md](../mac/docs/PLAN.md).

**Principles.** Free (MIT), local only: no account, no cloud service of ours, no telemetry, no driver download unless
the person asks (then only the maker's own, signature checked), no shop links. Read-only toward the printer unless the
person asks for a change, every write confirmed. Every claim is checked: each item has acceptance criteria that a test, a
fixture captured from a real printer, or a check on a real printer can confirm.

**Ranking.** value × fit ÷ effort. Value: how many users miss it and how often reviews and forum threads name it.
Fit: how well it works locally, without a service, on what we already have (LEDM, CDM, IPP, SNMP, eSCL, WIA, the
imaging code, the presets, the alert rules). Effort: S (about a week), M (2-4 weeks), L (more than a month).

**Platforms.** Full parity, as [../pdf/ROADMAP.md](../pdf/ROADMAP.md) decided: an item is done only when it ships on
Windows and on the Mac. Each item names its Mac half; a Windows-only mechanism (WIA, the spooler, the Store package) gets
its Mac equivalent named (ImageCaptureCore, CUPS, the App Store build) or the reason there is none. The .NET code and
its tests are the Mac half's spec. **Every item is built on Windows. The Mac halves still open wait for a new Mac**
(owner, 2026-11-17: no Mac; `docs/HANDOFF.md`).

## Free and Pro

Same model as Inkvolt PDF's (pdf/ROADMAP.md, "Free and Pro"): everything Inkvolt Print does today stays free, and so
does whatever a home or a small office needs to see its printers, scan, copy and print. **Inkvolt Pro** is one
one-time purchase, **$19**, one key for both apps (ECDSA P-256-signed, checked on the PC against the public key in the
app: no server, works offline, survives reinstalling; `pdf/tools/pro-key`, with the gate switched off during launch).
It unlocks the office features below, the ones the fleet and batch tools sell per seat (Print Conductor at
[$149 a user](https://www.g2.com/compare/equitrac-vs-print-conductor-vs-vasion-print-formerly-printerlogic), VueScan
Professional at [$199.95](https://www.hamrick.com/reg.html)). A feature without the licence shows what it would do and
where to get Pro, and never takes away a result already made.

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
| 2.4 Batch print | A list of files or a folder, copies, pages, two-sided, paper, the estimate | A folder printed as it fills, saved lists, command line, the results as CSV |
| 2.5 TWAIN | All of it | |
| 2.6 Fleet page | The page | CSV and JSON, `inkvoltprint status --all`, Fix all |
| 3.1 Share a scanner on the network | All of it (Pro until the owner's decision of 2026-11-22) | |
| 3.2 SNMPv3 | A community per printer | SNMPv3 |
| 3.3 The printer's own copier | All of it | |
| 3.4 Job notifications | All of it | |
| 3.5 Open in Inkvolt PDF on the Mac | All of it | |
| 3.6 Supply levels for USB printers | All of it | |
| 3.7 Spanish interface | All of it | |
| 3.8 Get the driver | All of it | |

The seam (1.6): the key format, its verification, the gate and the store are `ProKeys`, `ProCheck` and `ProKeyFile` in
`InkvoltPrint.Core/Suite`; each app's `Pro.Allows(feature)` (`InkvoltPrint.Core/Pro.cs`, `InkvoltPdf.Core/Pro.cs`) sits
on one `ProCheck` for its product, so both apps ask one check and read one key (`%LOCALAPPDATA%\Inkvolt\pro-key.txt`);
Inkvolt Print's Pro features ask it and nowhere else. **Before the gate is switched on in the Mac App Store copy**, its
Pro features need an in-app purchase as well (guideline 3.1.3(b)) or stay free there; that copy shows no buy button or
price (3.1.1(a)).

## Items

What each is: the README's feature table. What waits for real hardware: the README's "Not done / known limits".

### Wave 1

- **1.1 Supply history, pages per cartridge, days left.** Done, Windows and Mac. Pages left and yield from LEDM, CDM, IPP's
  `printer-supply` and the Printer MIB; CDM lifetime counters wait for a recording of
  `/cdm/deviceUsage/v1/lifetimeCounters` (no published schema). The test: a year of fixture readings with two cartridge
  changes, a wobble at the threshold, a week offline and SNMP's −3 gives the right days left, pages per cartridge and
  change dates, and the chart's data is the stored rows byte for byte.
- **1.2 Record a printer.** Done, Windows and Mac (`inkvoltprint record`, Report a problem's Record this printer). Open:
  the recordings it was built for, at least one Canon, one Epson, one Brother, one SNMP-only laser and one CDM-only HP,
  each dropped into the fixtures with the status, supplies and scan tests the demo fixtures have, so the README's "to try
  on hardware" lists shrink to what no fixture can show.
- **1.3 Scanners that only give PDF.** Done, Windows (eSCL and WIA drivers) and Mac (eSCL).
- **1.4 Alerts that survive the Store package.** Done on Windows (the startup task, WinRT toasts); the Mac has launch at
  login and its notifications.
- **1.5 Firmware watch and "keep my cartridges working".** Done, Windows and Mac.
- **1.6 The Pro key.** Done, Windows and Mac (the key in the app group container both Mac apps claim). Open: the Store
  copies of both Windows apps sharing one key.

### Wave 2

- **2.1 Print straight to the printer (IPP Everywhere, no queue).** Done on Windows: PWG raster, URF or PCLm by Print-Job
  over IPP/IPPS for Print a PDF, Copy, Print photos, batches, the scan presets' print step and job alerts, one route
  decision per printer (`PrintRouter`). Re-check against CUPS's `ippeveprinter` (WSL) with `InkvoltPrint.exe
  --direct-print` (`DevDirectPrint`; `--read-pclm` reads PCLm back with Windows' engine; ippeveprinter drops every
  `pclm-*` attribute, so its PCLm run assumes 600 dpi). Open: the M234dw printing a page from a PC with no queue for it.
  **Mac half waits** (PrintCore would carry the same encoders and plan; today the Mac prints through the CUPS queue).
- **2.2 Scan from the printer's button.** Done on Windows: HP's Scan to Computer over LEDM, and a Windows scanner's
  button events through WIA; off by default. Every walk-up name is an assumption (`LedmWalkupScan.Names`) until an HP
  all-in-one that lists the interface is recorded (the M234dw doesn't). **Mac half waits** (ICA's button events; the HP
  part a port of `LedmWalkupScan` and `ScanToComputer`).
- **2.3 Scan cleanup and a Unicode OCR layer.** Done, Windows and Mac. Word error rates:
  [RESULTS-cleanup.md](../pdf/tools/ocr-corpus/RESULTS-cleanup.md) (`ocr-corpus cleanup`). Known limits: a white sheet
  under a white lid shows no edge and stays whole; a dark lid isn't cropped; pdf.js (and PDFKit) find each word of a
  right-to-left line but not a phrase across two; Cyrillic and Japanese error rates wait for those OCR languages.
- **2.4 Batch print.** Done, Windows and Mac (the CUPS queue). The test: 50 files (PDF, JPEG, PNG, TIFF, a locked PDF
  that asks for its password) print to the demo queue in order with the estimated sheet count, exit codes as Inkvolt
  PDF's (`BatchPrintEndToEndTests`). Open: a physical printer printing a page.
  **Why the app ends its own process on exit** (`App.EndWithoutDllTeardown`): on a Snapdragon PC Qualcomm's Direct3D
  driver (`qcdx11arm64xum.dll`) faulted while DLLs unloaded, after everything had saved, because a static in Windows' PDF
  engine is the last holder of a Direct3D device once its documents are collected (a 40-line WPF program with no Inkvolt
  code crashes 10 of 10 when its `PdfDocument` is dropped and collected). On the command line the crash replaced the exit
  code, which a script may read as not printed. `App.OnExit` ends the process with the exit code once all is saved: 0
  crashes in 63 runs after, against up to 15 of 15 before. It avoids the fault, it doesn't cure the driver; no automated
  test catches it. To check by hand on a Snapdragon PC: `InkvoltPrint.exe --demo --batch --batch-run --snapshot out.png`
  several times, and the exit code.
- **2.5 TWAIN.** Done on Windows (64-bit sources beside WIA; 32-bit-only sources named and declined). Open: a real TWAIN
  manager and source (the development PC, ARM64, has neither). Mac: ICA, not started (the parity check: the same flatbed
  through ICA).
- **2.6 Fleet page, export, command line.** Done, Windows and Mac. The JSON's schema:
  `print/schemas/fleet-status.schema.json`.

### Wave 3

- **3.1 Share a scanner on the network (eSCL).** Done on Windows (free since 2026-11-22, the owner's decision; Kestrel from ASP.NET Core's shared framework, the
  owner's decision, no NuGet package; TCP 9780, HTTPS only, Private networks only). Open: an iPhone scan app, a Mac's Image
  Capture, sane-airscan or another Inkvolt Print over a real network with a real USB scanner behind it (this PC's LAN is
  Public). **Mac half waits** (an ICA scanner shared the same way).
- **3.2 SNMPv3 and a community per printer.** Done on Windows (a community per printer; SNMPv3 with SHA-256/SHA-1/MD5
  and AES-128/192/256/DES; SNMP access… asks the printer first; a refused login is its own state) and on the Mac (the
  community, SNMPv3 with SHA-256 and AES-128, the refused state). Which key extension a maker's agent uses for
  AES-192/256 after MD5 or SHA-1 isn't published: Blumenthal's is tried, then Reeder's once; a real printer confirms it.
  **Mac follow-up waits:** the other protocols need `SnmpCrypto` to give MD5, SHA-1, DES and longer AES keys.
- **3.3 The printer's own copier, copy extras.** Done on Windows. The copier writes only the start, because
  `CopyConfigDyn` holds the panel's walk-up defaults and nothing captured shows when a copy has finished to put them back;
  the start's names (`LedmCopy.StartNames`, `StartValues`) are an assumption until a recording confirms them, so *Through
  this PC* stays the default. **Mac half waits** (PrintCore's copy, the LEDM request and the layout).
- **3.4 Job notifications.** Done, Windows (the spooler, and the printer's own job list when it prints straight) and Mac
  (IPP Get-Jobs over cupsd's socket). Decisions: stuck is told once per episode, again only after real progress, at most
  3 times per job; failed once per job; a resubmitted job (same id, another submit time) is new; only your first job is
  told stuck; jobs don't color the tray icon. **Accepted:** a slow big job on a driver that reports no pages and no growing
  size, with the printer saying Printing, can raise one false "may be stuck" after 15 minutes. **Beware** when testing
  with a temporary queue: with Windows managing the default printer, printing to it and removing it moves the default;
  set it back afterwards.
- **3.5 Open in Inkvolt PDF on the Mac.** Done (`InkvoltPdfApp`: found by bundle identifier, files handed over with
  `NSWorkspace.open`). Open: a person seeing the hand-off.
- **3.6 Supply levels for USB printers.** Done, Windows (route 1: the IPP class driver through `IppPrintDevice`; route 2:
  the maker's driver over bidi) and Mac (route 1; route 2 has no Mac counterpart). Open: an IPP-over-USB printer, and a
  maker's driver that answers bidi.
- **3.7 Spanish interface.** Done, Windows and Mac, What's New in Spanish on both. **Next:** the owner's review of the
  Mac-only wording (`print/docs/SPANISH-REVIEW.md`, "Inkvolt Print for Mac"); the Mac listing's Spanish is the owner's
  call (an es-MX localization in App Store Connect, which `asc-listing.mjs apply` then fills).
- **3.8 Scanners that need their driver, and Get the driver.** Done on Windows for Epson, Canon (asia.canon), HP,
  Brother and PFU (fi and SP); a Store copy only opens the maker's link and watches for the device (policy 10.1.5;
  `print/packaging/README.md`, "Get the driver and the Store"). **Next:** Canon's US and European models (their sites
  refuse programs: a source a program may read), ScanSnap (no driver page); a person to try each maker's installer
  through the app, and the Store copy's link and *Found it*; Windows 10 x64.

### Wave 4 (market check, 2026-11-21)

From a fresh comparison with the HP app, Epson, Canon and Brother's apps, NAPS2, VueScan, PaperCut's free tools and
Windows' own printing and scanning (the owner: "do all of them", 2026-11-21). Windows Ready Print (July 2026) puts new
printers on Windows' IPP class driver, which lacks the makers' extras: 4.2 and 4.5 answer that. Each line says Done when
merged; the Mac halves wait for the new Mac. Free unless it says Pro.

- **Batch A (a pile of paper):**
  - **4.1 Two-sided scanning on a one-sided feeder.** Done on Windows and Mac: fronts, the stack turned over, backs, pages put in
    order, the other order one click away, counts that differ said; a preset option (README, "Two-sided on a one-sided
    feeder"; `TurnedStack`; the Mac's in `mac/docs/PLAN.md`, "Wave 4"). **Next:** a person with a one-sided feeder to try
    both tray kinds, on Windows and on a Mac.
  - **4.3 Pages turned upright on their own.** Done on Windows and Mac: sideways and upside down, only when sure, on by default
    (every corpus page each way round), one Undo step (`PageUpright`; the Mac's in `mac/docs/PLAN.md`, "Wave 4").
    **Next:** real feeder scans, and pages in scripts it leaves alone, on both.
  - **4.4 Small black-and-white PDFs.** Done on Windows and Mac: 1-bit pages as CCITT G4 (or Flate when smaller) from the core's own
    encoder, read back by MuPDF; a "smaller file" choice per preset; a text page 17 to 60 times smaller than its JPEG
    (`CcittG4`, `Bilevel`; on the Mac in PrintCore, PDFKit draws them too: `mac/docs/PLAN.md`, "Wave 4"). **Next:** Inkvolt
    PDF's 4.8 to reuse it, on Windows and Mac.
- **Batch B:**
  - **4.15 Recent scans.** Done on Windows: the last 20 saves from every scanner, Open, Show in folder, Email again, Print, Remove
    from list, kept on this PC only, gone files dropped (README, "Recent scans"; `RecentScans`). **Next:** the Mac half waits.
  - **4.13 Print the clipboard.** Done on Windows: text laid out on pages and printed as a PDF, a picture through Print photos,
    copied files as they are, each with the usual options (README, "Print the clipboard"; `ClipboardPrint`). **Next:** the Mac
    half waits.
  - **4.2 Two-sided printing by hand.** Done on Windows: Print a PDF, Batch and Copy, through the queue or straight to the
    printer; the fronts, a prompt for face down or face up (the printer's answer first, the person's kept) and an odd last sheet,
    the backs in the order that stack feeds them, proven on a model of the paper (README, "Two-sided by hand"; `HandDuplex`).
    Photos prints one side. **Next:** the owner's paper test (`--hand-duplex` on the M234dw: 1, 2, 5 pages, 2 copies of 3, face
    down; Batch with two files) and a one-sided printer; the Mac half waits.
  - **4.5 Ready for Windows' new driver.** Done on Windows and Mac. On Windows: per printer the queue's driver (Windows' IPP class driver,
    Microsoft's, the maker's version 3 or 4), whether it answers IPP and eSCL (and says Mopria), whether it's ready for protected
    print mode, *Set up with Windows' driver* beside the old queue (never removed), and a warning for a WIA- or TWAIN-only
    scanner (README, "Ready for Windows' new driver"; `DriverReadiness`). The M234dw here: IPP class driver, IPP and eSCL,
    ready. On the Mac: a network printer's Details say what it answers (IPP, eSCL, AirPrint, Mopria) and whether it
    needs a maker's driver, and a scanner only its maker's ImageCaptureCore driver reaches is warned about (`DriverReadiness`;
    the Mac's in `mac/docs/PLAN.md`, "Wave 4": no Set up with Windows' driver, macOS sets up IPP printers driverless itself).
    **Next:** the owner to try Set up with Windows' driver on a printer on a maker's driver; a Mac with a maker's scanner
    driver.
- **Batch C:**
  - **4.7 Drop a color, remove punch holes.** Done on Windows and Mac: Clean up's Drop a color (red, green, blue or picked off the page)
    and Remove punch holes, per scan, per preset and per page, proven on generated scans (README, "Scan clean up";
    `ColorDropout`, `PunchHoles`; the Mac's in `mac/docs/PLAN.md`, "Wave 4"). **Next:** real punched sheets from a feeder and a
    flatbed, on both.
  - **4.8 Join two halves.** Done on Windows and Mac: a page's Join with the next page… finds the overlap of two scans of an original
    too big for the glass (either way up, on any side) and joins them into one page; not sure, the second half is placed by hand;
    one Undo step (README, "Join two halves"; `HalvesJoin`; the Mac's in `mac/docs/PLAN.md`, "Wave 4"). **Next:** a real A3
    drawing on a letter or A4 glass, on both.
  - **4.11 Name the file from its contents.** Done on Windows and Mac: a preset's file name can hold `{text-date}`, `{text-title}` and
    `{text-number}`, read from the first page (a date in the usual ways of writing it, in English and Spanish; the heading; an
    invoice, order or receipt number), shown and editable in the review before saving (README, "Scan presets"; `TextFinds`; the
    Mac's in `mac/docs/PLAN.md`, "Wave 4"). **Next:** real invoices and receipts, on both.
  - **4.14 Scan straight to Word or text.** Done on Windows and Mac: preset file types Word document (.docx) and Text (.txt), the
    recognized text as paragraphs (headings in Heading 1), photos as pictures; written in the shared core with the Office parts
    moved there from Inkvolt PDF (README, "Scan presets"; `ScanDocx`, `ScanText`; the Mac's in `mac/docs/PLAN.md`, "Wave 4").
    Word opens them (checked on Windows). **Next:** Word and Pages on the Mac opening one.
  - **4.6 Phone as a scanner.** Done on Windows, with or without a scanner (the sidebar's Scan with your phone, or a Scan tab): a QR code opens a page this PC serves over HTTPS on the private network only while a phone scan is open; the phone's browser takes the photos (no app, no cloud), the first phone to pair is the only one that sends, each photo bounded and checked before it's decoded, made a flat page at the scan's settings or a preset, into the review (README, "Scan with your phone"; `PhoneSession`, `PhotoPage`). Replaces Microsoft Lens. **Next:** the owner's phone on the home Wi-Fi (Android's Chrome past the certificate warning, several pages, Done); an iPhone; the Mac half waits.
  - **4.12 A camera as a scan source.** Done on Windows: Use a camera opens the camera's live picture (Windows.Media.Capture, the largest format that still moves), Capture page takes its latest frame in full as a page, warped flat and sized like a phone's photo, into the review with the settings or a preset (README, "Scan with a camera"; `CameraSession`, `CameraFormats`). A 1080p webcam here opened and streamed. **Next:** a document camera, and a real page captured through the window; the Mac half waits (AVFoundation).
  - **4.18 From Inkvolt PDF into Print's presets and Print a PDF.** Done on Windows and Mac: a PDF preset saves PDF/A-2b or puts a
    password on the PDF (AES-256 as Inkvolt PDF writes it; the password asked once and kept in Credential Manager if wanted,
    never in the presets); Print a PDF's Layout prints several pages per sheet (2, 4, 6, 9, 16), a booklet (saddle-stitch order,
    both sides, by hand on a one-sided printer) or a poster (150 to 400% over overlapping sheets with cut marks). Inkvolt PDF's
    print layouts and sRGB profile moved into the shared core, Inkvolt PDF's behavior unchanged; Print's PDF/A and protected
    scans pass Inkvolt PDF's PDF/A check and open in its PDFsharp and MuPDF (README, "Print a PDF", "Scan presets";
    `SheetPrint`, `PdfArchive`, `PdfEncryption`; the Mac's in `mac/docs/PLAN.md`, "Wave 4": the password kept in the keychain,
    the layout chosen under Print a PDF's file list, macOS's print panel making the copies and the two sides). **Next:** a
    booklet and a poster on paper (the owner's M234dw: fold, trim), on both; a protected scan opened in Acrobat; veraPDF on a
    PDF/A scan.
  - **4.16 Cards, calendars and collages in Photos.** Done on Windows: a folded card (two to a sheet, the photo on the front,
    a typed message inside on the sheet's back, fold and cut marks), a calendar (a month or a year per photo, in the interface
    language's month and day names and first day of the week) and a collage (2 to 9 photos in rows, columns or one large;
    spacing and border; drag one photo onto another to swap), offline, with the usual photo options, and Save as PDF
    (README, "Print photos"; `PhotoProjects`). **Next:** a card printed two-sided and folded, a calendar on A4 in Spanish, on
    paper; the Mac half waits.
  - **4.9 A print log on this PC.** Done on Windows: every job this PC's spooler sees while the app runs (time, queue,
    document, user and PC, pages and copies, color and two-sided when known, printed or cancelled), month totals per printer
    and per person, kept on this PC only (13 months, 10,000 jobs), on by default with a switch and Clear; the view free, the
    CSV Pro (README, "Print log"; `PrintLog`, `PrintLogRecorder`). Checked on this PC with a job to Microsoft Print to PDF.
    **Next:** a person to watch a week of real jobs (a laser, an inkjet, a shared printer) against the printers' own counts;
    the Mac half waits (CUPS keeps a page log of its own).
  - **4.10 Share a USB printer with phones.** Done on Windows, free (the owner, 2026-11-22): a switch per queue printer, off by
    default, private networks only; announced as `_ipp._tcp` with Mopria's and AirPrint's keys, IPP on TCP 9782 (Get-Printer-Attributes,
    Validate-Job, Print-Job with PDF, JPEG, PWG Raster, Apple Raster), printed on the Windows queue (README, "Share a printer with
    phones"; `PrinterShare`, `SharedPrinter`, `RasterReader`). Checked with our own IPP client over the real server on loopback and in
    demo mode. **Next:** an Android phone's default print service and Mopria, a Mac, and an iPhone (AirPrint's `_universal` subtype is
    answered by our own mDNS responder beside Windows', `MdnsSubtype`); IPPS; the Mac half waits
    (macOS shares printers itself).
- **4.17 Setting up a new printer's Wi-Fi out of the box** (the owner's "middle option", 2026-11-22: Windows' Wi-Fi and the
  printer's own page, not each maker's protocol). Done on Windows: the printers' setup and Wi-Fi Direct networks nearby, joined on
  a click (an open one with a temporary profile, a secured one in Windows' own list), the printer's setup page opened, back to the
  network the PC was on (or how, when it can't), and the new printer found there; no Wi-Fi password ever passes through the app
  (README, "Set up a new printer's Wi-Fi"; `PrinterSetupGuide`, `SetupNetworks`). Checked: the list read on this PC; joining only
  on a made-up Wi-Fi. **Next:** a person with a new (or reset) HP, Epson, Canon and Brother printer to go through it, and a PC
  that loses its Wi-Fi profile; the Mac half waits (CoreWLAN needs location access there too).

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
  Firmware); crash recovery for unsaved scans; native ARM64; a native Mac app in the Mac App Store.

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
  departments, not a lean app. 4.9's print log isn't this (the owner's decision, 2026-11-22): a log of one PC's own
  spooler, kept on that PC, that charges, holds and limits nothing.
- **Film scanning with infrared dust removal, IT8 calibration** (VueScan Professional): a niche that needs the
  scanner's infrared channel through a maker driver.
- **Vendor driver bidi and printer extensions** (Canon, Epson and Brother cleaning through their drivers): not a
  uniform interface; the Maintenance card drives what the printer advertises (LEDM, IPP Identify-Printer) and points
  at the panel for the rest.
- **Fax.**
