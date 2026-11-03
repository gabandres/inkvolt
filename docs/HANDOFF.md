# Handoff, 2026-11-02 (newest first)

## Start here (next session)

What is truly left, per app and platform, checked against the code on 2026-11-02. Done items are gone from this list;
`git log` has them. **No release is planned: the owner decides on return.** Don't publish a Mac or Store version on your
own (when the owner asks: `INKVOLT_PUBLISH=yes release.sh <v> --publish`, then the Homebrew tap
`gabandres/homebrew-inkvolt` and the website `Z:\portfolio`, as 1.4.1 and 1.5.0 were).

**How to work a Mac item.** One item per commit, its .NET tests ported first (same names), 0 warnings, `mac/docs/PLAN.md`,
`WHATS-NEW.md` "## Next" and the roadmap's Mac line updated, then push to master. Use `bash mac/tools/mac.sh` for
everything on the Mac (`mac/CLAUDE.md`). One agent on the Mac at a time (they share `~/Repos/inkvolt-pc` and
`/Applications`). After each push, check the `mac` CI job: CI's Xcode is older than the Mac's and rejects long
expressions the Mac compiles (split them), and its runner is slow (heavy tests skip on `GITHUB_ACTIONS`, as
`ScanCorpus.runs` and Vision's do). Each item's spec is the Windows code and tests named in `pdf/ROADMAP.md`.

### Inkvolt PDF for Mac: scheduled (unattended run, Tue 2026-11-03 08:10)

One agent, cheapest first, one commit each, in this order:
1. ~~Saved signatures between launches~~ Done 2026-11-03 (`SavedSignatures`, Application Support's "Inkvolt PDF/signatures").
2. ~~Rotate view~~ Done 2026-11-03 (View › Rotate View Clockwise ⇧⌘R / Counterclockwise ⇧⌘L; ViewTest).
3. ~~Dark pages~~ Done 2026-11-03 (View › Dark Pages (Night Reading), Settings; `NightColors`).
4. ~~Dragging thumbnails~~ Done 2026-11-03 (the sidebar's thumbnails: move, copy to another window, PDFs and pictures dropped).
5. ~~Reading modes~~ Done 2026-11-03 (View › Single Page ⌘4, Continuous ⌘5, Two Pages ⌘6, Two Pages with Cover ⌘7).
6. ~~Insert from Scanner~~ Done 2026-11-03 (Pages › Insert from Scanner…; demo scanners only: a person must check it
   with a real scanner, PLAN.md).
7. ~~Report a Problem~~ Done 2026-11-03 (Help › Report a Problem…; `ProblemReport`, HelpTests).
8. Comments and form data in and out (roadmap 1.4): Export and Import Comments (XFDF, FDF, CSV), Summarize Comments,
   form data as CSV and JSON (the Mac has XFDF and FDF only), Fill Forms from CSV (`FormMerge`), Batch's comment exports
   and summary, `--fill`.
   **Skipped in the unattended run of 2026-11-03** (no code committed): the Windows core alone is about 2,000 lines
   (`CommentFiles` with its XFDF and CSV parts, `FormDataFiles`, `FormMerge`, `CommentSummary`) and 22 tests, plus the
   app's commands, Batch's three actions and `--fill`: well past the run's 90 minutes an item. Split it into its own
   session or two (CommentFiles first; then FormDataFiles' CSV and JSON with FormMerge and `--fill`; then the summary).
9. Redaction by pattern, Windows' additions of 2026-11-01 (roadmap 1.1, "Finished on Windows 2026-11-01"): named sets,
   scans searched through OCR text, every hit listed to accept or skip, the read-back and the report with CSV, Batch's
   new failure rules, the Pro split.
   **Skipped in the unattended run of 2026-11-03** (no code committed): Windows' additions of 2026-11-01 and 2026-11-02
   are about 3,500 changed lines (79ba338 alone 2,384), touching the pattern search, OCR text, the hit list, the
   read-back, the report and Batch: past the run's 90 minutes an item. Its own session.

### Inkvolt PDF for Mac: other gaps, not scheduled

- No Windows test to port: vector printing (pages print as 300 dpi pictures), printer status and Inkvolt Print's printer
  settings when printing, the Snapshot tool.
- Larger roadmap items: 2.3's leftovers (leaving out blank pages, scan presets, the scanners Inkvolt Print remembers in
  its sandboxed container; File › Scan already has the feeder, both sides and OCR); 3.4 long-term validation (writing /DSS
  and /VRI, B-LTA, Check Signatures Online, Batch's action, the Pro gate, the rest of LtvTests.cs;
  `Signatures.verify(online:)` exists in PdfCore, unused by the app); 3.3 Compare with Office files, scans and formatting;
  3.5 indexed folder search; Microsoft Office as E12's converter (backlog note below, on the mini); 3.1 Translate (after
  2.1); 2.1 paragraph text editing (the largest; the Mac has the line-level editor).
- The Mac UX pass (`mac/docs/UX-BRIEF.md`, not started; after the PDF items).

### Inkvolt PDF for Windows: open, no hardware needed

1. OCR: done 2026-11-03, `MissedLines` (through `ScanText`, so Recognize Text and Redact by Pattern): ink no word covers,
   in line-sized type-like bands of the cleaned page, read again alone, then word by word; words put in reading order.
   `pdf/tools/ocr-corpus` RESULTS.md: the six scans have no skipped line (unchanged); `skipped-lines` (the redaction
   corpus's first page, typeset) 39.1% → 21.7%; `probe` makes 36 more pages (none skipped a line). Left: Windows reads
   "1111" in no way, even alone, so 2 of that page's 6 skipped words stay lost; a dropped word inside a line that was read
   isn't read again (reading such ink gave fragments: "4 lY).70"); the cleaned path only (Clean off reads as before).
   The Mac (Vision) port should check whether Vision skips lines too before porting it (`MissedLines.cs`,
   `MissedLinesTests`). Seen while measuring: the redaction corpus's page 3 (three lines of numbers, typeset) is read
   upside down once cleaned ("OO 6830 9999 9999 9999"; as rendered it reads right): `Upright` on a page of digits.
2. PDF 3.4: ~~certifying with a choice of fields to lock~~ Done 2026-11-03 (`FieldLock` on `SignRequest`, the Sign dialog's
   "Lock form fields", `ProFeature.FieldLocking`; `FieldLockTests`, EU DSS B-LTA TOTAL_PASSED on a certified form with a
   field locked). Left: Batch's long-term action (not started: it needs the address window per batch, and a client per run).
3. Translate's "Still wrong" list (`pdf/ROADMAP.md` 3.1), rows drawn by one operator first. Run a real model (llama.cpp,
   `Z:\tools\llama.cpp\models`, on a port other than the knowledge base's) before trusting Translate again.
4. PDF 2.2 leftovers (suspect words for Batch, Scan and export), 2.1 (turned text, mixed families), 2.4 (form XObjects
   piece by piece, row spans).
5. Speed: `drawings.pdf` misses Find (30 s) and scrolling (773 ms a page); on-screen scroll fell under 60 fps while the
   PC was loaded, recheck idle.
6. ~~UX still short (`docs/UX-REVIEW.md`, round 2): group menus as flyouts, the bar at 150 % text.~~ Done 2026-11-03
   (UX-REVIEW round 3): flyouts with a line under each command; under 1100 logical DIPs the palette button keeps its icon
   and Appearance moves into "…", so at 150 % on 1200 DIPs the bar keeps six commands; its menus follow the Text size.
   Left: Comment still goes to "…" there; Organize's page pictures.
7. Small fixes: done 2026-11-03, `AiStreamParser.ParseWhole` and `AiProtocol.OllamaLoadedContext` check that the JSON
   root is an object before `TryGetProperty` (`[]`, `"x"`, `1`, `null` gave InvalidOperationException; AiProtocolTests'
   `JsonThatIsNotAnObjectIsNotAChatCompletion`). Done 2026-11-03, DevScript's `compare` checks that both
   files exist and open before `Comparing.LoadFile` (whose modal error the off-screen script never answered) and fails the
   step (`FAILED:` in the log, the app quits) on a bad path or a side that doesn't load. Done 2026-11-03, the central part of the
   Flate limit: every PDFsharp `UnfilteredValue` in Inkvolt PDF goes through `PdfObj.StreamBytes`, which refuses a stream
   past 256 MB (`PdfObj.MaxStreamBytes`; attachments saved or opened: 1 GB) with `StreamTooLargeException`, an IOException
   the "damaged filter, read as empty" catches don't swallow, so whatever reads it fails with a message. A leading Flate
   filter is measured before PDFsharp inflates it (counted, kept nowhere; streams under 1/1032 of the limit skipped). The
   redaction check never reads one as empty: page content, forms it draws, hidden layers, attachments, XMP, XFA and earlier
   versions are each noted "too large to search" and the report is Incomplete (Batch then saves nothing, the read-back
   fails); Redaction.Apply itself rasterizes through MuPDF and reads no stream. HostileStructureTests:
   `StreamBytesRefusesAStreamThatInflatesPastItsLimit`, `RedactionCheckSaysItIsIncompleteWhenAStreamIsTooLargeToRead`.
   Done 2026-11-03, the rest: `BoundedFilters` puts bounded subclasses of PDFsharp's Flate, LZW and ASCII85 decoders in
   `Filtering`'s shared instances (by reflection, field names of PDFsharp 6.2.x; a test checks they're in place), so every
   stage of a filter chain, wherever it is in the array, is measured before PDFsharp decodes it (Flate inflated and
   counted, LZW counted by entry lengths as PDFsharp's decoder makes them, ASCII85 by its "z"s), and PDFsharp's own
   decoding while it opens a file (object streams, xref streams) is too: every open goes through `PdfObj.Read`, which
   allows 256 MB a stream and 256 MB in all, so such a file fails what opens it with StreamTooLargeException's message
   (viewing goes through MuPDF and isn't affected). Tuned: Optimize leaves a stream it can't unpack as it is, and a page
   holding one keeps its images (`ContentImages.Scan` says incomplete); the text layer takes such a stream for not its
   own. Kept failing on purpose, as a skip could give a wrong result: content editing, accessibility check and Auto-Tag,
   PDF/A, fonts and ToUnicode maps, Sanitize, vector shapes, page marks; the redaction check notes it and is Incomplete.
   The attachment list's packed size for one without /Size is fine as it is. HostileStructureTests:
   `OpeningAFileWhoseObjectStreamsInflatePastTheLimitFailsBeforeTheMemoryIsSpent`,
   `EveryStageOfAFilterChainIsMeasuredBeforeItIsDecoded`, `OptimizeAndTheTextLayerPassOverAStreamTooLargeToRead`. Not
   checked: MuPDF's own inflating (it streams object streams, so memory stays small, but a bomb costs it time).
8. ~~CI: the Windows `test` job fails about one run in two on a different timing test each time~~ Done 2026-11-03:
   `shared/Testing/Timing.cs` (linked into both test projects): `Timing.Limit` (4× on `GITHUB_ACTIONS`),
   `Timing.CancelAfter` (cancels from a thread of its own: a pool timer fired after Parallel.For work had finished) and
   the `Timing.Alone` collection (runs after the parallel tests) for deadline tests and file-let-go tests. Causes in the
   last 40 runs: a starved thread pool (PageCleanup, TranslationCopy, OtherBrands IPP, DeviceHttpLimits, CertificatePin,
   FleetRead; then QueuePrinter's 50 ms call deadline and BatchPrint's 100 ms ones, which the healthy call must meet too;
   LtvTests' 3 s client deadline, which a refused loopback connection Windows retries for ~2 s overran), a quiet period a stalled timer overran (BatchPrintFolder), handles to files open in place inherited by a
   child another test started with Process.Start (FindWorker, InPlace; `KeptText` now runs alone), Pro's globals read
   outside the Pro collection (`LtvProTests`), and a real bug: FolderIndexer called a folder moved away mid-listing
   "Couldn't list the folder" instead of away. Fixed 2026-11-03: OfficeConverter started its helper with Process.Start, so
   the helper held every tab's in-place file while it converted (saving over one failed meanwhile); it now starts through
   `FindWorkers.StartWithOnlyPipes` (a handle list: its output and error pipes only), and Show in Folder goes through the
   shell (ShellExecute passes on no handle; explorer.exe through Process.Start did). Print's `Log.cs` and the `--try`
   start in `MainViewModel` still use CreateProcess with inheritance (Print opens no file in place).

Needs hardware: 2.3's acceptance test (a WIA flatbed and a WIA feeder scanner, 10 pages each; TWAIN and black-and-white
in Scan).

### Inkvolt Print, Windows and Mac: ON HOLD (owner, 2026-11-02)

Not next work; listed so nothing is lost. Print for Mac 1.0 waits for App Review (the owner is asking Apple).
- Mac, the app halves of what PrintCore already has (PLAN.md's P12): 1.6 Pro key (CryptoKit verifier, the app group
  container, Help › Inkvolt Pro…), 1.3 scanners that only give PDF (PDFKit renderer), 1.5 firmware watch, 1.1 supply
  history (Swift Charts), 2.6 Fleet page, 2.4 batch print, 1.2 record a printer (`--report` runner). Not started on the
  Mac: 3.4 job notifications (the rules to PrintCore; CUPS gives no page counts through `cupsGetJobs2`), 2.3 scan
  cleanup and a Unicode OCR layer.
- Windows, no hardware (hold lifted for these by the owner, 2026-11-03): 3.2 a community per printer DONE (2026-11-03,
  Credential Manager, `SnmpLoginTests`); SNMPv3 DONE (2026-11-03, Pro, authPriv SHA-256/AES-128, `SnmpV3Tests`; never
  tried on a printer's agent; PrintCore on the Mac needs the same port later); UX: the palette for another printer DONE
  (2026-11-03, "Printer: command" entries once a word is typed); motion in the scan review DONE (2026-11-03, subtle:
  never while a scan or save shows progress, `ReviewMotion`).
- Windows: *Plugged in, needs its driver* DONE (2026-11-03, owner asked, for 1.3.0.0): USB printers Windows found but has no
  driver or queue for (`NeedsDriver`, `NeedsDriverTests`; real case: the HP LaserJet P1006 here, bound to *Generic printer device*).
  Its words are in Core's `NeedsDriverText` (Spanish: see the commit). Untried: *Set it up* with a real driver installed.
- Hardware, both platforms: 2.1, 2.2, 2.5, 3.1, 3.3, WIA PDF-only scanners, batch print on paper, a real jam for job
  alerts. No physical printer has printed a page, and neither stuck-job rule has fired on a real spooler.
- Small screens and Windows 10 FIXED (2026-11-03, for Print 1.3.0.0; `docs/ux-review/small-screens/README.md`): the One
  PDF Print button was clipped with no scroll (even at 1180 × 800); now the options scroll and Print is pinned. Windows
  larger than the screen opened with the title bar off the top (`ScreenFit`; PDF's restored size too). Windows 10 path:
  no Mica request below 22621, opaque background, MDL2 icons; dev aids `INKVOLT_FAKE_WIN10=1`, `INKVOLT_FAKE_WORKAREA=WxH`,
  `--demo --sample-pdf [--printer n] --press-print report.txt`. **A person must still run it on the real Windows 10 PC**
  (the test zip from that session, or the next Store build): frame, caption buttons, icons, Choose a PDF → Print.

- USB printers' supply levels (owner, 2026-11-03, for Print 1.3.0.0; roadmap 3.6): route 1 DONE, levels and status from a printer on
  Windows' IPP class driver (IPP over USB included) through `IppPrintDevice` (`QueueDeviceTests`), the supplies card's source line and
  *Not reported by this printer*. Route 2 DONE, the driver over bidi (`IBidiSpl2`, `QueueBidiTests`, *From its driver*, the demo USB laser). Neither route has been seen answering
  on real hardware: no IPP-over-USB printer and no maker's driver here. The M234dw and M277 (IPP class driver over WSD) time out on route 1 while off
  the network; `inkvoltprint queues --bidi` shows Windows answering 13005 (schema not supported) for them. **Try `inkvoltprint queues --bidi` on a PC with an HP or Epson driver** and look at the levels.

### Only a person

Look at the Mac UI nobody has seen (PLAN.md lists it per step), hear Read Aloud with a real voice, try E12 with a real
LibreOffice and web address, see Inkvolt PDF open a scan from Inkvolt Print for Mac.

### Machines

**The M1 Air is being sold (owner, 2026-11-02); an M6 Mac mini (24 GB, 512 GB) replaces it.** Sell only after the mini runs
builds and releases. **Backed up to OneDrive (2026-11-02, hashes checked):** `Work/Bermudez Systems LLC/Inkvolt/Keys/Mac signing and
App Store Connect/` (both keychains, env.local, the ASC .p8, the GitHub SSH key, a README with the restore steps); the Sparkle key
was already in `Keys/Mac Sparkle update key/` (matches the Air's). What they are, for reference: `~/Library/Keychains/inkvolt-devid.keychain-db` (Developer ID Application:
export its identity as a .p12, or make a new one with `devid-cert.sh`) and `inkvolt-dev.keychain-db` (`dev-cert.sh` can make
another), `~/.inkvolt-sparkle/ed25519.key` (also on OneDrive: check the copy matches before wiping; without it no installed
Mac copy can be updated), `~/Repos/inkvolt/mac/InkvoltPrint/.env.local` (ASC key, keychain password), the SSH keys
`~/.ssh/id_ed25519_github_*`; then on the mini: Xcode, `sh mac/Vendor/mupdf/build.sh`, the `ignia-mac` entry in
`~/.ssh/config` on the PC (or a new host name), and `mac.sh`'s `INKVOLT_MAC_HOST`. Other projects' files on the Air
(Ignia, Callbook builds in `~/build-artifacts`) are outside this repo. The Mac runs macOS 27.2, Xcode 27.1, Swift 6.4.

**Backlog (owner, 2026-11-02): Microsoft Word, Excel and PowerPoint as E12's converter on the Mac** (Windows converts through
Office first). About a day: AppleScript per app with a time limit, files staged in Office's group container
(`~/Library/Group Containers/UBF8T346G9.Office/`) because Office for Mac is sandboxed, Word left as found, the
`com.apple.security.automation.apple-events` entitlement and `NSAppleEventsUsageDescription` (`sign.sh` and `release.sh`
sign Inkvolt PDF with no entitlements today; add the entitlements file there). Needs Microsoft 365 signed in on the Mac
and a person to allow the Automation prompt; do it on the mini.

### Notes

**Released and current.** Inkvolt PDF 1.6.0.0 and Inkvolt Print 1.2.0.0 in the Store (2026-11-02); Inkvolt PDF for Mac
1.5.0 (GitHub release `pdf-mac-v1.5.0`, Homebrew). The Store's release notes are in English and Spanish; neither app has a
Spanish interface (its own project, not started).

**Reviews.** Hostile-input reviews before releases found about 18 bugs in Print and about 20 in PDF, all fixed. Keep doing them.

**Tests.** 4,320, none failing except the usual timing tests under load: `ThreadClockTests`, `AccessibilityCheckStopsOn…`,
`A_file_that_takes_all_the_memory…` and others. Each passes alone. `AccessibilityCheckStopsOn…` has failed in most full runs and could use a longer limit.

# Handoff, 2026-10-31 (newest first)

**Owner decision.** Windows only for now: the Mac isn't up, so nothing waits for it and parity is on hold (`pdf/ROADMAP.md`
"Mac on hold"). The Mac items below stay listed for when it is back; skip them. The next Windows items are in the night's list
below, 3.3, 3.4 and 3.5 now done. Timestamp servers: https only, Sectigo's free one suggested (only http from DigiCert, SSL.com and
GlobalSign when probed); not yet confirmed that Acrobat trusts its timestamps. The privacy policy is updated and live (timestamps,
certificate checks, the Mac's AI assistant). The folder index keeps a changed file's old text about 2 minutes until compaction: accepted
for now, though just-redacted text lingers on the PC that long.

**Released.** Inkvolt PDF 1.5.0.0: published in the Store on 2026-10-31, GitHub release `pdf-v1.5.0.0`, website updated. It holds the three below, with two
pre-release reviews' fixes; each has its checks and limits in `pdf/ROADMAP.md`. The smoke test failed once on the Word step and passed on
the same package when run again: the run started at 13:16 and failed at 13:53, past its 4-minute limit, so the PC most likely slept.
The bench ran on battery: `text.pdf` scrolled at 54 fps, under the target and down from 75, which could be the battery; check on mains.

**The Mac has a known hole, released.** `mac/.../SignatureChanges.swift` still has what 1.5.0 fixed on Windows: a later update can lay
something over a signed page and the signature stays Valid, through a field that only calls itself a timestamp or a comment written
directly in `/Annots`. Inkvolt PDF for Mac 1.4.0 ships it. First thing when the Mac is back.
- 3.3 Compare: Office files and scans on either side, formatting and moves apart from wording, scans aligned, visual differences in
  the annotated copy; the 30 planted changes pass. Not run on a real scan.
- 3.4 Long-term validation: PAdES B-LT and B-LTA pass EU DSS run locally (`pdf/tools/pades-check`). Not checked: Acrobat's "LTV enabled",
  real certificate authorities, smart cards. Certifying with a choice of fields to lock isn't built.
- 3.5 Folder search: 10,000 generated PDFs, a word in 3-114 ms, a changed file found in 3.4 s. Not checked: real PDFs at that scale, a
  hostile PDF, an MSIX install, network drives, OneDrive placeholders. One run took 569 s to index, not explained; a two-word phrase
  takes 3-4 s to list 500 pages.

**Print wave 2 on master, not released.** 2.6 Fleet page, 2.4 Batch print, 2.3 Scan cleanup and Unicode OCR layer. Each has its checks and
limits in `print/ROADMAP.md`.

**Hold on any Print release:** both items were worked on 2026-11-02 (`print/ROADMAP.md` 2.4 has the evidence); lifting the hold is the owner's call.
- The Qualcomm driver crash on exit is explained: Windows' PDF engine frees its Direct3D device as its DLL unloads, and `qcdx11arm64xum.dll` faults; a program with no Inkvolt code does it. It replaced the command line's exit code. `App.OnExit` now ends the process first: 0 of 63 after, on the runs that crashed 15 of 15 and 8 of 8 before. The driver's fault remains for other programs.
- Batch print has spooled on real queues on file ports, through the command line and the view model, each job's pages read back. **A physical printer still hasn't printed a page.**

Open on 2.3: `es-faded` got worse with cleanup, 2.7 % to 3.0 % missed (accepted, the roadmap states it). Cyrillic and Japanese OCR weren't
measured, since those languages aren't installed here. Decisions made on 2.6 and 2.4: Fix all only resumes and turns off Use Printer
Offline; the fleet sorts as the tray does (low toner above offline); batch asks to confirm over 100 sheets and stops at 500 per command-line
or folder run. Run a review for hostile input before a Print release: the last two reviews found 18 bugs in code whose tests passed.

**Print 2.1, 2.2 and 2.5 are parked (owner, 2026-11-01).** They need a real printer or scanner to finish, and the owner has none while
traveling. Work goes on with what can finish without hardware.

**Next (Windows), no hardware needed.** PDF 3.1 Translate side by side, PDF 1.1's leftovers (saved pattern sets, scanned pages, the per-hit
list, the removal report, the Pro split), Print 3.4 Job notifications, then Print's Report a problem button, 2.1 leftovers, UX still-short items.
**Needs hardware, later.** Print 2.1, 2.2, 2.5, 3.1, 3.3, the hardware half of 3.2, WIA PDF-only scanners, TWAIN and black-and-white in Scan.

**Tests.** Timing tests still fail now and then under load, a different one each full run (`ThreadClockTests`, `FindWorkerTests`,
`HugeStringsAreRefused…`); each passes alone. A run across PC sleep fails several more with times like `[7 h 41 m]`: rerun before believing them.

**Small fixes queued, new.** Windows' recognizer can skip a whole line that is on the page (seen on a synthetic scan, with or
without cleanup): `ScanText` could re-read bands with ink and no words, which would help Recognize Text too. A script step whose
file can't be read waits on an off-screen dialog: `compare` in `DevScript` hangs on a bad path.

# Handoff, 2026-10-30 night

Work stopped here on the owner's word, to save the weekly quota. Read this part first; "evening" below is older, and
its items 1, 8 and 9 are done.

**Owner decisions since the evening.** The features other apps keep behind their paid tiers come first (`pdf/ROADMAP.md`
"Priority"). Tesseract waits until someone asks for missing languages. Find in worker processes: yes, done. A Mac release
may ship with UI nobody has seen; the list of what to look at is in `mac/docs/PLAN.md` under each step.

**On master.** Windows: 2.2 OCR stage A (deskew, cleanup, suspect words), 3.2 PowerPoint and HTML export, 3.6 Find in
worker processes, PDF/A copies passing veraPDF, "Not fully checked". Mac: E5 Prepare Form, E6 Measure, E7 PDF/A-2b, 1.3
accessibility checker, 2.4 Make Accessible with PDF/A-2a, E11 AI assistant.

**Released.** Inkvolt PDF 1.4.0.0: published in the Store, GitHub release `pdf-v1.4.0.0`, website updated. New Store
listings live on both apps. Print has nothing new for users. Inkvolt PDF for Mac 1.4.0: published
(notarized DMG, appcast, GitHub release `pdf-mac-v1.4.0`, Homebrew tap, website), with Measure, Prepare Form, PDF/A, the
checker, Make Accessible and the AI assistant, none of whose UI a person has seen.

**Stopped partway, on origin, not merged.**
- `t3/mac-e12-office-web-convert` (`4bc3bdb`): E12's `PdfCore/Convert` with LibreOffice, and two unbuilt app files in the
  last commit. Left: the app, Word for Mac, tests, docs. Its web-page and converter work has not been reviewed.

**Next, in order.** Mac: E12, E9, E10, E13, E14, E15. Windows: 3.3, 3.5, 3.4. Mac: UX pass (`mac/docs/UX-BRIEF.md`), the
Mac halves of 1.4, 2.1, 2.3, 3.6 and 3.3-3.5, Inkvolt Print's 1.1, 1.2, 1.3, 1.5, 1.6, a `--snapshot` step and screenshots.
Windows: Print waves 2-3, Report a problem, WIA PDF-only scanners, TWAIN and black-and-white in Scan, 3.1, 2.1 leftovers,
UX still-short items.

**Small fixes queued.** Windows: `ParseWhole` and `OllamaLoadedContext` throw on non-object JSON. Both apps: a single huge
Flate stream is unbounded. Find: the drawing set's first Find (31 s) and scroll (770 ms a sheet) still miss their targets,
and a page that crashes MuPDF natively is re-read in the app's process. A partly checked file in Batch isn't saved. Mac:
`PrepareForm.swift:500` loses a nudge on ⌘W within 0.45 s. Before `Pro.Enforced` is turned on, the Mac must set `Pro.store`
ahead of the command line (`main.swift:8`).

**Only a person.** Look at the new Mac UI (PLAN.md lists it per step; `/Applications/Inkvolt PDF.app` on the Mac may be a
branch's build). Never run: real Ollama, LM Studio or https from
the Mac, a key saved to the login keychain, LibreOffice on Windows, a real screen reader on the HTML, OCR on a real scan.

**How it ran.** Usage without tokens: `(claude -p "/usage" --output-format json | ConvertFrom-Json).result` in PowerShell.
Partner Center: Edge with `--remote-debugging-port=9333` and the profile `%LOCALAPPDATA%\inkvolt-partnercenter-profile`
(signed in), scripts in `~/.inkvolt-visibility/` (`pc-export`, `pc-import`, `pc-reorder`, `pc-submit`). Mac agents: one
worktree each, `~/Repos/inkvolt-<step>`, and the lock `~/Repos/.inkvolt-mac-lock`. A branch started before another step
merged will conflict in `BatchWindow.swift`, `Report.swift` and PLAN.md: merge master into it, then retest. One daily
task remains (9:00, this thread): the awesome-list PRs, Apple's review, the Store.

# Handoff, 2026-10-30 evening

What the 2026-10-30 session shipped and everything still open, so the next session (or the owner) can pick up
without reading this one. Owner decisions already made that day: full parity Windows + Mac per item; Inkvolt Pro at
$19 one-time, built but **enforcement off** during launch (`Pro.Enforced`, flip at a few thousand installs or ~50 Store
ratings); publish releases without asking; every new agent on Opus 5.5 (PPE instance for long jobs).

## Shipped today

- **Windows:** Inkvolt PDF 1.3.0.0 and Inkvolt Print 1.1.0.0 submitted to the Store (in certification; GitHub
  releases `pdf-v1.3.0.0`, `print-v1.1.0.0`). PDF: Make Accessible + Reading Order/Alt Text + PDF/A-2a (roadmap 2.4),
  USB/TWAIN scanners (2.3), paragraph editing leftovers (2.1), speed work with the benchmark (3.6), Inkvolt Pro
  licensing (gate off), two UX rounds (9.62), the Pro seam shared with Print. Print: `print/ROADMAP.md` (new), Pro
  window + one key file for both apps (1.6), Store-package alerts (1.4), supply history (1.1), firmware watch (1.5),
  record a printer (1.2), PDF-only scanners (1.3), UX rounds (9.61).
- **Mac:** Inkvolt PDF for Mac 1.3.0 published (DMG, appcast, Homebrew tap `gabandres/inkvolt`): Batch with presets,
  watched folders and command line (E8), Reduce/Header & footer/Watermark/Flatten (E4), signatures (E2), Compare (E3),
  the Pro window. Website and README point at 1.3.0.
- **Visibility:** `docs/VISIBILITY.md` (log + next 30 days), Pro page and six search-intent guides live, SaaSHub
  submitted, Homebrew tap, social/press drafts in `docs/visibility/`, Store listing proposals in both packaging READMEs.

## Owner's own 15 minutes

1. Store certification: `msstore submission status 9MXDTSFJ9W28` / `9PNR76HJ62SK` (a poll was left running in the
   session). If either fails, the report is in Partner Center.
2. MacUpdate: click the verification mail (gabriel@bermudezsystems.com), sign in (password in
   `~/.inkvolt-visibility/accounts.txt`), Add App with the texts the session gave (1.3.0 now, not 1.2.0).
3. OpenAlternative (sign in with GitHub, submit the repo); AlternativeTo (add Inkvolt Print); FileHorse (captcha form,
   text in `docs/VISIBILITY.md`, use 1.3.0). Softpedia skipped on purpose (demands a "no AI-written code" tick).
4. Authorize the Gmail connector in claude.ai settings if directory sign-ups should be handled without you.
5. Social: read `docs/visibility/` (Show HN, Reddit per subreddit with rules and days, Product Hunt, one-liners,
   8 press pitches), then say "post them"; the schedule is in VISIBILITY.md's "Next 30 days" (r/software on a
   Wednesday first, press pitches one a day, Product Hunt once Print for Mac is approved).
6. Awesome-list PRs waiting on reviewers: awesome-free-apps #458 #459, awesome-windows #125 #126,
   awesome-foss-alternatives #84, awesome-privacy #1256, open-source-mac-os-apps #1864, awesome-mac #4045.
7. Pro checkout: pick Paddle or Lemon Squeezy, create the account, give the session the product link; the Pro page
   and the window link to https://bermudezsystems.com/products/inkvolt/pro until then. GitHub Sponsors is not set up
   (github.com/sponsors/gabandres has no listing).
8. Answered 2026-10-30: yes. Decision for speed 3.6: text for a long Find is read in worker processes. Done: Find across
   5,000 pages 2.71 s against the 5 s target (`pdf/tools/bench/RESULTS.md`, third run).
9. Partner Center listing text: the keyword/description proposals ("Listing proposals 2026-10-30" in
   `pdf/packaging/README.md`, `print/packaging/README.md`) and the Spanish release notes for 1.3.0/1.1.0 go in through
   the Partner Center pages (the API refuses a draft edited there), after this certification.

## Apple (Inkvolt Print for Mac)

- 1.0 has been WAITING_FOR_REVIEW since 2026-10-26. A Windows-side poll runs with the API key copied to
  `C:\Users\gabri\.inkvolt-asc\` and `mac/InkvoltPrint/.env.local` (git-ignored). When it leaves that state:
  `node mac/InkvoltPrint/asc-listing.mjs apply 5` (creates 1.1 with build 5, already uploaded and VALID) then
  `node mac/InkvoltPrint/asc-listing.mjs submit`, both from Windows. If 1.0 is rejected, read the resolution center
  first. Nudge Apple through Contact Us after ~7 days.

## Mac, when it is plugged in again

- **UX pass for both Mac apps**: brief in `mac/docs/UX-BRIEF.md`; start a T3 session on the Mac in `~/Repos/inkvolt`
  with "Read mac/docs/UX-BRIEF.md and do it" (branch `mac-ux`; merge here).
- **Inkvolt PDF parity steps left** (`mac/docs/PLAN.md`): E5 Prepare Form, E6 Measure, E7 PDF/A, E9 attachments and
  layers, E10 Read Aloud, E11 AI assistant, E12 PDF from Office files and web pages, E13 split view; roadmap items on
  the Mac: 1.3 accessibility checker, 1.4 comments/form data in and out (most of it), 2.1 paragraph editing, 2.3 USB
  scanners (ImageCaptureCore), 2.4 Make Accessible, 3.6 benchmark on the Mac; Mac screenshots for MacUpdate (add a
  `--snapshot` step to the PDF app first).
- **Inkvolt Print for Mac**: the Mac halves of 1.1 supply history, 1.5 firmware watch, 1.6 Pro seam in PrintCore
  (CryptoKit, the key in the app group container), 1.2 record, 1.3 PDF-only scanners; real-printer checks listed in
  `mac/docs/PLAN.md` P10 (separator sheet, ID card, borderless photos, Photos sheet dragging).

## Hardware checks pending (Windows)

- A real USB scanner for PDF 2.3 (10-page flatbed and feeder stack with OCR); TWAIN on an x64 PC.
- Print 1.1/1.5: a cartridge change seen live on LEDM, IPP and SNMP printers; a real firmware update noticed; "Keep my
  cartridges working" on a printer set to automatic updates (one asking for the admin password).
- Print 1.2: recordings of a Canon, Epson, Brother, SNMP-only laser and CDM-only HP; 1.3: a real PDF-only scanner.
- Print 1.4: the packaged smoke run showing a toast with its buttons and the Task Manager startup entry; two Store
  copies sharing one key file.

## Next development (Windows), in the roadmaps' order

- PDF 2.2 Better OCR (deskew, cleanup, optional Tesseract, correction of low-confidence words).
- PDF 2.1 leftovers: paragraphs in turned text, paragraphs mixing font families (edit line by line today).
- PDF 3.6 misses: Find 9.7 s (worker processes, see decision 8), drawing-set scroll 848 ms/sheet, first Find on the
  drawing set 164 s; re-run `pdf/tools/bench` on a quiet PC before the next release and commit RESULTS.md.
- PDF wave 3: 3.1 translate, 3.2 PowerPoint/HTML export, 3.3 compare Office files and scans, 3.4 LTV signatures,
  3.5 indexed folder search.
- Print `print/ROADMAP.md` waves 2 and 3; Help › Report a problem button for `record`; WIA scanners that only offer
  PDF; TWAIN and black-and-white in Print's own Scan tab.
- UX still short (`docs/UX-REVIEW.md`): PDF group menus as WinUI-style flyouts, the bar at 150 % text on 1200-px
  windows (Print's palette for another printer and motion in its scan review: done 2026-11-03).
- Tests: a test that measures time takes its limit from `Timing.Limit`, cancels with `Timing.CancelAfter`, and goes in
  `[Collection(Timing.Alone)]` if it holds a deadline or checks a file is let go (item 8). On a PC loaded by other work
  the full run still overruns a few hang guards (`FolderIndexerTests.A_file_that_never_ends…`' 15 s stall); rerun alone.
- Pro: issue the first business licences with `pdf/tools/pro-key issue` (private key in `C:\Users\gabri\.inkvolt-pro\`,
  backed up to OneDrive › Work › Bermudez Systems LLC › Inkvolt › Keys); the flip of `Pro.Enforced` is a release note.
- Homebrew main cask once the repo has 225 stars and is 30 days old; until then the tap.

## Where things are

- Private keys (never in git): Pro signing key `C:\Users\gabri\.inkvolt-pro\` (+ OneDrive backup); App Store Connect
  key copy `C:\Users\gabri\.inkvolt-asc\`; Sparkle key on the Mac (`~/.inkvolt-sparkle`, OneDrive backup).
- Directory account notes: `C:\Users\gabri\.inkvolt-visibility\accounts.txt`.
- Website repo `Z:\portfolio` (Firebase Hosting; pages generated by `~/.inkvolt-visibility/gen-pages.mjs`, the HTML is
  what's committed; port fixes into the fragments before regenerating).
- Release-notes files used for the GitHub releases: `%LOCALAPPDATA%\Temp\inkvolt-release\`.
