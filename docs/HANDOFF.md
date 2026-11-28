# Handoff

What a next session needs: where things stand, what's open, what waits. Older entries are in git history;
the Mac machines and where the keys are backed up: `mac/docs/NEW-MAC.md`; what the Mac still lacks: `mac/docs/PLAN.md`, "Open".

## Current state

- **Mac/Windows parity, 2026-11-27/28 (the owner: "on par 100%"; full permission to publish both).** An audit of every
  Windows feature against the Mac apps found 22 gaps PLAN never listed (and 7 the other way); all ported, reviewed and
  merged: Print for Mac's direct printing everywhere with routing (a macOS queue stopped by a failed filter gives way; a
  paused one keeps its jobs), scan button, the printer's copier, Copy, scanner sharing, Open With and drops, presets
  outside the Scan tab, Help, ⌘K palette, rating request, alert buttons, USB driver readiness and Get the driver; PDF for
  Mac's Compare dictionary reading, OCR without Tesseract (the owner's decision: Vision only; photographed pages, Make
  Text Editable, two languages), Translate's looks and right-to-left, paragraph editing's mixed runs, kerning, pictures in
  the flow and Crop, Export Pages as Images, XPS/EPUB/CBZ/FB2 opened as a PDF, Convert to Word from Finder and
  --convert-to, Back/Forward and the small commands; Windows got the Mac-only Reset Form, Next/Previous Comment, Share,
  Reply to Comment, Customize Command Bar, IPv6 zones. Three hostile-input release reviews' findings fixed (Print for
  Mac: any app could start a scan, sharing open on public hotspots; PDF for Mac: crafted CFF/BMP crashes, AppLog privacy,
  zip bombs; Windows: zone handling, Share, Reset Form, JPEG) and the same bugs fixed on Windows where they existed. Two
  memory bugs behind Mac CI's signal 11 fixed (a dropped MuPDF stream; MuPDF's global HarfBuzz context:
  `mac/Vendor/mupdf/patches/harfbuzz-context-per-thread.patch`, a report for MuPDF's tracker beside it, for the owner to
  file; Windows is safe: MuPDFCore's shared locks, ReflowableLayoutTests). Redaction on a highlighted line now closes the
  gap (it showed the removed word's width), Mac and Windows.
  - **Released 2026-11-28:** Windows Inkvolt PDF 1.20.0 and Inkvolt Print 1.11.0 (Published 05:34/05:23), Inkvolt PDF
    1.20.1 (the redaction fix; submitted, in certification when this was written: mark `pdf-v1.20.1.0` `-Published` and
    the website's softwareVersion once Published); Inkvolt PDF for Mac 1.14.0 live (pdf-mac-v1.14.0, appcast 5afed9ae,
    Homebrew cask 68922f7, website 7de21a5); Inkvolt Print for Mac 1.5.0 build 10 WAITING_FOR_REVIEW (released by
    itself on approval; then tag `print-mac-v1.5.0` on 27b67d2c and the website's softwareVersion 1.4.0 → 1.5.0).
  - **The build Mac's `gh` isn't signed in:** `release.sh --publish` failed at its GitHub step (exit 102); the release and
    the appcast were made from the PC (the appcast's PUT through `gh api --input <json>`: on Windows the base64 body is too
    long for an argument). Sign `gh` in there before the next PDF for Mac release. The release clone's MuPDF is
    1.25.2-cca5e0db (the HarfBuzz patch). Benches: Windows 2026-11-28 under load, the same as 1.19.1 measured right after
    (bdc6ccb2); Mac every target met (48579a98).
  - **For a person:** the new screens on screen and with VoiceOver (both Mac apps); a real copy from Inkvolt Print for Mac
    (its build lacked Local Network permission), a USB scanner and one with buttons, an HP that offers walk-up scan or
    its own copier, a USB device with no driver, a link-local IPv6 printer, the Share sheet; an older Inkvolt PDF for Mac
    finding 1.14.0 in its feed (en, es); Microsoft Office as PDF for Mac's converter (off until checked). Known red on
    the Mac only: HalvesJoin's huge page (timing; CI skips it).

- **Windows hotfix: printing through a queue whose driver Windows can't load (2026-11-27, 09a33387).** After that night's
  Windows updates (this PC: Windows 11 on Arm, Insider Dev 26340), every Microsoft IPP Class Driver queue here failed with
  "PrintTicket provider failed to bind to printer. Win32 error: The system cannot find the file specified" in every app
  (Print to PDF still worked; PrintService/Admin events 318 and 232). Inkvolt Print 1.10.1 routes such a print straight to
  the printer over IPP (`QueueDriver`, `PrintRouter` `queueWorks`); Inkvolt PDF 1.19.1 says so before its print dialog and
  hands the document to Inkvolt Print (`--queue`). Both Published in the Store 2026-11-27 (Print 17:03, PDF 17:13; bench skipped: no engine
  change); GitHub releases `print-v1.10.1.0`, `pdf-v1.19.1.0` marked Published; website `softwareVersion` deployed (portfolio
  78d8a77). Mac unaffected (macOS printing, no Windows driver): no Mac release. This PC's queues stay broken until they're
  removed and added again (or a restart/spooler restart, which needs the owner): the owner's call.
- **Mac parity done in code (2026-11-23/24; the owner: "full feature parity like Windows").** Every Wave 4 item of both
  roadmaps is on the Mac, reviewed (each branch, then a whole-release hostile-input pass per app) and merged, plus
  Inkvolt Print's printer data of 2026-11-20, the printer's web port, SNMP refusals, separator codes (Vision), P12 2.1
  (print straight to a printer with no macOS queue: PWG raster, Apple raster, PCLm against libcups and ippeveprinter),
  Compare's scan alignment, export links and folder-search phrases on the Mac. Mac CI: the Print job's deadline stall is
  fixed (`OffThePool` trait, af218267) and the Vision tests' macOS 15 white page was the test's drawing, not Vision
  (e43b62fe); CI's `pdf` job's loopback flake (127.0.0.1 stops answering) is fixed (13538627: CompareAlignTests held
  the runner's Swift pool ~11 minutes, now off it; `AiSocketTransport` reads answers as they arrive), Mac CI green.
  2026-11-24 also: Use Your Phone drains a refused upload so its answer isn't lost to a reset (6f01a905;
  `mac/tools/phone-client.sh`), and both Mac apps have an accessibility audit (`sh mac/tools/ax-audit.sh`, 37a6fad2;
  its open findings for a person with VoiceOver in PLAN).
  - The owner's decisions (2026-11-24): the drawing set's speed targets are a known limit (MuPDF's drawing; recheck on a
    MuPDF upgrade); Inkvolt PDF for Mac's work merged after 1.13.0 (Compare alignment, export links, folder phrases, the
    MuPDF patch) waits for the next Mac release; HP's walk-up scan waits for a recording from a printer that offers it;
    the phone scan's TLS key stays in the login keychain (app-scoped by its ACL); the MuPDF inline-image patch is made, on
    the Mac only (`mac/Vendor/mupdf/patches/`; the upstream report in `inline-image-filter-budget.md`, for the owner to file).
  - The release clone `~/Repos/inkvolt` has the patched MuPDF (pulled and `sh mac/Vendor/mupdf/build.sh` run
    2026-11-24; the inline-picture test passes against it). Print for Mac 1.4.0 goes on sale by itself once Apple
    approves; a scheduled check (every 4 hours) then updates the website and this file, and turns itself off.
  - What only a device can do, with what each needs: PLAN's "Open" (P12 2.2 HP walk-up and ICA buttons, 3.1 scanner
    sharing, 3.3 the printer's copier; the Office converter's Microsoft 365 checklist).
- **Released:** Wave 4 (a market check of 2026-11-21; the owner: "do all of them", release them) is built, reviewed and
  in the Store: Inkvolt Print 1.8.0.0 and 1.9.0.0, Inkvolt PDF 1.17.0.0 and 1.18.0.0, all Published 2026-11-22 (the
  website's `softwareVersion` 1.9.0 and 1.18.0). GitHub releases `print-v1.8.0.0`, `print-v1.9.0.0`, `pdf-v1.17.0.0`,
  `pdf-v1.18.0.0`. **Inkvolt PDF 1.19.0.0 and Inkvolt Print 1.10.0.0 Published 2026-11-24** (the hostile-input review's
  hang fixes, Print's phone-test fixes, a direct job followed 2 hours at most, a preset's `{n}` padded to 32 digits at most,
  any standard format, `495b4832`): tags `pdf-v1.19.0.0` (`3afe9263`) and `print-v1.10.0.0` (`7aa7d90d`), GitHub releases,
  website `softwareVersion` 1.19.0 and 1.10.0. The next submission of each must be higher. Every Wave 4 item is Done on Windows and on the Mac in both roadmaps. **Inkvolt PDF for Mac 1.13.0 published 2026-11-23** (Wave 4 on the
  Mac): `pdf-mac-v1.13.0` on `22c18b3e`, notarized DMG sha256 83264265…3f93e0660f, 41,748,931 bytes, not Latest; the
  appcast (17 releases, each once, Spanish notes) found by an unmodified 1.12.1 (en, es); the installed DMG's full
  self-test 758/758 in en and es; Homebrew cask `f36e0f5`; website `7ea1d3e` deployed and pushed. **Inkvolt Print for
  Mac 1.4.0 (build 9) submitted 2026-11-23, approved and on sale 2026-11-24 (READY_FOR_SALE; website `0fa3d39` deployed
  and pushed)** (Wave 4 on the Mac, the hostile-input review's fixes at
  `2f6bb9a1`): `print-mac-v1.4.0` on `b757e0ed`; preflight OK, uploaded, VALID; listing applied (release after approval,
  as before; es-MX What's New skipped: the version has no Spanish localization in App Store Connect); review notes name
  the phone scan's HTTPS page (TCP 9781, only while Use Your Phone…'s window is open), the camera (Use a Camera… only)
  and location (Set Up a New Printer's Wi-Fi… only). CI's `build`
  job on `2f6bb9a1` compiled InkvoltPrintKit but failed its Vision/SNMPv3/timing suites (`t3/mac-ci-test-stall-fix`),
  so its app step was skipped; the app compiled on the build Mac (release.sh's archive, a Release `build.sh`) and 29
  `--report --demo` checks of that Release build read as expected.
- **Release gotchas:** a branch merged after `## Next` became `## x.y.z` can put its What's New lines under the released
  version (it happened with 1.17.0; fixed by hand): after each merge during a release, check `## Next` still holds them.
  Each release ran a hostile-input review of the diff since the last tag before packing; keep doing it. The bench needs an
  idle PC; on-screen fps on 2026-11-22 was below 1.16's run for the 1.16 app too (this PC, not the app).
- **Flaky under load (timing):** `EditableTextTests.MakingPagesEditable…`, `PipedChildTests.AChildWithPipes…`,
  `TranslationLooksTests.Thousands_of_rules…`, the two new `Release118HostileTests` linear-time tests,
  `DriverDownloadTests.A_finished_childs_pid_taken…` (TimedOut once under load, 2026-11-22); `tools/test.ps1` names them.
- **Phone tests (2026-11-22, Store 1.9.0.0, Ethernet now Private):** an iPhone passed both. Scan with your phone: QR,
  Safari's warning, a photo, the page straightened, Done (the first upload was slow; the PC replies as soon as the body is
  read, so it's the phone's shrink or the Wi-Fi: not yet timed). Share a printer: the iPhone printed a PDF through
  "Inkvolt Share Test" (a queue on the local port `C:\InkvoltShareTest\job.out`, HP PCLmS class driver: `CanShare` passes a
  file port not ending .prn/.pdf) and the queue wrote a 6-page PCLm. Three bugs found and fixed on master, in `## Next`:
  an iPhone's browse asks 18+ questions in one packet (every printer it knows) and `MdnsSubtype.MaxQuestions` was 16, so
  it was never answered and saw the printer only from the turn-on announcement (now 256); `TurnOnAsync` made a new UUID
  each time, so phones listed one printer per turn-on (now `PrinterShare.UuidFor`, name-based v5); the phone scan said
  "Scanning…" while waiting for the next photo (`Capture_GotPage`). Still to do: the OnePlus (it couldn't read the QR
  code; Android printing untested; its wireless debugging is on, adb runs here), and timing the iPhone's upload.
  Diagnosing mDNS: `pktmon` (elevated) shows each query's questions; a Python listener on 5353 joined to the group shows
  multicast answers. iOS answers a browse from its cache, so it often sends no query when the print sheet opens.
- **The build Mac** (`buildmac`, a MacBook Air M5 in the owner's wife's account, `Z:\machines\rules\build-mac.md`): slot
  worktrees `~/Repos/inkvolt-<slot>` for agents at once (`INKVOLT_MAC_SLOT`; three at a time); spare slots were removed
  2026-11-24 (`pc` and `windows` kept; the release clone `~/Repos/inkvolt` is only pulled, for releases). It has Xcode 27
  where CI has Xcode 26: CI's Swift gives up on or can't infer expressions Xcode 27 compiles fast, and its SDK has types
  that clash with ours (it had a `Picture`): type literals and closures, keep expressions short, name ambiguous types in full.
## For the owner: hardware

- On the Macs, in this order: phone as a scanner with a real iPhone and an Android phone (Inkvolt Print for Mac's own HTTPS page, its
  self-signed certificate, the firewall's question); a password-protected PDF printed on a real printer from Inkvolt PDF
  for Mac 1.13.0; a booklet and two-sided printing by hand on the M234dw; a camera page; the Wi-Fi guide with a new
  printer; Print a PDF straight to the M234dw with no Mac queue for it (Cancel during a real job); the Mac windows by
  eye and with VoiceOver (PLAN's "What a person must look at" and each section's list).
- Wave 4 on paper and devices: two-sided printing by hand on the M234dw (start with `--hand-duplex`; 1, 2, 5 pages and
  2 copies of 3; each sheet's back right way up); a booklet folded, a poster joined, a card folded; an iPhone and an
  Android printing to a shared printer; Set up a new printer on a new or reset printer; a real punched sheet, an A3
  original joined from two halves; a webcam page; a week of the print log against the printers' page counts.
- Scanners: a WIA 2.0 scanner (page progress, Stop, a PDF-only WIA driver); a PC with only a 32-bit TWAIN driver; a jam
  partway through a feeder scan; a printed QR separator sheet scanned for real; scanner sharing from an iPhone or a Mac on
  a Private network with a real USB scanner behind it.
- Get the driver: real installs through the app from Canon, HP, Brother and PFU (and PFU's licence page in the Store
  copy).
- The M234dw: Record a printer on it (the copy documents' element names; it has no LEDM walk-up scan, so HP's Scan to
  Computer can't be confirmed on it); a copy on the printer and a direct IPP print; its IPP and SNMP page counts, its panel
  text, SNMPv3 against it.
- Other printers: a WSD printer that answers SNMP; a queue added in Settings appearing on the printer list (checked only
  through `inkvoltprint queues --watch`); a printer whose web page is on another port; a recording of a CDM printer's
  `/cdm/deviceUsage/v1/lifetimeCounters` (what makes CDM lifetime counters possible); a refused SNMPv3 printer (the demo
  has none).

## For the owner: eyes

- Wave 4's windows on screen (both apps) and their Spanish; spell check's underline at different zooms; Reflow with a
  screen reader; dragging tabs between windows and monitors; the AI features against a real model (Suggest Redactions,
  Ask Across Folders, Search by meaning, Edit by Asking, Summary to Audio); JBIG2 pages in Acrobat and Edge; a copied
  table pasted into Excel.
- Inkvolt PDF: Crop Picture's handles, the ￼ mark and Picture… (the editor stays open behind the file dialog); links in
  an exported PowerPoint and in a browser; Compare's overlay on a real scan; Arabic and Japanese translated copies in
  Firefox (copy a line, search a phrase) and Acrobat; Make Text Editable on an Arabic scan; Tesseract's language list and
  download wording; comments.pdf's panes filling about 1 s after the pages; the tool icons, dragging marks in a turned
  view, the Comments pane's Color menu.
- Inkvolt Print: the SNMP access dialog with Narrator.
- Both: Open Log Folder in both Store copies; a multi-file Explorer conversion while the running copy doesn't answer; the
  Spanish of both apps' newer What's New lines.
- `pdf/tools/export-corpus` with `-LibreOffice` (optional; never run).

## Known limits (not action items)

`drawings.pdf` Find and scroll speed (MuPDFCore 2.0.1); pdf.js runs a right-to-left word into a figure or Latin word
beside it, and loses spaces on right-to-left lines with another look inside; MuPDF reads Arabic-Indic digits backwards;
Canon models sold only in the US or Europe aren't found and ScanSnap has no driver lookup; the slow index runs are Windows
Defender scanning each file (`pdf/ROADMAP.md` 3.5).

## If the test host crashes or hangs

Not reproduced under load with `--blame-crash`/`--blame-hang`; MuPDF's "premature end of data in flate filter" is printed
by many tests, not by a crash. A starved thread pool stalling the worker pipes was the likeliest cause of the hang
(`WorkerPipe`). If it happens again: the blame dump and the last tests in the TRX.
