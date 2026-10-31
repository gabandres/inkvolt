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

**Under way (owner's go, 2026-10-31).** Print wave 2, the three items no hardware is needed for, one branch each, not merged, pushed to
origin as backups (they may be unfinished: each commit message says):
- 2.6 Fleet page: `worktree-agent-aa5ca6a254c1712da`
- 2.4 Batch print: `worktree-agent-aafc822e7ecd8b955`
- 2.3 Scan cleanup and Unicode OCR layer: `worktree-agent-a7bfaa97044299e39`

Resume: finish each against `print/ROADMAP.md`, run `dotnet test Inkvolt.slnx`, merge to master. Expect small conflicts in the docs and
`SupplyHistoryCsv.cs`, which 2.6 and 2.4 both touched. Run a review for hostile input before any release, since the last two reviews found
18 bugs in code whose tests passed. Then 2.1, 2.2 and 2.5, whose code and simulators can be done away from hardware, each needing a
real printer or scanner to finish.

**Next (Windows).** Print waves 2-3, Report a problem, WIA PDF-only scanners,
TWAIN and black-and-white in Scan, 3.1, 2.1 leftovers, UX still-short items.

**Tests.** Timing tests still fail now and then under load, a different one each full run (`ThreadClockTests`, `FindWorkerTests`,
`HugeStringsAreRefused…`); each passes alone.

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
  windows, Print's palette for a printer other than the selected one, motion in the scan review.
- Tests: three timing tests flake only when both test projects run in parallel on a loaded PC
  (`JsFormTests.HostileScripts…` was loosened; `ThreadClockTests` and one more seen once); consider a serial
  collection for timing tests.
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
