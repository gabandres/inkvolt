# Inkvolt PDF: roadmap

What Inkvolt PDF builds next to do better than the paid PDF apps (Acrobat Pro, Foxit PDF Editor Pro/+, Nitro PDF Pro, PDF
Expert, PDFelement Pro, ABBYY FineReader PDF, Power PDF Advanced, PDF-XChange Editor Plus), feature by feature.
Written 2026-10-27 from a gap review against those apps and their vendors' current help pages; sources are linked per
item. What exists today: [README.md](README.md) ("Using it", "Known limits"); the Mac port: [../mac/docs/PLAN.md](../mac/docs/PLAN.md).

**Principles.** Free (AGPL), local only: no account, no cloud service of ours, no telemetry. AI only through the
user's own endpoint (a local model or their own key), with the "what is sent, where" window before anything leaves.
Every claim is checked: each item below has acceptance criteria that a test, a corpus run or an outside validator
(veraPDF, Acrobat, pdf.js) can confirm.

**Ranking.** value × fit ÷ effort. Value: how many users miss it and how often reviews name it. Fit: how well it works
locally, without a service, on what we already have (MuPDF, `DocLayout`, the edit transaction, Batch). Effort: S (about a
week), M (2-4 weeks), L (more than a month).

**Priority.** Decided 2026-10-30 with the owner: the features other apps keep behind their paid tiers come first, on both
platforms. Second engines and other additions with no known demand wait for it: Tesseract in 2.2 stays to do until
reviews or issues ask for missing languages.

**Mac back (owner, 2026-11-02).** The Mac was on hold from 2026-10-31 and is back: Inkvolt PDF for Mac 1.5.0 has
PLAN.md's E1-E16. Still to do on the Mac: 1.1's additions of 2026-11-01, 2.1, 3.1, 3.3, 3.4 and 3.5,
in the order of the ranked list in `docs/HANDOFF.md`.

**Platforms.** Full parity (decided 2026-10-27): an item is done only when it ships on Windows and on the Mac, so a
person or an office picks the platform, not the features. Windows usually goes first (it has the code to port); the Mac
follows in the same release cycle. PLAN.md's "Parity with Windows" steps (1.0, then E1-E16) are done; what the Mac still
lacks is the list above. One Pro key works on both.
Mac first, Windows to follow: moving and recoloring notes and text markups (the Mac's `AnnotationMoves`, D7 part d).

## Free and Pro

Decided 2026-10-27 with the owner: everything Inkvolt PDF does today stays free, and so does whatever a person needs to
read, fill, sign, edit and protect their own documents. **Inkvolt Pro** is a one-time purchase (in the range of
$19-39; a yearly price for updates may come later) that unlocks the power features below, the ones the paid apps keep
for their top tiers. A business licence (invoices, MSI/Intune packages, a support contact, priority fixes) follows once
there are business users.

- **The source stays open.** Inkvolt PDF is AGPL (MuPDF is), so the Pro features' source is published like the rest
  and anyone may build them. What a purchase buys is the ready, signed, updating build and the licence; the unlock is a
  convenience, not a lock. Closing the source would take Artifex's commercial MuPDF licence (quoted per customer, per
  copy with quarterly minimums): only worth a quote if Pro sells well.
- **No account, still.** A Pro licence is a key signed with our private key (ECDSA P-256: in .NET's own library and in
  CryptoKit, where Ed25519 would have needed a package) and checked on the PC against the public key in the app: no
  server is asked, nothing is sent, the key works offline and survives reinstalling. Inside the app one entitlement
  check (a single `Pro` seam in Core) decides what shows; a feature without the licence shows what it would do and
  where to get Pro, and never takes away a result already made.
- **Selling.** Windows: through our own checkout (a merchant of record such as Paddle or Lemon Squeezy: it handles sales
  tax and VAT worldwide for about 5% plus a small fee per sale), since the Microsoft Store leaves non-game apps that use
  their own commerce 100% of the revenue, against 15% through the Store's add-ons
  ([Microsoft](https://developer.microsoft.com/ja-jp/store/publish-apps)); a Store add-on stays possible for people who
  prefer buying there. Mac: the same key, sold the same way (the PDF app is outside the App Store).
- **Against PDFgear.** It is free and does a lot, so nothing a person needs day to day goes behind Pro. Pro is what
  PDFgear and the free tiers don't do well: rule-based and batch redaction, automation, accessibility remediation,
  folder-wide work, archival-grade signatures.

| Item | Free | Pro |
|---|---|---|
| 1.1 Redaction by pattern | Redacting areas, selections and search matches (today); the built-in patterns on the open document | Saved custom pattern sets, regex, pattern redaction in Batch over many files, the removal report |
| 1.2 Batch presets, watched folder, command line | Batch as it is today | Saved presets, the watched folder, the command line |
| 1.3 Accessibility checker | The checker and its report | |
| 1.4 Comments and form data in and out | All of it | |
| 1.5 Redaction check | All of it (a safety check) | |
| 2.1 Paragraph text editing | All of it (PDFgear edits text for free) | |
| 2.2 Better OCR | All of it | |
| 2.3 USB scanners | All of it | |
| 2.4 Tags, reading order, alt text, PDF/UA | Viewing tags and alt text | Auto-tagging, fixing reading order, PDF/UA output, in Batch too |
| 2.5 What's in this PDF | All of it (the privacy promise) | |
| 3.1 Translate side by side | All of it (it uses the user's own AI) | |
| 3.2 Export to PowerPoint and HTML | All of it | |
| 3.3 Compare Office files, scans, formatting | Comparing two PDFs, moves, the overlay and lining up scans, the annotated copy (it was free already, so it stays free) | Office files and scans against a PDF, formatting changes |
| 3.4 Long-term validation for signatures | Verifying | Adding LTV data, certifying with field locks |
| 3.5 Indexed folder search | Searching open documents | Indexing folders and searching them |
| 3.6 Speed on huge files | All of it | |

**Built (2026-10-30), gate off.** Decided with the owner: **$19**, one time. `Pro.Allows(feature)` in Core (`Pro.cs`) is
the one check every Pro feature asks (`ProFeature`: the rows of the table above); behind it the licence is real: a key
`INKVOLT-PRO-` + base32 groups of five (version, name, email, issue date, products `pdf`/`print`, then an ECDSA P-256
signature; `pdf/tools/pro-key/README.md` documents it, with a test vector for the Mac port), verified on the PC against
the public key in the suite's shared library (`InkvoltPrint.Core/Suite`: `ProKeys`, `ProCheck`, `ProKeyFile`, moved there
the same day for Inkvolt Print's 1.6, so one key licenses both apps), kept in `%LOCALAPPDATA%\Inkvolt\pro-key.txt` where
both apps read it, entered and removed in Help › Inkvolt Pro…, issued with `pdf/tools/pro-key`
(the private key stays off the repo). **Enforcement is off**: `ProCheck.Enforced` (Core's `Pro.Enforced`) is false, so everyone gets
everything while Inkvolt PDF launches; a key is still verified and shown, and buying is presented as supporting the
project or as a licence a business can invoice. It flips on, in a release noted in WHATS-NEW, once Inkvolt PDF has a
few thousand installs or about 50 Store ratings; from then on a locked feature shows what it does and a button to the
window, and the command line prints the message and exits 2 (the UI and tests for both states are in place). Still to
do: the checkout itself (the owner sets it up with a merchant of record; the Get button opens the product page until
then). The Mac's verification (CryptoKit `P256.Signing`, same key, the test vector read in place) and its Help › Inkvolt
Pro… window: done 2026-10-30 (`mac/InkvoltPdfKit/Sources/PdfCore/Pro.swift`, `ProWindowController`).

## Wave 1 (next)

### 1.1 Redaction by pattern (done 2026-10-27)
- **Leader.** Acrobat Pro: Find Text & Redact with fixed patterns (phone, credit card, email, SSN, date), several files,
  review each hit, then apply; it doesn't search encrypted PDFs
  ([Adobe](https://helpx.adobe.com/acrobat/current/removing-sensitive-content-pdfs.html)). PDF-XChange adds regular
  expressions (ECMAScript) and custom saved patterns ([PDF-XChange](https://help.pdf-xchange.com/pdfxe9c/redaction_ed.html)).
  Foxit sells Smart Redact (names, organizations; batch) as a paid plug-in
  ([Foxit](https://resource-cms.foxit.com/tutorials/master-ai-powered-pdf-redaction-with-smart-redact-in-foxit-pdf-editor)).
- **Now.** Areas, selected text, every match of a search; pages become images at 300 dpi with OCR text put back.
  Redact by Pattern (`RedactionPatterns`): SSN, phone, email, card (Luhn), date, IBAN (mod 97), IP and ZIP patterns,
  phrases and a regex (with a timeout), across line breaks and hyphens, on all pages or a range, marked for review in
  the document; Batch's Redact Patterns action applies them over many files.
- **Finished on Windows 2026-11-01.** Named sets saved on this PC (`RedactionPatternSets`, plain JSON, one regex a set:
  alternation covers more); scanned pages and pictures searched through OCR text (`RedactionSearch`); every hit listed
  with page and context beside the page itself, accepted or skipped one by one or all (`RedactReviewDialog`), areas marked by
  hand before the search listed with them, said to go too, and untickable, then applied;
  the result read back, searched again, and what was removed looked for in the rest of the file (dates and ZIP codes only
  by pattern: a file's own time stamps hold the same digits), with what the patterns find in comments, fields, bookmarks,
  properties, XMP, attachments, tags and every other string the file holds; the report as a page and as CSV
  (`RedactionReport`, `RedactionReportDialog`); Batch runs a set over a folder, asks for passwords as before, and fails a file
  with a hit left, with a scan nothing could read, or with a part that couldn't be searched; the Pro split through
  `ProFeature.PatternRedaction` (sets, regex, the Batch action, the report's rows and CSV; the built-in kinds, phrases, the
  list, the read-back and the pages to look at stay free).
- **What the app promises about scans.** Nothing: a page read by OCR is never called clean. A page counts as read by OCR
  when its pictures cover half of it (even under a text layer, which can be poor or planted), when it has no text and
  some ink or a picture, or when it has ink no word explains (a logo, text drawn as shapes). Each such page is flagged in
  the list, the report and Batch's notes, whatever was found on it. Ink where nothing was read is read again on its own at
  300 dpi, since Windows' recognizer can skip a whole line; what stays unread is outlined on the page and can be ticked to
  black out unread. Without an OCR language a scan fails its file in Batch; a text page with a picture nothing could read
  doesn't (a logo mustn't fail a batch), and the file's result, the batch's summary and the report all say to look by hand. A value OCR can't read on a page is the limit
  that remains: only a person looking at the page catches it, and the dialog, the report and this page say so.
- **Other limits.** A page with a text layer that covers all its ink and pictures under half of it isn't read by OCR, so
  text whose visible glyphs differ from its text layer (a broken or hostile font map) can pass. A number or word broken at
  a line end with no hyphen or space ("123456" / "789") reads as two. Phrases on OCR text must be read exactly right; digits
  are read kindly (l for 1, O for 0, spaces round dashes; no check digit on OCR pages). A hit on OCR text blacks out the
  whole word it is in. More than 100,000 hits stop the search rather than list part of them. One page has 10 seconds, each
  regex call 1 second: past that the search stops with an error and nothing is changed.
- **Checked.** `RedactionCorpusTests`: the generated corpus (line-broken, hyphenated, split runs, /Rotate 90, scans upright,
  under /Rotate and on their side, a picture on a text page, a scan under a poor text layer, the encrypted copy through
  Batch) finds 21 of 21 with a stand-in recognizer that reads only what still shows, and leaves 0. The real app with Windows'
  recognizer (`--script`, en-US, Debug build): 21 of 21 on the same file and 0 left, in Redact by Pattern on the plain copy
  and in Batch with a saved set on the plain and encrypted copies; the list and the report looked at in screenshots; 100
  plain pages searched in 5.6 s with no false flags; a list of 30,000 hits opens and Accept All / Skip All answer. `RedactionSetsAndReportTests`: tampered, oversized and malformed
  sets refused whole; masks; formula cells; the Pro gate. Attacks that turned up real bugs, all fixed with tests: quadratic
  overlap check on a page of hostile numbers; a page's regex time unbounded across calls; a hit dropped when its glyphs have
  no box; invisible and wide characters hiding a number; the check stopping with an error on many or long values (its regex
  size limit), treating a timeout as clean, and timing out on a redacted page's pixels; a signed file exported unredacted when the plan had an export after Redact Patterns; a
  dash in a CSV cell starting a formula.
- **Not checked.** A person's eyes on a real scan, and a real scan at all: every scan here is synthetic. Windows' recognizer
  dropping a line didn't happen on these files, so reading a place again has only run against the stand-in. OCR languages
  other than en-US. A screen reader on the list. With `Pro.Enforced` on, the Free report and the Pro window were seen in
  screenshots and Batch's gate is tested, but the sets' buttons and the regex box weren't pressed; nor, gate off, were
  they driven by hand (sets were saved and loaded through dev steps).
- **Beat it when:** patterns for SSN, phone, email, card, date, plus regex and named custom patterns saved on the PC;
  a match is found across line breaks, hyphenation and split text runs; cards pass Luhn and SSNs the SSA's number rules,
  so near-misses aren't marked; scanned pages are searched through their OCR text; every hit is listed with page and
  context, accepted or skipped one by one or all, before anything is applied; Batch runs a pattern set over a folder
  (password files asked for, as Batch does now); a report (CSV and a page in the app) lists per file the page, pattern
  and a masked value of each removal; after applying, the result is read back and searched again, and any remaining hit
  fails the file. Test: a corpus with planted values (line-broken, hyphenated, rotated page, scanned page, encrypted file)
  finds 100% of them and leaves 0 after applying.
- **Effort** M. Windows now; Mac: done with E1 (2026-10-28; your own pattern in ICU syntax) and Batch's action with E8 (2026-10-30). What Windows added on 2026-11-01 is still to do on the Mac.

### 1.2 Saved batch presets, a watched folder and a command line (done 2026-10-27)
- **Leader.** Acrobat Pro's Action Wizard: saved actions on files or folders, exported and imported to share
  ([Adobe](https://helpx.adobe.com/acrobat/current/action-wizard-acrobat-pro.html)). ABBYY FineReader PDF's Hot Folder:
  watched local, network, FTP or mail folders, now or on a schedule, capped at 5,000 pages a month on 2 cores
  ([ABBYY](https://pdf.abbyy.com/how-to/optimize-digitization-routines/)).
- **Now.** Windows: Batch with 16 actions (Save as PDF/A added; Redact Patterns and Check Redaction came with 1.1 and 1.5). Presets
  (`BatchPresets`): named, saved on the PC, exported and imported as plain JSON (format marker, `version`, fields always
  in the same order, no passwords: Protect keeps which ones it sets), strict on reading (an unknown action or setting, a
  wrong value or a newer version is refused saying where). Watched folders (`WatchedFolder`): in the app while it is open
  (Batch › Watched Folders, status in the title bar), or `inkvoltpdf --watch <folder> --preset <file> [--once]` in a
  terminal or a scheduled task; a file runs once its size and time have held for 3 s and nobody holds it open, is moved
  into `working` (so it runs once, across restarts; a run that never finished sends its files to `failed`), then to
  `done` or `failed`, with a line per file in `inkvolt-watch.log`; one watcher per folder; no page cap. Command line
  (`BatchCommandLine`): `inkvoltpdf --batch <preset> <files or folders>` without a window, a line per file, exit code 1 on
  any failure (2 for a wrong command line or preset, 3 stopped), `--help`; Protect's passwords from environment
  variables. Tests: presets round-trip through export and import unchanged, malformed and newer presets are refused
  with clear errors, 24 files copied in slowly (held open, or growing in bursts) all come out once, a held file waits,
  originals move right, an interrupted file never runs twice, the command line's exit codes. Mac: done with E8 (2026-10-30: presets, watched folders, `--batch` and `--watch`; `--fill` with 1.4, 2026-11-03). Still to do: a
  500-file run over a real network share; `--batch` and `--watch` through the alias of an installed package (the pack's
  smoke run starts the app through the alias, with a dev script only).
- **Beat it when:** an action list is saved as a named preset (a plain JSON file, readable and diffable, exported and
  imported); a watched folder runs a preset on each new file once it has stopped growing, moves originals to "done" or
  "failed", and writes a log line per file; no page cap; `InkvoltPdf.exe --batch <preset> <files or folder>` runs the
  same preset without a window and returns a non-zero exit code on any failure; the new actions Save as PDF/A and
  Redact by pattern. Test: a preset round-trips through export and import unchanged; 500 files dropped into a watched
  folder all come out once, none twice, including files copied in slowly over the network.
- **Effort** M. Windows; Mac with Batch.

### 1.3 Accessibility checker (done 2026-10-27)
- **Leader.** Acrobat Pro: Accessibility Check against PDF/UA and WCAG, each rule passed, failed or "needs manual check"
  ([Adobe](https://helpx.adobe.com/acrobat/current/create-verify-pdf-accessibility.html)). The free PAC follows the
  Matterhorn Protocol (31 checkpoints, 136 failure conditions, 89 machine-checkable)
  ([axes4](https://support.axes4.com/hc/en-us/articles/7371943734930)). Why now: US Title II deadlines moved to
  April 26, 2027 (entities of 50,000+) and April 26, 2028 (smaller), WCAG 2.1 AA
  ([JD Supra](https://www.jdsupra.com/legalnews/doj-extends-title-ii-ada-web-2176958/)).
- **Now.** Windows: Review › Accessibility Check… (`AccessibilityCheck`) checks the Matterhorn Protocol 1.1's
  machine-checkable conditions (83 of its 87, 5 of them through another condition, plus PDF/UA's basics: tagged, MarkInfo, PDF 1.x header, tag parents,
  language codes): tags, role map, content tagged or artifact, metadata and title, languages, figures, formulas,
  headings, tables, lists, contents, notes, annotations, links, fields, tab order, media, attachments, layers, XFA,
  security, XObjects, fonts. Each failure has its Matterhorn number, page and element (choosing it scrolls there and
  outlines it), what is wrong and what fixes it; the 48 human conditions are a 15-item checklist in the same pane; the
  report saves as one accessible HTML page; Batch's Check Accessibility action writes it beside each file and fails a
  file with failures. Not checked: 09-007, 09-008 (Ruby, Warichu), 28-018 (a printer's mark's appearance), 31-023
  (veraPDF doesn't check these either); widths of CFF and Type 1 programs. Corpus (`tools/a11y-corpus`, 50 PDFs from Word, InDesign, LaTeX, PDFMaker, PDFlib, Distiller,
  OpenOffice and others, veraPDF 1.30.3): the same pass/fail as veraPDF for 50 of 50 files, the same failing
  conditions for 50 (wcag-table-word, long called a veraPDF inconsistency, was a later object stream PDFsharp missed; see
  the tool's README); veraPDF's own 297 PDF/UA-1 test
  files: 296 of 297 (the other can't be opened by PDFsharp). Mac: done 2026-10-30 (Tools › Accessibility Check…, the sidebar's pane, the
  report, Batch's action): against Windows on the same files, the same pass or fail for 50 of 50 and 296 of 297, the same conditions
  for 49 and 296; the two differences are files Windows' PDF reader reads differently (`mac/docs/PLAN.md`).
- **Beat it when:** a local checker covers the machine-checkable Matterhorn conditions and agrees with veraPDF's
  PDF/UA-1 result on a corpus of 50 files (tagged and untagged, Word, InDesign and LaTeX output); each failure links to
  the page and element, says in plain words what is wrong and what fixes it, and the human-check items are a checklist
  in the same panel; the report saves as HTML; runs in Batch. Test: the corpus result matches veraPDF file by file.
- **Effort** M. Windows; Mac: done 2026-10-30.

### 1.4 Comments and form data in and out (done 2026-10-27)
- **Leader.** Acrobat Pro: export and import comments as FDF or XFDF
  ([Adobe](https://helpx.adobe.com/acrobat/current/importing-exporting-comments.html)), comment summaries, form data
  import and export.
- **Now.** Windows: Review › Export Comments, Import Comments, Summarize Comments; Edit › Forms › Export Form Data,
  Import Form Data, Fill Forms from CSV; Batch actions for the exports and the summary; `inkvoltpdf --fill`.
  Comments (`CommentFiles`): XFDF (ISO 19444-1 elements and attributes; a stamp's appearance as Acrobat's base64
  DICT/STREAM tree), FDF (every annotation as it is, appearance streams included) and CSV, with replies to any depth,
  colors, authors, dates, opacity, borders, line endings and geometry; imported comments without an appearance get
  Inkvolt's own. Import merges by /NM (or, without one, by type, page, place, text and author), lists what it skipped
  and why, and lets in only an allow-list of entries, every value cleaned (no actions, JavaScript, attachments,
  embedded files or external streams, also inside appearances), XML without DTDs, at most 64 MB and 100,000 comments.
  Form data (`FormDataFiles`): XFDF, FDF, CSV and JSON for every field type, values checked against their fields
  (choices, length, required, read-only) and then run through the form's scripts. Merge (`FormMerge`): a filled copy
  per CSV row in a folder, names from a pattern with Batch's tokens and any column, optional flattening; refused rows
  aren't saved and the report (screen and CSV) lists each problem. Summary (`CommentSummary`): landscape sheets, the
  page as it prints at the left, the numbered list at the right, numbers on both joined by a line, continuation sheets.
  Tests: XFDF and FDF round trips into a clean copy keep every comment (type, text, author, color to XFDF's 1/255,
  replies, geometry, style), CSV keeps all but FreeText fonts; exported XFDF validates against the XFDF 3.0 rules
  transcribed into an XSD; Adobe-style XFDF (rich text, replies, ink, a stamp's appearance) imports; every field type
  round-trips in all four formats; a 200-row merge makes 200 forms whose values read back right; failed rows are
  reported per row; DTD, entity-expansion, script, action, attachment and oversized files are refused or cleaned.
  Still to do: the round trip through Acrobat itself (not run here: checked against the spec's rules and Adobe-style
  samples instead); a highlighter pen's blend comes back as a plain pen through XFDF (XFDF has no field for it; FDF
  keeps it). Mac: Export and Import Comments done 2026-11-03 (`CommentFiles`, Tools › Annotate); form data as CSV and
  JSON, Fill Forms from CSV and `--fill` done 2026-11-03 (`FormDataFiles`, `FormMerge`, File › Form Data); Summarize
  Comments (`CommentSummary`, Tools › Annotate) and Batch's exports and summary done 2026-11-03.
- **Beat it when:** comments export and import as XFDF and FDF (replies, colors, authors, appearances of stamps and
  drawings kept) and as CSV; form data exports as XFDF, FDF, CSV and JSON and imports from them, and a CSV of many rows
  fills one copy of the form per row (a merge); Summarize Comments makes a PDF with each page beside its comments, numbered
  and connected. Test: XFDF exported by Inkvolt imports into Acrobat and back with every comment equal; a 200-row CSV
  makes 200 filled forms whose values read back right.
- **Effort** S-M. Windows; Mac: done 2026-11-03.

### 1.5 Redaction check (differentiator, done 2026-10-27)
- **The gap.** A box drawn over text leaves the text in the file; Free Law Project's X-Ray finds only that case
  ([Free Law Project](https://free.law/projects/x-ray/)). A study of 11 redaction tools, Acrobat among them, found that
  removed text can still be inferred from the positions of the characters around it
  ([arXiv 2206.02285](https://arxiv.org/pdf/2206.02285)). No premium app checks a received or produced file for this.
- **Build:** Check Redactions (Review menu, Batch): finds dark boxes, drawn rectangles and black highlight annotations
  with text, images or vector content still under them, redaction annotations never applied, and text covered by
  later content; flags lines whose remaining glyph spacing gives away the removed width; lists each with page and box.
  Our own redaction (1.1) passes it by construction (pages become images). Test: a corpus of bad redactions (boxes,
  highlights, white-on-black, unapplied marks) is flagged 100%, properly redacted files 0%.
- **Now.** Windows: `RedactionCheck`, run after every Apply (with what was redacted) and as Review › Check Redaction…
  and a Batch action (a file with findings fails). Covers: text under dark boxes, highlights and other comments or drawn
  in the color behind it (white-on-black read strictly: any text whose glyphs don't show, found by drawing each
  character), pictures and drawings under dark boxes (drawn again without the box), unapplied Redact marks, text beside
  a box keeping its positions; each with page and box. Leftovers of the redacted text in every other place the file can
  keep it (page text, hidden or off-page content, comments and appearances, fields and XFA, bookmarks, Info and XMP,
  attachments, tags, scripts, unused objects, each earlier incremental version, raw bytes decompressed) and text an
  earlier version showed that the current one doesn't; redacted areas that still show something or hold the original
  picture. Fix redacts, sanitizes and rewrites. With 1.1's patterns it also looks for what they find outside the pages, and
  a part it couldn't search to the end is reported, not read as clean. Tests: the corpus (8 kinds flagged, each properly redacted 0), a value
  planted in each place, an earlier revision, ordinary files 0. 100-page file: 1.2-1.9 s after Apply (Debug build,
  busy PC), in the background (Apply itself unchanged). Mac: done with E1 (2026-10-28) and Batch's action with E8 (2026-10-30). Still to
  do: glyph-spacing inference around pixel redactions.
- **Effort** S. Windows with 1.1; Mac with its redaction.

### 1.6 Store update check (done 2026-10-27)
- **Why.** Store apps update when Windows gets to it, so people can sit on an old version for weeks.
- **Now.** Windows: packaged installs ask the Store (`Windows.Services.Store`) ~30 s after startup and from Help › Check
  for Updates…; a ready update shows in the title bar ("Update required" when mandatory, never blocking reading); Update
  settles unsaved documents as closing does, then the Store installs it. Setting to turn the startup check off; only
  Windows' Store service is asked. Decisions tested with a fake Store (`UpdateCheck`). Mac: the PDF app ships outside
  the App Store and updates through Sparkle 2 (done with D8, 2026-10-28).
- **Effort** S.

## Wave 2

### 2.1 Paragraph text editing
- **Leader.** Acrobat Pro: text reflows inside its box, font, size and color from a panel; but the font must be installed:
  embedded-only fonts allow only size and color, otherwise it falls back to Minion Pro
  ([Adobe](https://helpx.adobe.com/acrobat/using/edit-text-pdfs1.html)). PDF Expert detects paragraphs and keeps font,
  size and opacity ([Readdle](https://support.readdle.com/pdfexpert/edit-pdfs/edit-text-in-pdf-files)).
- **Now.** Part a (Windows, 2026-10-28): a click selects the paragraph (`ContentEditor.GroupParagraphs`: runs on one
  baseline make a line; lines join under DocLayout's rules for Word export, same font, size within 5% and color, at
  most 0.65 em apart at a steady line step, left edges (a first-line indent allowed), centers or right edges lined up,
  split where a line ended short), with its alignment (left, right, centered, justified from three lines) and line
  step. Typing rewraps it in its box, Shift+Enter a line break; the old show operators leave the text position as they
  found it, so text placed after them stays put; the box grows downward, and when it would reach the next text or
  picture below the editor says so live and the app asks before writing. One edit, one undo step, signed files
  appended. Review of part a (2026-10-28): right-to-left paragraphs (rewrapped left to right they'd read backwards),
  paragraphs with other text on their lines (a raised footnote mark, a symbol in another font: it would be left
  behind) are edited line by line; spaces drawn by operators of their own go with the paragraph; a click between the
  lines of a paragraph that can't be edited as one no longer opens its first line. Turned pages, flipped (browser) and
  scaled coordinate systems, Tc/Tz, lines written bottom-up and emptied paragraphs were checked and work.
  Part b (2026-10-28): characters the embedded subset lacks come from the installed font closest to it
  (`StandInFonts`: its own family when installed, Helvetica as Arial, Times as Times New Roman; else 14 common Windows
  families ranked by class (serif/sans/mono from name and flags), weight and slant, then x-height and the widths of the
  characters both have; script fallbacks past those), embedded as a subset (`CidFontWriter`) under `/InkFbN_` names,
  only for those characters, named under the editor; character spacing is 0 inside them and the font, size, spacing
  and rise are set back after. Characters no font here has are still refused by name. Runs in those fonts are part of
  the paragraph when it is read again (a second edit keeps them). Part c (2026-10-28): font (the installed families),
  size, color, bold and italic for a stretch (`TextLook`, `TextSpan`; the editor is a rich text box with a bar above
  it: font list, A−/A+, B, I, six colors and the paragraph's own). Another family, bold or italic is drawn in an
  installed face (same embedding as part b); size changes Tf, color writes rg and sets back the paragraph's own fill
  operators exactly (gray, RGB, CMYK, a named color space; a pattern refuses a color change); each stretch sits in an
  `/InkvoltLook` marked-content sequence holding the family, bold and italic asked for, so the paragraph reads back
  as one with its looks (`TextParagraph.Spans`); a line with bigger text moves down (step = 0.25 of the line above's
  scale + 0.75 of its own), read back as the paragraph's own step. Text typed without looks keeps the looks of what
  didn't change (a character diff; typed letters inside a word take the look before them). Adjacent stretches in one
  font are one operator. Decisions: a styled space at a line's end isn't drawn, so its look goes. The look bar first
  listed the 14 common families only; since 2026-10-30 it lists every TrueType family Windows lists for the machine
  and the user (`StandInFonts.Installed`, from the font registry: "Arial Narrow Bold" is Arial Narrow's bold face,
  weights by name such as "Segoe UI Light" are families of their own, a collection entry gives the font its file
  loads as), and a look in one of them is drawn in it; a family that isn't installed, or whose file isn't TrueType
  (CFF OpenType), falls back to the closest ranked font as before. Stand-ins for characters the font lacks still come
  from the ranked 14. Tests: `ParagraphEditTests` (41, with
  `ParagraphEditTests.Looks`); on the export corpus (opt-in, `INKVOLTPDF_CORPUS`) the longest paragraph of each of 8
  files' first 3 pages took 20 more words, all re-extracted in order, no unreported overlap. A single run on one line
  still uses the one-run editor; since 2026-10-30 it draws characters the font lacks from the same stand-in fonts
  (`ContentEditor.Plan` returns a `RunPlan`: the changed middle split into stretches in the run's font and stretches
  shaped in a stand-in, written by `WriteLine`; `TextCheck.Borrowed` and `StandIns` name them under the editor;
  characters no font has are still refused by name). Part d (2026-10-30): text inside form XObjects edits as
  paragraphs and as single runs (`ContentEditor.Forms.cs`: each run inside a form knows its form, its operator in it
  and the Do that draws it; the edit rewrites the form's own stream, stand-in fonts go to the form's resources or the
  page's when it borrows them; a form the page draws more than once or that other pages share is copied for the Do
  clicked, under `/InkFmN`; a form drawn through another form edits only when nothing in its chain is shared;
  pictures inside forms stay as they were; a paragraph half in a form is edited line by line).
  `ParagraphEditTests.Forms` (9). Hyphenated line ends (2026-10-30): a hyphen typed into a word stays as typed
  ("respon-sible" is one word, joined without a space and never split at the hyphen); a soft hyphen (U+00AD) ending a
  line was added by the line break and is dropped (`ParagraphEditTests.Lines`). Kerning (2026-10-30): the TJ
  adjustments the paragraph's own text carried between two glyphs of a word (not word gaps, at most 0.25 em) make a
  table by pair of codes (`ContentEditor.Kerning`, `TextParagraph.Kerning`), and rewritten lines get the adjustment
  back wherever the pair occurs, so edited lines are set as tightly as untouched ones; the one-run editor does the
  same for its changed middle from the run's own pairs. Pairs the original never had get no kerning (the font's own
  kern table isn't read). The pdf.js half of the test below (2026-10-30): `pdf/tools/pdfjs-check` (Node, `pdfjs-dist`
  from npm, Apache-2.0; its README) prints what pdf.js reads from a page, and `ParagraphEditTests.PdfJs` (opt-in,
  `INKVOLTPDF_PDFJS`, skipped without Node) edits the test's own pages (each alignment, a form XObject, stand-in
  characters, a one-run edit) and, with `INKVOLTPDF_CORPUS`, the corpus's first three pages, adding as many of 20
  words as fit without running into the next block, and checks pdf.js reads the whole paragraph's words in order and
  the added ones together: all 6 sample pages and 15 corpus pages read in order (6 pages had no room under their
  longest paragraph). Acrobat isn't on this PC, so its half isn't run. The corpus check itself now finds the
  rewritten paragraph by its text (with kerning kept, the first rewritten lines land exactly where the old ones were,
  which it used to mistake for other text). Mixed-face paragraphs from other software (2026-10-30): lines join when
  their fonts are faces of one family (`FontNames.Family`: Word draws a bold word in "Calibri,Bold" beside
  "Calibri"), the paragraph's own font is the face most of its text is in (`PlainRun`), and a run in another face of
  the family reads back as a bold or italic span; typed again, such a stretch, or new text given bold or italic, is
  written in the page's own face when the paragraph has one (`PartLook.Page`: encoded in that font, its widths,
  its /Widths and ToUnicode extended as needed) and only otherwise in an installed face; the operator's own font is
  set back after the lines. A word in another family still blocks the paragraph (edited line by line), and a line
  that begins with another family doesn't join at all. `ParagraphEditTests.Mixed` (3). Turned text (2026-11-04):
  runs of one direction (within half a degree; at most 16 directions a page, those with the most runs) are turned
  upright about the page's origin (`ContentEditor.Turned.cs`: each run's reach along and across its baseline,
  `TextRun.Reach`, gives it its own upright box there; mirrored or slanted text has none and stays line by line),
  grouped, checked and laid out there as upright text is (`TextParagraph.Upright`), and the lines' starts turned back
  onto the page; `Lines`, `Box` and `Below` are their bounding boxes, `TextParagraph.Angle` the direction, and a click
  between its lines is tested in its own direction. The writing is unchanged (a line's start goes back into the run's
  own text space). The editor is laid out in the paragraph's direction and turned about its first line's start, the
  look bar and note beside where it is. `ParagraphEditTests.Turned` (6: 90°, -90°, 180° and 30° reflow, running into
  the next block, a sideways column beside an upright one); pdf.js reads the 90° and 30° samples in order; dev script
  (a sideways column, 20 words added): the editor turned over the column, 4 lines to 5, the next block where it was.
  Mixed families (2026-11-04): a line is the paragraph's when most of its text is (`PLine.Lead` is the line's
  `PlainRun`), so a line that begins with a word in another family joins; text in another family of the same size
  and color is part of the paragraph (only another size or color on its lines still edits it line by line), read
  back as a span of that family (`TextLook.Font`), and written again, typed letters too, in the page's own font for it
  (`PartLook.Page`, as for a bold face of the family; its widths and ToUnicode extended as needed), never an installed
  one when the page has it. `ParagraphEditTests.Mixed` (4 in place of the two that expected a block: a Times word mid-line, typed into, a line
  that begins with it, another size still line by line); pdf.js and the corpus paragraphs read as before; dev script
  (Helvetica with two Times words, one starting a line): one paragraph of 4 lines, 9 words added, both words still in
  Times. The standard Symbol font not embedded (2026-11-04): read through Symbol's own encoding (`GlyphNames.InSymbol`,
  so "a" in it is α) and measured with Windows' Symbol (`SystemFonts.Program("symbol.ttf")`, whose widths are Adobe's;
  the euro at 160, which it lacks, is 750), a word in it is part of the paragraph, typed letters too
  (`ParagraphEditTests.AWordInTheStandardSymbolFontNotEmbedded…`). The standard ZapfDingbats not embedded (2026-11-06):
  Windows has no twin of it (Segoe UI Symbol's dingbats are other shapes), so it stays in ZapfDingbats, read through its
  built-in encoding and measured with Adobe's own data (`ZapfDingbats`: the Core 14 `ZapfDingbats.afm` and Adobe's Zapf
  Dingbats glyph list, unmodified in `Core/Fonts` with the AFM licence, which `THIRD-PARTY-NOTICES.md` repeats); a word in
  it is part of the paragraph, a typed ✔ too (`ParagraphEditTests.AWordInStandardZapfDingbatsNotEmbedded…`). PDF/A's
  Segoe UI Symbol embedding reads its characters from the same table (`PdfA.DingbatUnicode`). MuPDF reads such a font by
  its own glyphs, not as the characters (before and after an edit alike).
- **Beat it when:** a click selects the paragraph (lines joined by `DocLayout`, as Export to Word does); typing reflows it
  inside its box with the paragraph's alignment and line spacing, and the box grows downward or warns before it
  overlaps what follows; characters the embedded subset lacks come from the installed font closest in metrics and
  class (named in the panel, never silently), and the rest of the paragraph stays in its own font; font, size, color,
  bold and italic change for a selection; text inside form XObjects edits too. Test: on the export corpus, 20 words
  added to a paragraph re-extract in order, nothing overlaps the next block, and the page opens in Acrobat and pdf.js
  with the same text; a file whose fonts aren't installed is still editable (where Acrobat isn't).
- **Effort** L. Windows done but for the Still to do above; the Mac has the line-level editor only, and this is still to do there.

### 2.2 Better OCR
- **Leader.** ABBYY FineReader PDF: about 190 OCR languages ([Wikipedia](https://en.wikipedia.org/wiki/ABBYY_FineReader)),
  preprocessing (deskew, noise, straightened lines, trapezoid correction)
  ([ABBYY](https://help.abbyy.com/en-us/finereader/12/adjustimage)). Acrobat: suspect words shown beside the image and
  corrected in place ([Section 508](https://www.section508.gov/training/pdfs/aed-cop-pdf04/)).
- **Now.** Stage A on Windows (2026-10-30, branch `t3/pdf-ocr-deskew-suspect-words`). Recognize Text cleans each page before Windows'
  recognizer reads it (shared `Imaging/ScanCleanup`, beside Inkvolt Print's `Deskew` and `PageRotate`): straightened up to
  ±15°, sideways and upside-down pages turned upright, a 3 × 3 median, the paper evened out to white, lone specks
  removed; the cleaned page can replace the scan (off by default; one undo step with the text). The language is chosen
  among the installed OCR languages. **Suspect words** are listed beside their picture in a pane and corrected in place
  (or kept as read); the text layer is written again, so search finds the correction. Windows' `OcrWord` has only its
  text and box, no confidence, so suspect words are a documented heuristic, never a score: not in Windows' spell checker
  for the language, letters and digits mixed inside, odd characters, or read as a different real word on the scan as it
  was (`SuspectWords`). The engine is behind `ITextRecognizer` (Windows' today), so a second one is another
  implementation. Measured on a generated corpus (`pdf/tools/ocr-corpus`, six files, English and Spanish, skewed 3-10°,
  noisy, shaded, two pages turned): the word error rate is lower than today's on every file, 1.8% → 1.3%, 16.9% → 12.9%,
  5.4% → 3.8%, Spanish 44.9% (12.8% with Spanish chosen) → 8.0% and 41.3% (5.1%) → 4.3%, turned pages 99.9% → 3.7%
  (its RESULTS.md). Lines the recognizer skips (2026-11-03): Windows' recognizer now and then leaves out a whole line
  that is plainly on the page; `ScanText` finds the cleaned page's ink no word covers, in line-sized bands that look like
  type (not specks, rules, blocks or pictures, nor beside a word read on the same row), reads each again alone (at most
  12 places and 60 readings a page; what a place leaves unread is read word by word), and puts the words in reading
  order. Recognize Text and Redact by Pattern both read through it. The corpus's scans have no skipped line (numbers
  unchanged, 10-25 ms a page to look); on the page it skips two lines of (`skipped-lines`), 39.1% → 21.7%. **"1111"**
  (2026-11-04): what made it skip them is four 1s in a row, which Windows' recognizer never reads (alone or in a line, any
  size, margin or font tried: Helvetica, Times, Courier 9-18 pt) and for which it leaves out the whole line; one 1 alone it
  never reads either, and two not always, three always. So a run of four strokes or more alike and evenly apart, left
  unread, is read three strokes at a time and kept when each reading is three digits (`MissedLines.ReadOnes`):
  `skipped-lines` 21.7% → 8.7% (what is left: two commas). **A word left out inside a line that was read**
  (2026-11-04): unread ink on a read line's row, a word's gap clear of the words beside it (not the rest of a word read
  short), as tall as a digit, is read alone and kept only as plain words or numbers (`MissedLines.FindInLines`; at most
  16 places and, with the rest, 60 readings a page). The six scans are unchanged (the words they lack inside lines are two
  words read as one, "journeyxletter", not words left out); on `probe --count 18` (36 pages, 14,108 words) 752 → 747
  edits, 7 words found, no page worse. **Suspect words for Batch, Scan and export** (2026-11-04): Batch's Recognize Text
  action (window, watched folders, `--batch`), File › Scan and Insert from Scanner, and the exports' OCR mark suspect
  words as Recognize Text does when its "Mark suspect words to check" is on (it reads each page a second time as
  scanned); Batch and Scan keep them in the text layer with its language, so the Suspect words button shows when such a
  file is opened (`TextLayer.HasSuspectWords`) and they are reviewed there; Batch's notes and Scan's message count them;
  an export, which has no text layer to review, counts them in its message. All of them read as Recognize Text is set,
  cleaned or as scanned too (`AppSettings.OcrClean`; `PageOcr.AsSet`, export through `PageRecognizer.Page`, 2026-11-04).
  A page whose lines don't say which way up it is
  (2026-11-03) is read both ways and turned over only when that reading has clearly more real words (two, or a quarter
  more); digits count neither way, so a page of numbers (`digit-lines`, the redaction corpus's third page, read "OO 6830
  9999 9999 9999" turned over before) stays as it is. Still to do: the second engine (Tesseract) for languages Windows lacks and mixed languages per page,
  "make the text editable", straightened lines and trapezoid correction (ABBYY's). Mac: stage A done with E14 (2026-11-02,
  `mac/docs/PLAN.md`), with Apple's Vision as its recognizer; the page-of-numbers rule (`clearlyMore`) ported 2026-11-04;
  Vision skips no line on the corpus (`VisionProbeTests`), so the re-reading of missed lines isn't needed there. Suspect
  words for Batch, Scan and export on the Mac too (2026-11-04, E14a): Batch (window, watched folders, `--batch`) and
  export read with Recognize Text's choices (`PageOcr.recognizer(_:options:spelling:)`), Batch keeps the marks and the
  language in the text layer and notes the count, exports count them, Scan already ran Recognize Text's pipeline, and a
  file opened with suspect words lists them (`TextLayer.hasSuspectWords`, the `/PdOcr` check first). "1111" with Vision
  (`VisionProbeTests.visionOnFourOnesInARow`): read in every line with words, every font and size, as scanned and
  cleaned; only lines of nothing but 1s and card digits on cleaned Times at 9 and 12 pt are left out (or "1111" read
  "M11"). That isn't Windows' problem (it reads no line that holds four 1s), so `MissedLines.ReadOnes` isn't ported.
- **Beat it when:** pages are deskewed (±15°), turned upright, despeckled and their background cleaned before recognition,
  optionally written back as the cleaned image; a second, local engine (Tesseract, Apache-2.0, 100+ languages;
  [tessdata](https://github.com/tesseract-ocr/tessdata)) is an optional download for languages Windows lacks, with
  mixed languages per page; low-confidence words are listed beside their image and corrected in place, the text layer
  updated; "make the text editable" turns a page's recognized text into real text in a matching font (for 2.1).
  Test: on a scan corpus (skewed 3-10°, noisy, two languages) the word error rate is lower than today's on every file,
  and a corrected word is found by search.
- **Effort** L. Windows; Mac: stage A done with E14 (2026-11-02; Vision does the languages).

### 2.3 USB scanners (WIA, TWAIN)
- **Leader.** Acrobat: scans through TWAIN or WIA (Windows) and Image Capture (Mac), presets, deskew, background removal,
  descreen ([Adobe](https://helpx.adobe.com/acrobat/using/scan-documents-pdf.html)). PDF-XChange keeps knowledge-base
  articles on scanners its 64-bit build can't find ([PDF-XChange](https://www.pdf-xchange.com/knowledgebase/all/search?q=tag:WIA)).
- **Now.** Windows (2026-10-30, branch `pdf-usb-scanners`). File › Scan and Insert from Scanner list scanners with a
  Windows (WIA) driver beside the eSCL network ones, labelled "(USB · Windows driver)", through the WIA layer Inkvolt Print
  already scans with (`shared/…/Wia`: `WiaScanner` over `WindowsWia`, `wiaaut.dll` late bound, no package): glass, feeder,
  both sides where the driver offers duplex, color, grey or black and white (the driver's threshold type), the offered
  resolutions, Letter, A4, Legal or the whole area; a feeder stack scans until the driver says the feeder is empty, into
  one PDF with the OCR text layer as eSCL scans get. Windows' own eSCL driver for a network scanner already listed is left
  out. 64-bit TWAIN sources are listed too when the TWAIN 2 manager (TWAINDSM.dll) is installed, through the same device
  interface (`WindowsTwain`: native transfer, the source's own window never shown); without it, a line under the list says
  so. Leave out blank pages (on by default; Inkvolt Print's `BlankPage`), and presets: Save as preset… keeps source,
  color, resolution, page size, OCR and blank choices, matched to whichever scanner is chosen (`PresetPlan`). Tests with a
  fake WIA device (`UsbScannerTests`: a feeder of 10, duplex with blank backs, a flatbed; the plan, the PDF, blank pages,
  presets, error words, the TWAIN model). **Hardware:** this PC's one WIA scanner is Windows' eSCL driver for an HP Color
  LaserJet MFP M277 that is no longer on the network: listed, and connecting said "The scanner isn't answering…"; no page
  has been scanned through a real WIA or TWAIN driver (no USB scanner, no TWAIN manager here), so the acceptance test (a WIA
  flatbed and a WIA feeder scanner, 10 pages each) is still to run. Scans are straightened and cleaned (2.2) before OCR
  reads them; the scan itself is kept as scanned (only Recognize Text writes the cleaned page back). Mac: File › Scan uses
  ImageCaptureCore with the feeder, both sides and OCR, leaves out blank pages (2026-11-06, PrintCore's `ScanRun`), saves
  scan presets (`ScanPresets.fromChoices`, `PresetPlan`) and lists the scanners Inkvolt Print remembers first (its hand-off,
  `ScannerList`).
- **Beat it when:** WIA 2 scanners (and 64-bit TWAIN sources) are listed beside eSCL ones in the same dialog with feeder,
  duplex, color and dpi; blank pages are dropped on request; every scan goes through 2.2's cleanup and OCR; scan presets
  are saved. Test: a WIA flatbed and a WIA feeder scanner each scan a 10-page stack into one PDF, OCR included.
- **Effort** M. Windows; Mac: done 2026-11-06 (scanning through ImageCaptureCore, blank pages, presets, Inkvolt Print's scanners).

### 2.4 Tags, reading order, alt text, PDF/UA
- **Leader.** Acrobat Pro: Autotag in Adobe's cloud (headings, borderless tables, nested lists, multi-column reading
  order), a reading order tool and tag editor ([Adobe](https://helpx.adobe.com/acrobat/using/cloud-auto-tagging-accessibility-pdfs.html));
  reviewers note that sending the file to a server is itself a risk ([Apryse](https://apryse.com/blog/auto-tagging-pdf-ua-compliance)).
- **Now.** Windows (2026-10-30, branch `pdf-accessible`). **Make Accessible** (Review menu, command palette, Batch;
  `AutoTag`): `DocLayout` reads the pages as for Export to Word into a tag plan (headings, paragraphs, lists, tables
  with a bold first row as column headers, pictures and vector charts, running headers and footers; a sideways margin
  stamp is never a heading, a bold numbered "3.1 …" line is a heading at its depth), then each piece of page content
  goes in BDC/EMC with an MCID (never across BT/ET, q/Q or other marked content) or becomes an artifact (running
  headers, footers and page numbers as Pagination artifacts, rules and backgrounds), and the structure tree follows
  the plan: Document › H1-H6 (evened out: the first H1, none skipped), P, L › LI › LBody, Table › TR › TH (Scope
  Column) / TD (ColSpan), Figure (Alt, Layout BBox), Link (text and OBJR, Contents from its text), Form and Annot for
  fields and comments; ParentTree, MarkInfo, Lang (a passage clearly in another language gets its own), title (asked:
  the metadata's, else the first heading), DisplayDocTitle, Tabs S on every page, pdfuaid in the XMP, PDF 1.7, the
  standard Latin fonts embedded as PDF/A does, Symbol/Wingdings bullets with ActualText; existing tags are replaced
  (alternate text kept by place); one undo step, a signed file's edit appended. **Reading order pane**: the page's
  pieces numbered in the list and as boxes on the page, moved by drag or Alt+Up/Down, alternate text typed, Decorative,
  or suggested by the user's own vision model through `AiClient` after the "what is sent, where" window (an OpenAI
  vision request: the picture and the text near it), Apply changes re-tags. **Save as PDF/A-2a** (File menu, Batch):
  `PdfA` at level A keeps the tags, needs a language, keeps pdfuaid with its extension schema. Tests: `AutoTagTests`
  (20: each tag kind, MCIDs and the parent tree, title/language/tab order/identifier, heading levels, reading-order
  moves, decorative pictures, alternate text round trip and re-tagging, links, PDF/A-2a, Batch and presets, the vision
  request). **Corpus** (`tools/a11y-corpus`, `run.ps1 -Tag`, veraPDF 1.30.3; figures given a stand-in alternate text):
  the corpus has 2 untagged files, both pdfTeX papers: after Make Accessible both pass every condition but 31-027
  (glyphs of the TeX math fonts without Unicode), veraPDF agreeing (7.21.7-1 only). It has no untagged Word file, so
  12 Word and office files were tagged with their own tags replaced: 5 pass veraPDF PDF/UA-1 outright (Word 2016, Word
  365, a letter, a résumé, a PDFMaker test document), the other 7 fail only on what tagging doesn't touch (form-field
  tooltips 28-005, fonts 31-009/014/030), same result as the checker for 12 of 12. PDF/A-2a: the Word files pass
  veraPDF 2a and ua1; the pdfTeX paper (tagged in the app, 5 pictures given alternate text in the pane, one marked
  decorative) fails both only on the same math-font glyphs. **Part 3** (2026-10-30, branch `pdf-accessible-2`):
  the **Pro gate** (`ProFeature.AutoTagging`, `ReadingOrder`, `AccessibleOutput`: Make Accessible, the pane's moves and
  Apply, PDF/A-2a, in Batch through `BatchStep.Feature` and `BatchPlan.Validate`; viewing stays free; enforcement off);
  **Unicode for glyphs without it** (`FontUnicode`, `TexGlyphs`: a ToUnicode from TeX's glyph names and the OML/OMS/OMX
  math encodings, the Adobe Glyph List's Greek and math names, empty CFF glyphs as spaces; also at PDF/A-2a); **more
  tag kinds** (`AutoTag.Kinds`): Caption (in its table, beside its figure), Note with an ID, TOC › TOCI nested by
  indent, Formula with its text as alternate text, nested lists (L in the item's LBody), TH Scope Row, two header rows
  under a spanning header, words-over-numbers headers, a table that doesn't look like one (`PlausibleTable`) read as the
  chart's figure or as paragraphs, labels beside a figure part of it; **the pane**: pieces read with the page before or
  after (`MoveToPage`, `TagBlock.ReadWith`, Alt+Page Up/Down), Page Up/Down for another page's pieces, Enter/F2 to the
  alternate text and Esc back. Tests: `AutoTagKindsTests` (16), `FontUnicodeTests` (31), `ProTests` (+2), `AutoTagTests`
  (+1). **Corpus** (veraPDF 1.30.3, `run.ps1 -Tag`): checker and veraPDF give the same pass/fail on 50 of 50 files (the
  same conditions on 49; wcag-table-word's 15-003 as before); the 2 untagged pdfTeX papers now **pass PDF/UA-1** after
  Make Accessible in both (11 and 30 formulas, 6 footnotes each, their figure and table captions); the 12 re-tagged
  Word and office files: 5 pass, 7 fail only on form-field tooltips (28-005) and fonts (31-009, 31-014, 31-030), the
  same as the checker on 12 of 12 (the NIST standard's contents as 17 TOC, 55 entries). Save as PDF/A-2a of those 14:
  10 made, all 10 pass veraPDF 2a and ua1 (both papers, the NIST standard, the Word files); 4 refused as before (a
  signature, CMYK without a profile twice, a Times that would move). **Part 4** (2026-11-04): **forms tagged piece by
  piece**: a form XObject with text that the whole document draws once (`AutoTag.Write`'s `CountForms`, through forms
  drawn by forms) has its own content marked inside it, each piece in its own element, with MCIDs of its own under its
  StructParents and MCRs naming it (/Stm); its Do stays outside any marked content; a form drawn more than once is
  still one piece where it is drawn (a stream can hold one set of MCIDs). `AutoTagFormTests` (3: a heading and two
  paragraphs inside one form, a form two pages share, re-tagging). veraPDF 1.30.3 passes PDF/UA-1 on the form page
  tagged by `A11yCorpus tag`; `run.ps1 -Tag` as before (50 of 50 the same; 2 of 2 papers pass; 5 of 12 office files
  pass, the other 7 on 28-005 and 31-009/014/030). **A piece's kind in the pane**: a
  Kind list under the pieces (`AutoTag.KindsFor`, `AutoTag.WithKind`; a Pro fix as moving is): any piece a paragraph,
  heading 1-6, caption, footnote, formula or picture, a list or contents either of those two; text kinds take all its
  content (a list's entries, a table's cells row by row, a line each), a picture is everything in its box and needs
  alternate text, a picture made text keeps its area (pictures there become decoration); nothing is made a table or a
  list from a paragraph (their cells and entries aren't known). `AutoTagKindChangeTests` (4: paragraph to heading 2,
  list to paragraph, text to picture and back, table to paragraph); dev script `rokind` (a paragraph made heading 2 is
  read as Heading 1 after evening out, a line made a picture asks for alternate text). **Row spans**: in a ruled table a cell
  without a rule under it across its columns, over a cell of the same columns, spans that row too (`DocLayout`'s
  `TableFromGrid`: `DocCell.RowSpan`, the rows it covers keep a `Covered` cell with what was drawn there, so the
  exports are as before); Make Accessible gives the cell what its covered cells hold (text centered in a tall cell
  often sits in a lower row), writes RowSpan in its Table attributes and leaves the covered cells out; a row header
  over two rows heads both; header rows are told from the cells as drawn, a column header's span stops at the last
  header row, and a row all covered by the cells above is no row of its own (review, 2026-11-04). Borderless tables have no row spans yet (nothing marks them). `AutoTagRowSpanTests` (6:
  a header over two header rows and a row header over two rows, read, written and checked; Word's table unchanged).
  veraPDF 1.30.3 passes PDF/UA-1 on that table tagged by `A11yCorpus tag`; `run.ps1 -Tag` as before; export corpus: the
  same Word pages for 7 of 7, PowerPoint opens every slide, 3,617 of 3,641 HTML lines in order as before. **Unicode
  for Type 3 bitmap fonts**: a Type 3 font whose glyphs are named by their codes ("a65", "g65", "C65", or in hex "G41"
  for four in five of its named glyphs, as dvips and Ghostscript write TeX's PK fonts) gets a ToUnicode from the codes
  (`FontUnicode.CodeNamed`, `TexGlyphs.CodeText`): by the TeX font its name gives (OML, OMS, OMX for the math fonts,
  ASCII for the typewriter ones, OT1 for the rest of Computer Modern: ligatures, quotes, dashes; the italics' sterling
  at 36); a name that says nothing (dvips's "Fa") gets nothing, since a symbol font's codes are other glyphs and wrong
  text is worse than none (review, 2026-11-04); glyphs numbered in drawing order ("g1" at 65) are left alone. Also at
  PDF/A-2a. `FontUnicodeTests` (+13). veraPDF 1.30.3 passes PDF/UA-1 on a CMR10 bitmap sample after Make Accessible (31-027 before). Glyph pictures
  aren't read (no recognizer on them), so a bitmap font without a TeX font's name stays as it was.
  Still to do: Acrobat and PAC checks of the output (neither is installed here). **Mac: done (2026-10-30)**: Make Accessible, the Reading Order and Alt Text pane with its keyboard path,
  Save as PDF/A-2a, Batch's actions, the same Pro gates; veraPDF on what the Mac writes from the same 14 corpus files gives
  Windows' results on all 14 (PDF/UA-1: 2 of 2 papers pass, 5 of 12 office files pass, the other 7 on the same rules;
  PDF/A-2a: 10 made, 4 refused for the same reasons, all 10 pass 2a and ua1). Alternate text suggested by a vision model
  came with the Mac's AI assistant (E11, 2026-10-30). **Part 4 on the Mac (2026-11-05):** Unicode for Type 3 bitmap fonts (`FontUnicode`, `TexGlyphs.codeText`; FontUnicodeTests +4, the same names); forms tagged piece by piece (`AutoTagWrite`'s `mark`, `usesOfForms`; AutoTagFormTests, 3); row spans (`DocLayoutTables.tableFromGrid`, `AutoTagKinds.withRowSpans`, `withoutCoveredRows`; AutoTagRowSpanTests, 6); a piece's kind in the Reading Order pane (`AutoTag.withKind`, the Kind pop-up; AutoTagKindChangeTests, 4).
- **Beat it when:** Make Accessible tags an untagged PDF on the PC from `DocLayout` (H1-H6, P, L/LI, Table/TR/TH/TD with
  header scope, Figure, Artifact for running headers and page numbers), sets title, language and tab order; a reading
  order panel shows the order as numbered boxes, reordered by drag; alt text is typed per figure, or suggested by the
  user's own vision model (sent only after the usual window); output passes veraPDF PDF/UA-1 on the 1.3 corpus after
  the human checks; Save as PDF/A-2a. Test: 1.3's checker and veraPDF both pass on the corpus's untagged Word and
  LaTeX files after Make Accessible plus alt text.
- **Effort** L. Windows; Mac done 2026-10-30.

### 2.5 What's in this PDF (differentiator, Windows done 2026-10-28)
- **The gap.** Acrobat's sanitize step removes hidden data when redacting
  ([Adobe](https://helpx.adobe.com/acrobat/current/removing-sensitive-content-pdfs.html)), but no app gives one readable
  report of what a file carries and what it would do when opened.
- **Build:** a report (Properties, before Sanitize, and in Batch) of: scripts and what they call; actions that run on
  open, print or close; every web address and whether it is contacted without a click (remote GoTo, submit, URI on
  open); attachments; metadata and authors per object; earlier revisions recoverable from incremental saves (with the
  text that changed); hidden layers, white or off-page text; form values; the 1.5 redaction check. Saved as HTML or
  JSON. Test: a corpus with each item planted reports all of them; Sanitize afterwards reports none.
- **Now.** Windows: Review › What's in This PDF… (`DocumentInventory`, also from Document Properties and the Sanitize
  dialog, and Batch's Report What's in Each File). Scripts with their trigger and what they call (web, mail, submit,
  network, files, print, timers, eval); actions that run on open, close, save, print, page open and close, or field
  display (navigation to a page left out); every URI, Submit, Launch, GoToR/GoToE, ImportData target, address inside a
  script and external stream, marked "no click needed" when automatic or on pointer enter/exit; attachments (name tree,
  attachment comments, /AF); Info, XMP (document, pages, pictures, fonts), PieceInfo, comment authors with pages, article
  properties; signatures (name, date, reason, location); earlier revisions and the text they show that the current one
  doesn't; hidden layers, hidden comments and fields, white and off-page text; form values; covers that hide nothing (the
  redaction check's own findings, its echoes left out). Each item says whether Sanitize removes it. HTML (no scripts) or
  JSON (format marker, version, fields in a fixed order). Tests (`DocumentInventoryTests`): Sanitize's planted corpus with
  an appended revision lists every planted item, and after Sanitize with everything the report is empty; white,
  off-page and boxed text; automatic, pointer and click triggers; signatures; script calls; HTML and JSON; Batch. The
  Mac: done (2026-10-28, with E1's Sanitize; Batch's action with E8, 2026-10-30).
- **Effort** S (most of it is Sanitize's scan). Windows; Mac with Sanitize.

## Wave 3

### 3.1 Translate side by side (bring your own AI)
- **Leader.** Foxit: AI translate keeping layout, original and translation side by side, 25+ languages, in Foxit's cloud,
  credits per month ([Foxit](https://www.foxit.com/ai/pdf-translator/)). PDFelement: side by side or interleaved, 35-50
  languages, scans through OCR ([Wondershare](https://pdf.wondershare.com/online-pdf/ai-pdf-translator.html)).
- **Now (Windows, 2026-11-01; a real model from 2026-11-02).** The real model is Qwen3 4B (Q4) on llama.cpp's llama-server on
  this PC's GPU, 8,192 tokens of context. Its results are under **Real model** below; the rest was checked with a stand-in
  server. Review › AI Assistant › Translate with AI: free, as the table says, so
  no `Pro` check. `Translation.MakePlan` reads the pages, nothing sent: each page's paragraphs by 2.1's grouping
  (`ContentEditor.Translate.cs`), table cells apart by Export to Word's analysis (`DocLayout`), repeats once, paragraphs
  with no words not at all. The "what is sent, where" window shows every request. `TranslateAsync` sends them one at a
  time (a paragraph too long for the model's context in pieces). `Apply` writes the copy from the original's bytes, each
  page in one pass over a document kept open (reopening it per paragraph, as an edit does, would take the square of the
  length). A paragraph wraps in its box and may use the white space below it; next it shrinks in steps of 5%, down to half
  its size or 5 points; if it still doesn't fit it is written there and gets a comment. So does a paragraph left untranslated,
  with why. When the page's font lacks a letter, the whole paragraph is drawn in the closest installed font (a subset
  rarely holds a translation's letters; 2.1's letter-by-letter stand-ins would read like a ransom note), once per face in
  the file. Chinese and Japanese wrap between characters, a word wider than its box breaks, right-to-left text is
  shaped whole line by line against the right edge. The copy gets the language's `/Lang`, opens as an unsaved tab, and the
  original goes in the split view's second pane on the left (`ShowBeside`), scrolling and zooming with it. Progress and
  Cancel come from `ProgressPrompt`; stopping offers the part done as a copy.
  Decisions: text the editor refuses (mixed fonts, right-to-left, a raised mark on its lines) is translated here, since all of it
  is replaced: a bold word or a superscript inside a paragraph loses its look, and a raised mark joins the text sent. A
  bullet of its own stays where it is. A line comes apart at a gap over 1.5 ems or where its size changes. A single line's
  alignment comes from its place on the page or in its cell. White text stays in its box (past it, on a band we can't see,
  it would vanish). Text stays inside a rectangle that clips it and a form's `/BBox`, off pictures, figures, rules and form fields.
  A page with more than 20,000 pieces of text is left as it is and named, which is a cap per page, not on pages or size.
  A stopped run's unreached paragraphs get no comment each: the summary names their pages.
  Limits: scans (the words are in a picture; OCR's invisible text isn't rewritten) and text turned other than by a quarter
  turn (a stamp at 30°, mirrored or slanted text) stay and are named. Text
  in a hidden layer is neither sent nor rewritten.
  Comments, form fields, bookmarks and text in pictures aren't translated. A filled panel with no outline doesn't hold
  its text in; a clip that isn't one rectangle isn't followed; a paragraph clipped line by line comes out flagged, not
  fitted. Thai has no spaces, so it wraps between any two characters. A file's size can grow as with any edit: PDFsharp
  writes compressed objects out plainly (census-p60, 1.8 MB to 8 MB). Paragraphs with `/ActualText` stay and get a comment.
  **The bug a real run found (2026-11-02).** The first real page (NIST p. 9) reported 14 paragraphs in Spanish, and all
  the lines after each first line were specks. Text extraction read them, at the right size. That page paints a white band
  under each line just before drawing it, and all the new lines were written where the first old line was, so the later
  bands painted over them: the specks were descenders. All the tests passed because they read text, and the corpus only
  asked whether a page's pixels had changed at all. Now a new line is written where the lowest old line it reaches was
  drawn, and text doesn't grow under a rectangle filled later. `TranslationInk` renders each line of a copy and measures
  its ink (height and how much of the line has any); the tests, the 100-page report (each of its lines now on a white band)
  and the corpus use it.
  **Other faults the real runs showed, fixed.** A font that named no glyph for a code passed as having it when `/ToUnicode`
  and `/Widths` covered the code (pdfTeX's do), so accents came out blank ("funci n"): a readable program now decides. A
  spot color's "1 scn" was read as white, holding headings to their old box and shrinking them. "NimbusRomNo9L" and
  "Gotham-Book" got stand-ins of the wrong class. Small capitals fell apart at each change of size, and the model got "IGITAL".
  A short line going on in lowercase split a sentence in ragged columns, and a note's small number split a note's first line
  from the rest. Short labels one under the other were joined; figures beside a label moved into its text. A tight
  clip shrank headings; text could grow past the clip of its last line. A link starting a line split its paragraph and turned
  the text blue. A turned stamp in the margin made full lines look centered. A word in another script in a Latin-letter
  answer (the model wrote "sean要么 editoriales") is asked for again, then left out and flagged. The shrink floor went by a
  paragraph's first run, which may be a mark.
  **Real model.** Spanish, through the app with screenshots read side by side, and `TranslationRealModelTests` (opt-in) for
  what each paragraph got: NIST p. 9, 13 (a ruled table), 14, 20, 47 (a table); attn-v7 p. 3, 8 (a table); census-p60 p. 7 (three
  columns), 12 (a figure's table), 31 and 33 (turned tables). A page of text took 17 to 48 seconds with this model and GPU. All lines
  show, in their boxes, and figures and rules stay. No reasoning tags or preamble reached a copy; the model wrote none on these
  pages, so that part of `CleanReply` wasn't exercised by it. What it gave back unchanged on NIST p. 9 is "NIST SP 800-63-3" and
  "vi" (the 4 first seen included pieces of small capitals); on p. 47 and the census, "AAL1", "NO", "90th/10th" and the like.
  How good it reads: for a 4B model, good. The meaning is carried and a reader can follow it, with care on technical terms.
  Wording faults are the model's, not bugs: "Cuartil cuarto", "Las ingresos", "Errata" as "Errores", "GUIAS" without its
  accent. One whole document was only counted, not read through (attn-v7, 15 pages, 12 minutes).
  **Fixed (2026-11-06).** A row whose label and figures one operator draws (a TJ with wide adjustments: attn-v7's "Transformer
  (base model) 27.3 38.1", the census's "income inequality 0.488 0.485", resnet's tables) comes apart at its columns: the
  walk makes a run of each column from the glyph advances it computes (`ContentEditor.ColumnStarts`), told apart by the one
  rule `SplitAtColumns` also uses between operators (`ColumnGap`: over 1.5 ems, or over 0.6 ems beside figures and
  well beyond the operator's own word spacing, so pdfTeX's justified "results from 1999" stays one sentence). Only the label
  is sent; the other columns are drawn again as they were, each from where the one before it left the text position. In
  the corpus's first pages: table rows, author lists, numbered headings ("3.1 | Encoder and Decoder Stacks") and a list of
  figures ("Figure 1. | Median Household…"); a sentence's "]." before a stretched space doesn't split.
  White text on a dark band filled right under it (nothing painted between) uses the band's width (NIST p. 14's
  "Propósito" keeps its size); on a light card, a picture or a stroke it stays in its box.
  Checked again with the real model (Qwen3 4B Q4, llama-server, 8,192 tokens) on attn-v7 p. 8, census-p60 p. 12, NIST p. 14
  and resnet p. 6, in 8-100 seconds a page: every figure of the four tables is in its column, model names and "90th/10th"
  come back unchanged, nothing of the model's own reached a copy.
  Fixed after that run (2026-11-06), checked by applying its saved answers again and by the corpus's plan texts: a line
  opening with a bracket or quote pdfTeX draws on its own ("(i.e.", "[32]") is no longer taken for a bullet, so its
  paragraph keeps its left edge and its last line after a hyphen ("(classi-" / "fication and box regression [7]).", resnet
  p. 10; 13 such lines in the corpus's first 20 pages of each file); a short label ending in a colon stays apart from the
  short row under it (the census's second "Income percentile ratios:"); a centered label with free room on one side moves
  into it before it shrinks, and an operator's column no longer counts the gap to the next column among its word spaces
  (resnet's "error top-1" and attn-v7's "Transformador (modelo base)" keep their size); a column's body paragraphs take one
  size, the one its most shrunk paragraph needs, no smaller than 80% (attn-v7 p. 8's body all at 8.47 pt).
  **Turned text (2026-11-06).** Text set sideways or upside down (the census's appendix tables, a landscape table on a
  portrait page) is translated: each quarter turn the page's runs read in (within half a degree) is turned upright in the
  frame Export to Word turns a page by (`TranslationFrame`, `ContentEditor.TurnedParts`), its tables' rows and columns
  found there from that direction's lines with the page's rules (`Surroundings`), and its paragraphs grouped, given their
  room and fitted there as upright ones are; each new line's start is turned back onto the page and written in the run's
  own text space, so it reads as before. Upright tables are now found from upright lines only (a sideways table's cells,
  in their own frame, could land among them). `TranslationTests.A_table_set_sideways_is_translated_cell_by_cell…`; on
  census-p60 p. 31 and 33 (stand-in answers) every label, heading and note is translated, figures stay in their columns,
  nothing is named as turned. A multi-line row label in such a table ("AMERICAN INDIAN / AND ALASKA / NATIVE ALONE OR / IN
  COMBINATION") goes as one paragraph a line, upright or turned alike (its lines sit on the figures' rows).
  **Links and underlines (2026-11-06).** A link on a translated paragraph's lines moves onto its words where the
  translation keeps them as they were (an identifier, a document number: "(SP) 800-63A,", "SP 800-63C,"; spaces don't
  count, so a line's "800-" "63A," finds "800-63A,"), a copy of the link for each further line they reach, and its
  underline is drawn again under them (its distance from the baseline and thickness scaled with the text, its color); a
  link whose words were translated is taken off the page and out of the structure tree (what they became can't be
  told), with its underline (its painting operator ends the path unpainted) (`ContentEditor.TranslateLinks.cs`:
  `LinksOfWritten`, `Follow`, `FixLinks`, run by `TranslationWriter.Finish` once the copy's fonts are in it, so the new
  words can be read). A turned paragraph's links are dropped, its underlines left. `TranslationTests.A_links_area_and_underline_follow…`,
  `A_link_whose_words…`; NIST p. 14 with stand-in answers: all five link areas and underlines on their words ("SP" at a
  line's end and "800-" on the next, two areas). `PdfObj.AppendContent` (Flatten's) draws the underlines.
  Review (2026-11-06): a link's underline is only one rectangle filled in a plain color within the link's width; any
  other mark under the words (no link's, a stroke, a spot color, two links' underlines in one operator) stays as drawn.
  The underlines are blanked in the same step that moves the links, after the page is read again (a page that can't be
  keeps both as they were). A link is looked for only in its own paragraph's new lines, at the place nearest where it was;
  two places as near drop it. `Follow` tries only new words that can start the stretch.
  **A label alone on its row (2026-11-06).** The only cell with text on a table's row takes the empty cells after it
  (`Translation.CellsOf`), so a label heading the rows under it grows to its right rather than shrinking in its
  column (the census's first "Income percentile ratios:", which shrank to the floor: it keeps its size with stand-in
  answers on p. 12); a rule between them still stops it. `TranslationTests.A_label_alone_on_its_row_grows_into_the_empty_cells_beside_it`.
  **Looks (2026-11-06).** A bold or italic word, a subscript and a superscript keep their look ("d_model", "h_t−1",
  "x_1", a footnote's raised mark, the census's bold names, the W-9's italic titles). A run in another face than the
  paragraph's own (bold or italic where it isn't; its family kept when that is another, as LaTeX's are), or smaller
  than its line's text and 0.08 em below or 0.12 em above its baseline, is a stretch (`ContentEditor.TranslationLook`);
  the request carries the stretches as `<b>`, `<i>`, `<sub>`, `<sup>`, nested in one order, and asks the model to keep
  them around the words they mark (`TranslationMarkup.Mark`; the text so marked is the answer's key). The reply's tags
  are read in one pass (`TranslationMarkup.Read`, linear, at most 528 tags) and trusted only when they are ours,
  balanced, properly nested (none inside itself, never sub and sup together, three deep at most), name only looks the
  paragraph had, and cover about as much (per look at most twice the stretches plus one, the longest at most twice the
  paragraph's longest plus 12 letters, 4 for scripts, a share of the letters at most twice its share plus a tenth); a
  tag dropped leaves only its words plain. Any other reply is written plain, every tag, piece of one and angle bracket
  taken out (`CleanReply` already drops other tags). The copy draws a look in the page's own face for it (`/FB`
  beside `/FA`), or, when any face lacks a letter, each face's text from the installed font closest to it ("Arial",
  "Arial Bold"); a sub- or superscript at 0.7 of the size, 0.15 em lower or 0.35 em higher (`Ts`, stand-ins too:
  `CidFontWriter.Emit` takes the rise). Characters no font has are left out with the looks staying on their words.
  `TranslationLooksTests` (37: markup out and back, 13 replies that can't be trusted, crafted replies of 1.2 MB of
  tags, the page's own faces and installed ones, a superscript, a reply in plain halves). Export corpus with stand-in
  answers (`TranslationCorpusTests`): 216 texts of 2,082 sent marked (attn's "d<sub>model</sub>", resnet's
  "W<sub>i</sub>"), no tag on any page, the ink check's counts as before (3, 1, 9, 0, 0, 42, 0); pdf.js reads the copies'
  words in order.
  **Still wrong.** Looks a stretch can't carry: a word in another color or family that is neither bold nor italic (a
  name in Times among Arial, code in a monospace font), an underline, a regular word in a bold paragraph, a
  superscript of more than four characters set on its own band (it isn't part of the paragraph's lines). A paragraph
  goes plain when its text has angle brackets of its own, more than 64 stretches, needs more than one request (a piece
  could cut a stretch's tags apart; a cut-off answer is asked for in plain halves too), or is written right to left.
  The sizes and rises are fixed, not the page's own, and a superscript doesn't widen the line step. LaTeX's math
  italic ("d" of "d_model", CMMI) isn't read as italic. attn's section titles (NimbusRomNo9L-Medi) come out regular in
  the installed font, as before. Not checked with a real model: how often a small one keeps the tags. The model's,
  not bugs: a term translated three ways on one page ("bottleneck" as "boquilla", "botella" and left as is; "shortcuts" as
  "acortes" and "atajos"), "Transformer" kept in one paragraph and "Transformador" in the table, one of two column heads
  translated ("error top-1" beside "top-5 err."), an identifier changed ("SP 800-63A" as "DE 800-63A"), and "Table3shows"
  (the source's own missing space) kept.
  **Checked.** `TranslationTests`, including the test below on 100 made-up pages through a real
  socket to a stand-in server on 127.0.0.1: 100 pages kept, each figure in the same place to 0.01 pt, every paragraph
  written, the original's bytes unchanged, every connection from loopback, a redirect not followed (a second local
  server got nothing and the run stopped). Hostile replies through the real `AiClient`: endless answers stopped by length,
  keep-alives forever by the deadline (three in a row stop the run), silence, several paragraphs for one (asked once more,
  then left and flagged), control and direction-override characters, private-use characters, broken surrogates, markup,
  an answer cut at the model's limit (asked in halves), a refused key, a busy server (retried), a body that can't be read.
  Crafted PDFs: 30,000 runs on a page, 19,000 paragraphs on a page, a million characters in one operator, forms drawing
  forms 60^8 times (cut short at 64 MB and named, and cancellable), coordinates that overflow to infinity (an endless loop
  found in review), unreadable content, a font with nonsense widths. The real app driven with `--script` and looked at:
  all 100 pages to a stand-in on a real socket, the Send window, progress with the UI answering, Cancel and keep
  (376 paragraphs left, pages named), both panes scrolling to the same place from either side; the menu command and its
  window with the Ollama preset and no network (`aifake translate`) on f1040. `TranslationCorpusTests` (opt-in, `INKVOLTPDF_CORPUS`) on the 7
  export corpus files, first 30 pages of each, 99 pages, each answer longer and marked: page counts and pictures kept, no
  page failed, read and written in seconds. That stand-in lengthens every label, so its counts of what doesn't fit (about a
  tenth of paragraphs) say little about a real translation; the ink check's few lines it still names are at the size floor or in a chart.
  The real app driven again on an AES-256 file opened with its permissions password: the open password asked before anything
  is sent (the reading window used to come up over that question and take the keyboard; it now waits), the copy opened beside it.
  **Not checked.** Any other model, a cloud endpoint, or a language but Spanish with a real model; a model's refusal in words,
  or an answer to the text in place of its translation, can't be told from a translation. A screen
  reader on a copy: a paragraph's new lines sit in the tagged pieces of the old lines they reach. Acrobat and pdf.js on a copy. Long runs over
  sleep and Wi-Fi drops (a failed connection is retried, then the run stops and offers what it has; tested with a fake, not a
  real sleep). The interface is in English or Spanish (3.7).
- **Beat it when:** translation runs through the user's endpoint (Ollama, LM Studio, or their key), paragraph by
  paragraph, with the usual window showing what is sent; a translated copy keeps each paragraph in its box (2.1's
  reflow, text shrunk to fit and flagged when it can't), tables cell by cell; the two documents scroll together; no
  page or size cap. Test: a 100-page report translated with a local model keeps page count and figure positions, every
  paragraph translated, nothing sent beyond localhost.
- **Effort** M (after 2.1). Windows; Mac still to do (its AI assistant came with E11, 2026-10-30; 2.1 first).

### 3.2 Export to PowerPoint and HTML
- **Leader.** Acrobat exports to PowerPoint and HTML, with "retain page layout" or flowing text
  ([Adobe](https://www.adobe.com/learn/acrobat/web/convert-pdf-retain-page-layout)).
- **Beat it when:** PowerPoint: one slide per page at the page's size, text as editable text boxes in reading order,
  pictures as pictures, simple shapes as shapes, slide titles from headings; HTML: one file, reflowing, with real
  headings, lists and tables from `DocLayout`, pictures embedded, alt text from tags, valid HTML5 with no external
  requests. Test: export-corpus runs open in PowerPoint and LibreOffice with no repair prompt; the HTML passes the W3C
  validator and reads in order in a screen reader.
- **Effort** M. Windows; Mac: done with E15 (2026-11-02).
- **Now.** Windows done 2026-10-30: File › Export (and the command palette, Batch, presets, the command line through
  presets). PowerPoint: `PptxWriter`, one slide per page; a presentation has one slide size, so it is the size most pages
  have and pages of another size are shrunk and centered. Each paragraph is an editable text box where the page has it, a
  list one box with real bullets, the page's first top heading the slide's title (a running head never), tables are
  tables, pictures are stored once, sideways lines are turned boxes. `ExportShapes` tells lines, rectangles and ellipses
  apart by looking at a rendering, since MuPDF gives only a path's bounds; any other path stays as it looks, a picture. A
  slide's order is its reading order. HTML: `HtmlWriter`, one file that reflows: headings that never skip a level,
  nested and numbered lists, tables, pictures as data with the tags' alternate text (`ExportTags`), the running header
  and footer once. Everything from the PDF is escaped; no script, link or request, with a Content-Security-Policy too.
  **Checked** (`tools/export-corpus`, 7 real documents, 174 pages): every .pptx passes the Open XML SDK's validator and
  opens in PowerPoint (16.0, on this PC) with every slide and shape it was written with; every
  .html passes the W3C's Nu validator (run locally) with no errors, has no active content, and 3,617 of 3,641 lines
  read in the plain-text export's order. Word's page counts are unchanged.
  **Not checked yet:** LibreOffice (not installed on the PC that ran this: `run.ps1` runs it when it is) and a real
  screen reader (the order test reads the file's order, which is what one follows).
  **Known:** slides don't keep a font that isn't installed: a wider one wraps sooner, so
  dense forms come out crowded (the Word export's limit too). Links aren't carried over, in either format.

### 3.3 Compare: Office files, scans and formatting
- **Leader.** ABBYY (Corporate) compares a Word file or a scan with a PDF, OCR in the background; it ignores formatting
  ([ABBYY](https://help.abbyy.com/en-us/finereader/16/user_guide/overview_compare)). Acrobat reports text, fonts,
  images and page order ([Adobe](https://helpx.adobe.com/acrobat/current/compare-documents.html)).
- **Beat it when:** either side can be an Office file (made into a PDF by the installed Office, as now) or a scan (OCR
  first); font, size, color and style changes are listed apart from wording; moved paragraphs show as moves; shifted
  or skewed scans are aligned before the visual overlay; the annotated copy includes visual differences. Test: a
  contract and its edited .docx with 30 planted changes (wording, moves, bold, size) lists all 30, none extra.
- **Effort** M. Windows; Mac with Compare (the compare itself came with E3, 2026-10-30; Office files, scans and
  formatting are still to do there).
- **Now.** Windows done 2026-10-31. Either side can be an Office file (Word, Excel, PowerPoint through the installed Office,
  with the same checks as opening one), a picture of a page or a PDF. A page whose pictures cover 70% of it is a scan; one with
  no text is recognized first (Windows' OCR, skippable), and its text gets no formatting changes. Font, size, bold, italic and color
  changes are listed apart from wording, moved passages as moves with the edits inside them as their own changes, running
  headers and footers left out, each kind with a box to hide it (`CompareLooks`, `CompareMoves`, `CompareScan`). Scans are lined up
  for shift and skew before the overlay (`CompareAlign`, from each page's lines and where the ink falls; used only when the ink
  agrees better). What looks different besides the words is listed and in the annotated copy, with moves and formatting.
  **Checked:** `CompareContractTests`: a contract and its edited .docx with the 30 planted changes (8 changed, 5 inserted, 5
  removed, 4 moves, 8 formatting) made into PDFs by Word 16 list all 30, none extra; the PDFs are in the tests' `Data`, so CI runs it
  (`INKVOLTPDF_WORD` makes them again). The app compared the two .docx files through Word and listed the same 30. The edited
  PDF against a synthetic scan of itself (200 dpi, turned 1.3°, shifted) found 1.3° and the shift to a tenth of a point.
  **Not checked:** a real scan. **Known:** on that synthetic scan Windows' recognizer skipped a whole line, listed as removed and
  marked as maybe misread, and lost one "."; re-reading the bands with ink but no words is queued in `docs/HANDOFF.md`. A scan
  isn't lined up when scanned at another size or a quarter turn off.

### 3.4 Long-term validation for signatures
- **Leader.** Acrobat: Add Verification Information stores revocation data (DSS) after signing, and timestamped
  signatures with revocation are LTV-enabled ([SSL.com](https://www.ssl.com/how-to/long-term-validation-ltv-of-pdf-digital-signatures-in-adobe-acrobat/)).
- **Beat it when:** signing embeds OCSP/CRL responses for the whole chain (DSS/VRI) and can add a document timestamp
  (PAdES B-LT, B-LTA); Add Verification Information works on any signed file; DocMDP and FieldMDP are enforced when
  verifying. Test: Acrobat shows "LTV enabled" and the EU DSS validator reports B-LTA for our signed files.
- **Effort** M. Windows; Mac with signatures (verifying and signing came with E2, 2026-10-30, DocMDP and FieldMDP enforced
  as on Windows; the long-term data is still to do there).
- **Now.** Windows done 2026-10-31. Sign Digitally can store OCSP answers or CRLs for the whole chain and its timestamp's (/DSS, /VRI)
  and add a document timestamp (B-LT, B-LTA). Add Verification Information does it to any signed file as incremental updates, the earlier
  bytes as they were and each signature re-verified before the result is handed back; a signature with no timestamp takes two document
  timestamps, one for its time and one over the data, which is what EU DSS asks. Signatures followed only by such data still read as valid.
  Pro: adding the data (`ProFeature.LongTermValidation`); free: verifying, the level shown, and Check Signatures Online, which asks without
  changing the file. Going online happens only through `LtvClient`, after a window listing every address and what it gets: https for the
  timestamp server in the field, Sectigo's free one unless the person enters another (the http DigiCert default is gone; the real Sectigo answered and its timestamp verified, `INKVOLTPDF_REAL_TSA`), the certificates' own OCSP, CRL and issuer URLs as they name them,
  nothing private, loopback or link-local by name, by DNS answer (checked on the connection made) or by redirect, no proxy, 15 s and a
  size limit per request. **Opening a signed file used to go online by itself** (revocation, and Windows fetching missing issuers from what
  a file's certificates name, a way for a file to probe the local network): it no longer does, and signing no longer does either.
  DocMDP and FieldMDP were enforced as said; added: every FieldMDP reference counts, a locked field's appearance, other properties or a new
  field of its name count as changes. A hostile /DSS (wrong shapes, loops, zip bombs, thousands of entries, forged answers) reads as no data.
  **Checked:** `LtvTests` against a generated CA with a local OCSP responder, CRLs, issuer certificates and RFC 3161 server, none of it needing
  the internet. EU DSS 6.5.1 run locally and offline (`tools/pades-check`, opt-in `INKVOLTPDF_PADES_CHECK`) reports PAdES-BASELINE-LTA, TOTAL_PASSED,
  for B-LTA signing, Add Verification Information on a B-B file and on a no-changes certification, CRLs only, and a delegated responder;
  PAdES-BASELINE-LT, TOTAL_PASSED, for B-LT; and -B and -T for the plain ones. The real app, driven with `--script` against the local authority,
  added, checked and signed, its files reading B-LTA (`The_real_app_adds_checks_and_signs`). No file went to an online validator.
  **Not checked:** Acrobat's "LTV enabled" (Acrobat isn't on this PC; `tools/pades-check` says how, by hand). Real certificate authorities and
  timestamp servers: every run was against the generated one, so a real CA's OCSP answers older than a fresh timestamp (issued ahead by a CDN) are
  handled only as far as "still in force at that time" in our own check; EU DSS may ask for a later one. Smart cards.
  **Certifying with fields locked**, Windows done 2026-11-03 (Pro, `ProFeature.FieldLocking`; the gate stays off): the Sign dialog's "Lock form
  fields" (when certifying a form) locks all fields, the ones chosen, or all but those. The signature gets a FieldMDP reference after its DocMDP
  one (/Data the catalog, /Action, /Fields, /V /1.2), the signature field a /SigFieldLock /Lock saying the same, and the locked fields the
  read-only flag; a field's own /Lock is honored beside it (a reference each). The verifier reports a later change to a locked field as not
  allowed ("locked field "Name""), and to an open one as allowed. **Checked:** `FieldLockTests` (the dictionaries against ISO 32000-1 Tables
  233, 253, 254, 256; a locked and an open field changed after each of the three choices); EU DSS 6.5.1 (`tools/pades-check`) reports
  PAdES-BASELINE-LTA, TOTAL_PASSED, for a form certified with a field locked and then given long-term data. **Not checked:** Acrobat's view of
  the lock.
  **Batch's long-term action**, Windows done 2026-11-03 (`AddLongTermStep`, same Pro gate; presets save it as `addLongTermData`
  with its `timestampServer`): Add Verification Information on each signed file, with checks, reports and exports only.
  The window lists every address the signed files would ask before the run (the command line: `--online`); the run has one
  `LtvClient`, one file at a time, each file the request budget a single file has (`NextFile`); an answer is used again for
  the next file and a server that didn't answer (time out, no connection) isn't asked again, so a batch can't hammer it.
  Per file: no signature, already long-term (no copy), offline (`BatchHost.IsOnline`), couldn't reach the service; the
  originals as Batch keeps them. **Checked:** `BatchLongTermTests` (a mixed batch, B-LTA, offline and unreachable, cancel,
  oversized and garbage replies, presets, the command line); EU DSS 6.5.1 reports PAdES-BASELINE-LTA, TOTAL_PASSED, for a
  batch's second file, whose answers came from the first's. **Not checked:** many files against a real authority; the
  app's watched folders don't go online (their files fail "may not go online").
  **Still to do:** the Mac. Encrypted files are refused, since `Incremental` can't append to them.

### 3.5 Indexed folder search
- **Leader.** Acrobat Pro's catalog: a full-text index (.pdx) over a folder, searched in Advanced Search
  ([Adobe](https://helpx.adobe.com/acrobat/current/creating-pdf-indexes.html)).
- **Beat it when:** a folder is indexed in the background (a local file beside our settings), kept current as files
  change, OCR text included; results with context, opened at the hit; accents and case ignored as Find does. Test:
  10,000 PDFs indexed once, a word query answered in under 1 s, a changed file found again within a minute.
- **Effort** M. Windows; Mac still to do (Spotlight covers part of it there).
- **Now.** Windows done 2026-10-31: Edit › Search Folders… (Ctrl+Alt+Shift+F, the command palette), Pro (`ProFeature.FolderSearch`; the gate stays off). No new
  dependency: a small inverted index of our own, one file per folder in the data folder's `FolderIndex` (`FolderIndex`): terms to pages, each page's text compressed, written
  only at the end, a commit at a time, flushed before its footer, so a crash leaves the last commit; compaction writes a new file. Terms fold what Find's own comparer reads alike,
  asked of the comparer (`IndexTerms`), and a word is found inside longer ones; the index only proposes pages, Find runs on the kept text and has the last word, so no search opens a PDF.
  Only **index workers** parse PDFs (`IndexWorkers`, the find workers' pattern, below normal priority, 2 GB each); `FolderIndexer` keeps it current by the system's change notices and a look every 30 s.
  OCR text layers are indexed; no OCR runs, and a scan with no text is counted and said. Damaged, password-protected, over 512 MB or 50,000 pages, over 2 minutes of processor time, or crashing a worker twice:
  skipped, counted, listed, read again when it changes or with Rebuild.
  **Checked** (`tools/bench`, `index-make`, `index-run`; Surface Laptop 7, Snapdragon X, on battery, other work running; Release): 10,000 PDFs and 6 bad ones (72,797 pages, 149 MB, 200,400 terms) indexed from nothing in 158 s
  (146-158 s in three runs; **not explained:** a fourth took 569 s and a fifth was stopped when it slowed to a few files a second, with workers idle and processors free, single pages taking 0.5-2 s by the clock; Windows holding back low-priority work on battery is the guess, unproved), a 154 MB index file, the app at most 179 MB. Word queries to the last result listed: 3-114 ms, the worst
  a one-letter query at 219 ms; the first query after opening 84 ms (target 1 s, met). A changed file found again in 3.4 s, three times out of three (target a minute, met); opening the index 27 ms. The Release app on that corpus: indexed with the window answering in at most
  35 ms, paused and resumed, a result opened at its hit, a new file found. Tests: every byte offset of a commit cut (`FolderIndexTests`), a writer killed 8 times mid-commit (`FolderIndexerTests`), workers dying, hanging, spinning and running out of memory
  on a file, a folder going away. **Missed, not part of the target:** a phrase of two words common but rarely side by side took 3.2-4.1 s to list 500 pages (first result 14-20 ms; every page has to be read).
  **Not checked:** real-world PDFs at this scale (the corpus is generated), a real hostile PDF (a worker's death is simulated), a network drive, a disk filling up. An MSIX install indexes and searches a folder in the pack's smoke run (`smoke-msix.ps1`), passed with 1.5.0. **Cloud drives:** real Cloud Files placeholders are tested on a sync root the test makes, on this PC, with no provider running (read when on the PC, counted and left alone when only in the cloud, a sub-folder included). Of OneDrive itself only one folder on one PC was measured, its 7 PDFs listed, all on the PC already: a file only in OneDrive's cloud has not been seen staying there, nor Dropbox or Google Drive at all.
  **Known:** a moved file is read again; the text of a changed file stays in the index file, shown by no search, until the next compaction (within about 2 minutes). The Mac's half is still to do.

### 3.6 Speed on huge files (differentiator)
- **The gap.** Acrobat users report freezes on 200-500 page files and on large drawings, and Adobe staff suggest
  leaving continuous scrolling ([Adobe Community](https://community.adobe.com/t5/acrobat-discussions/acrobat-becomes-very-slow-when-i-open-large-pdf-files-200-pages/td-p/15579541)).
  No vendor publishes numbers.
- **Now.** Windows: the benchmark is in (`tools/bench`, see its README): a deterministic corpus made on the PC (a
  5,000-page text in four standard fonts, a 500-page 300 dpi JPEG scan, a 1 GB drawing set of 400 sheets with 72,000
  paths each, 250 pages with 10,000 comments and replies), measured at Core level three times in fresh processes, the
  medians against the targets in [tools/bench/RESULTS.md](tools/bench/RESULTS.md); `scrollbench` in the dev script
  times the on-screen scroll; `BenchTests` keeps the generator and harness working. First run (2026-10-30, Surface
  Laptop 7 with a Snapdragon X, a busy PC): first page 0.06 s (text), 0.27 s (scan), 0.35 s (comments); 10,000 comments
  listed in 0.79 s; 4, 37 and 12 ms per page scrolling those three, 73–75 fps in the app with no blank page. The
  speed work since (second run the same day, branch `speed`, same busy PC): Find runs as one search on two threads in
  page order and remembers each page's text for the document's lifetime (whole for pages with little text); a file of
  256 MB or more opens in place and its bytes are read only when needed, with a name scan so the panes skip PDFsharp
  when the file has nothing for them; big renders run in four strips on cloned contexts; the viewer shows a small
  preview of a page before its full render. Drawing set: first page 1.47 s to 0.47 s, peak 2.08 GB to 0.16 GB, no sheet
  blank 200 ms after the scroll stops (was 2), a second search a millisecond. Still missed: Find across 5,000 pages
  9.7 s (was 12.8 s), the drawing set's 20-page scroll proxy 848 ms a sheet (was 1,597; the 72,000 paths cost per path,
  not per pixel, so a preview still takes a few hundred ms) and its first Find 164 s on that run (106 s in a quieter
  moment; about 250 ms a sheet of MuPDF parsing the paths for a text pass that ignores them). Threads in one process
  can't take these further: MuPDFCore's native wrapper guards MuPDF's allocations with process-wide mutexes (four
  instances use four times the CPU of one for no gain), while four processes run four times as fast. So (third run,
  2026-10-30, decided with the owner) a long Find reads text in **find workers** (`Core/FindWorkers.cs`,
  `PdfEngine.Find.cs`): the app started again with `--find-worker` and a per-launch pipe name, no WPF on that path. Find
  across 5,000 pages 2.71 s (9.64 s before, run straight after on the same PC), target met; the drawing set's first
  Find 31.7 s (106 s); the app with its workers at most 0.87 GB, against 1.5 GB. A search starts on its two threads and
  starts workers when its pace, from 200 ms on, says over 2 s is left and 16 pages or more (about 1,000 pages of a
  text); up to eight, two cores left free, 100 MB each within half the free memory and 1.2 GB. A worker that fails, can't
  start or stalls for 2 minutes loses nothing: its pages go to the threads, with no message. Workers end with the
  search, on Cancel, with the engine and with the app, even a crash (a Job Object, and a watch of the parent in the worker).
  A file with a password stays in process, so no password crosses a pipe; a PDF in memory is shared through a section
  with no file behind it, and nothing is written to disk. Formats other than PDF stay in process. The Store smoke test
  searches in workers. The drawing set's scroll stays over target (761 ms a sheet): a display list kept per sheet
  doesn't change that, as the engine already keeps 32 and painting is three quarters of the cost (581 ms again against 761 ms
  the first time), so that idea was dropped. **Mac (E16, 2026-11-02):** `mac/tools/bench` makes the same corpus and
  measures (RESULTS.md, on the M1 Air, to be run again on the M6 Mac mini): MuPDF instances don't wait on each other there, so
  Find reads pages on threads in process (`PdfEngine.findAll`, every core but one, no workers): 5,000 pages in 0.55 s, the
  drawing set in 6.9 s (33.5 s before); one copy of a file's bytes for all of an engine's instances took the drawing set's
  peak from 2.6 GB to 1.3 GB. Still over target on the Mac too: the drawing set's scroll (584 ms a sheet) and its Find.
  **A hostile file's time: MuPDF's own inflating, bounded by time (Windows, 2026-11-05).** PDFsharp's filters are bounded
  (`BoundedFilters`, 256 MB a stream); MuPDF's inflating kept memory flat but not time: a 7 KB page Flate twice to 4 GB
  took 52 to 116 s of one core to draw, a 1 MB one Flate once to 1 GB 13 s, a 20,000 × 20,000 picture of 1.2 MB 9 s a
  draw (MuPDF reads a picture's samples only up to its width × height: a 10 × 10 one of 1 GB, milliseconds). MuPDF's
  abort cookie can't reach it: the page's content is read while the display list is made, and MuPDFCore 2.0.1's wrapper
  passes no cookie there and exports nothing of MuPDF's own; nor does MuPDF look at a render's cookie while it inflates
  a picture. So (option A's fallback, the owner's choice over the rejected `InflateGuard` pre-scan) a page is first
  drawn small, every picture decoded, in a **page check** (`Core/PageChecks.cs`, `PdfEngine.Checks.cs`): the app
  started again with `--page-check`, killed after 10 s (about 30 times a drawing-set sheet's 0.3 s), the page then
  refused with a note in the viewer and a reported empty page in exports, blank in print; Find, the other pages, text and
  export go on. Every path that runs a page's content waits for its check once (render, save as image, text, Compare,
  export, redaction's picture boxes, Find in process); Reduce File Size checks a picture of over 64 M samples first. In
  the app the 7 KB page says so within 14 s, its neighbours draw, Find finds the rest (`PageCheckTests`, the dev script).
  Cost (bench `one`, single runs on a busy PC, `INKVOLTPDF_BENCH_CHECKS=0` for without): drawing set first page 0.53 to
  0.96 s, scroll proxy 1,068 to 1,167 ms a sheet, Find 32.9 to 34.0 s; text first page 0.09 to 0.24 s (the check
  process starting), 5.8 to 9.6 ms a page, Find 2.78 to 2.74 s; two check processes of about 50 MB each, not in the
  peaks above. A sheet drawn back to back costs about twice (0.45 to 1.0 s): its check (0.3 s in process) competes for
  the same cores. Not covered: a document with a password (no secret crosses a pipe) and formats other than PDF run
  unchecked; a document a check process can't open runs unchecked; the folder index's workers keep their own 2-minute
  limit a file; the Mac (done 2026-11-06, in process: below).
  **Its review (2026-11-05):** a check whose drawing MuPDF gave up on (damaged, or past the process's 2 GB) refuses the
  page instead of passing it on to be drawn here unlimited; a picture of over 4,096 × 4,096 is also decoded at its full
  size in the check (the small drawing decodes a JPEG at an eighth, a JPEG 2000 at its smallest level: a 30,000 ×
  30,000 JPEG passed, then cost 900 M pixels in an export or a deep zoom), one too big for the 2 GB refused. When no
  check process starts (the program missing, an antivirus holding it past 15 s), pages run unchecked (failing open, as
  before page checks: failing safe would leave every document blank on that PC), nothing is kept of it, and a start is
  tried again after 30 s, doubling to 5 minutes. Starting a check process and ending it can't cross any more (one
  ended while it started opened a closed file). Only the document the user opens checks its first page as it opens
  (not an engine opened for page sizes, a password or a thumbnail; a thumbnail checks its one page in the shared
  process); a page asked ahead is withdrawn with the page it was asked for when that is scrolled past. Both processes
  open one shared copy of a document.
  Export as images, Batch's page images and Read Aloud leave a refused page out and say so; Reduce File Size measures a
  soft mask by its picture's rule. Bench `one` after it (single runs, the PC at 50 to 100% from other work): text first
  page 0.25 s with checks (0.07 without), 9.1 ms a page (5.6), Find 2.7 to 3.0 s (2.7); drawing set first page 1.03 s
  (0.58), scroll and Find within the load's noise (1.1 to 1.7 s a sheet, 36 to 61 s either way); scan first page 0.21 s
  (0.07), 27 ms a page (25). To measure again on an idle PC.
  **Its second review (2026-11-05):** no verdict is carried to another engine any more (`PageIdentity` removed: PDFsharp's
  view of a page vouched for what MuPDF would read, two parsers a hostile file can make disagree; a refusal stuck
  whatever the edit changed; every edit hashed the document): an edit's, undo's or Reload's engine checks each page
  again when it is first drawn. Measured (5 notes each, median, PC at 93%): the first draw after an edit 33 ms with
  checks (14 without) on a text page, 1.54 s (0.99) on a 72,000-path sheet. Only MuPDF running out of the check
  process's memory refuses a page (`PageChecks.OutOfResources`: a picture to decode of more than half of its 2 GB, or
  the process past half of it during the check); a page MuPDF reads in part (it warns and draws what it can) is drawn
  as before. An image's own soft mask, which MuPDF's structured text doesn't list, is decoded at its full size too
  when over 4,096 × 4,096 (`PageMasks`: found through PDFsharp in the check process, documents up to 64 MB, only to
  decode more); the pictures it does list (patterns, forms, comments) come from the drawing's display list, 40 to 48
  ms after the 270 ms drawing of that sheet. A check process that fails to start leaves its page to the other one;
  pages run unchecked only when none runs. A document closed just before its check process opens it no longer ends
  that process. Bench `one` after it (single runs, the PC at 45 to 100%): text first page 0.27 s (0.08 without), 11 ms a
  page (5.4); scan first page 0.33 s (0.08), 28 ms a page (29); a 2.7 MB scan, its masks read, 0.28 s (0.06); drawing
  set first page 1.03 s (0.78), 0.98 s a sheet (1.09), Find 33 s (35).
  **The drawing set after page checks (2026-11-06).** Where a sheet's time goes (one core, PC at 30 to 70% from other
  sessions): MuPDF making its display list (reading the 72,000 paths) 190 to 350 ms; the text from that list 40 to 60
  ms; drawing it at 1,200 px 750 to 1,500 ms on one thread, about half that on four strips; the check's 64 px drawing
  110 to 280 ms, almost as dear as a large one (anti-aliasing costs per path, not per pixel). Before, every sheet's list
  was made twice (the check, then the render) and drawn twice. Now (`PageChecks`, `PdfEngine.Checks.cs`) a render
  waiting for its page's check gets the check's own drawing of the whole page at its scale (after the check as before,
  from the list just made, up to 8.4 MP, only of the size asked), and the next two pages are drawn ahead, one in each
  check process, so sheets come in pairs; the check's small drawing was unsmoothed (215 to 93 ms a sheet; undone by the
  review below); the viewer asks at once for the
  full render of a page its check draws (`PdfEngine.CheckDraws`), with no preview first that would leave the full render
  to make the list again on the one view lane. The bomb tests stay green: the check itself is unchanged. Bench `run` (the
  PC at 25 to 30%, other sessions idle; RESULTS.md): first page 1.01 s to 0.81 s on one run and 1.03 s (runs of 0.77,
  1.0, 1.0 s) on the next, still on the line: a check process already running (as after the start page's thumbnails)
  takes 0.15 to 0.35 s off; scroll proxy 969 to 524 ms a sheet; frames with a blank page on screen 214 of 238 to 165 of
  241, a page still blank 200 ms after the stop (1, as before; 2 on the run before the viewer change); the same pages
  again 742 to 923 ms (their lists are in the check processes now). Find 38.4 to 29.5 s, its code unchanged (the
  load's noise): it is MuPDF's list making, 80% of a sheet's text, and MuPDFCore 2.0.1's wrapper extracts text only
  from a display list (no text-only device, no page run without one); eight processes sustain about 13 sheets a second
  here (one alone, 4), so 400 sheets take some 30 s. Still missed: Find (a text-only reading would take MuPDF's own
  entry points, which the wrapper doesn't export, or a content reader of our own, which the review ruled out for
  disagreeing with MuPDF), the scroll proxy (no sheet's list and drawing fit in 200 ms on one process), and a page blank
  after the stop.
  **Its review (2026-11-06):** the picture is only a shortcut: it must never make a fine page fail, weaken the guard or
  leave a page blank longer. The check process now sends the verdict first, then draws the picture within its own 1.5 s
  (`PageChecks.PictureLimit`), so its time never counts against the limit; the render waits for it only that long plus
  half a second each to arrive, then draws the page here, and the viewer's quick previews come back for a document
  whose last picture was late (`CheckedDocument.PictureLate`). A picture of another size, late, or from a process gone
  mid-picture is dropped and the process ended, the page fine (it was refused before). The check's small drawing is
  smoothed again: the limit stands for what a page costs here, and a path of 100,000 edges across the page took a
  fifteenth of its time drawn unsmoothed (3 s against 0.2 s), so a page twice over the limit passed; the test
  `APageTheLimitRefusedDrawnSmoothIsRefusedStill` keeps it refused. A picture a render waits for is never let go of (two
  pages on screen dropped each other's), only those asked ahead past the last three, and one let go of before it is
  sent isn't drawn; `CheckDraws` holds only for a picture still coming; pages asked ahead are drawn at the scale the view
  gives each (`ViewScale`, the viewer's rule now in Core: an A1 sheet after A4 pages gets its picture). A check process
  starts with the app's window (`PageChecks.Prestart`): bench `one`, drawings.pdf, three runs each, first page 813, 864,
  813 ms against 958, 877, 1,012 ms without. Bench `run`, master c932ac4 and this branch back to back (PC at 2 to 10%
  before each; RESULTS.md): drawings.pdf first page 0.91 to 0.82 s, scroll proxy 873 to 685 ms a sheet (524 on the
  unsmoothed run before, at 25 to 30% load: smoothing back costs the check some 120 ms a sheet), frames with a blank
  page 216 to 174 of 240, pages still blank after the stop 2 to 1, the same pages again 579 to 919 ms, Find 35.0 to
  30.7 s; text first page 0.29 to 0.24 s, scan 0.25 to 0.23 s, comments 0.89 to 0.67 s. Still missed as above.
  **Find on the drawing set, the options looked at (2026-11-06), none taken.** (a) MuPDF's text without the paths:
  MuPDFWrapper.dll (MuPDFCore 2.0.1) exports 90 functions, and text comes only from `GetStructuredTextPage` on a display
  list that `GetDisplayList` makes by running the whole page (no text device, no page run, no flags to leave paths or
  pictures out). MuPDF's own text device run straight on the page (`fz_new_stext_page_from_page`, as PyMuPDF does) took
  112 to 121 ms for one 4.4 MB sheet of drawings.pdf here, against 230 to 410 ms for list and text: about twice as fast,
  but only with a wrapper built with that export, a native change for the owner to decide. (b) Our own reading of the
  text operators as Find's first pass: `ContentLexer.Parse` takes 380 to 540 ms on that sheet's content (Debug build), no
  faster than MuPDF; a byte scan for BT … ET could take tens of milliseconds, but a page left out on its word trusts a
  second reader over MuPDF's (fonts without /ToUnicode, reading order across operators, forms, annotations), the
  disagreement the review ruled out, and as a filter that only confirms it saves nothing (every page must still be read
  to know it has no hit). (c) A page's text kept across Finds is already kept for the document's lifetime (a second Find
  about a millisecond); keeping it across sessions would write the document's text to disk, which Find never does.
  **A hostile file's time on the Mac (2026-11-06): bounded in process, no check process.** The Mac calls MuPDF 1.25
  directly (`MuPDFShim`), so each call that reads a page's content takes a cookie with a time budget (10 s, Windows'
  limit) and a largest picture (1 G samples, width × height × components). The cookie alone stops nothing while MuPDF
  inflates (the 7 KB page is one lexer call over 4 GB of white space), so the shim opens every document over its own
  stream, which hands MuPDF small chunks while a page is read and throws MuPDF's progressive-loading "not yet"
  (`FZ_ERROR_TRYLATER`) once the budget is spent or Cancel fired: no repair, nothing half read kept. A device in front
  of the list and text devices looks at the clock at each drawing call and refuses a picture over the cap before it is
  decoded (MuPDF inflates all of a picture's samples for every draw, even drawn small). The page is then refused at
  once from then on: the viewer says "This page took too long to read and isn't shown", Find finds the rest and says
  which pages it skipped, Batch's page images leave it out, export reports it empty, print leaves it blank; Cancel and
  closing the document stop a reading at once. In the tests (1 s budget) the 7 KB and 1 MB pages are refused within
  about a second (red first: 74 s for both), the 20,000 × 20,000 picture at once, a 72,000-path sheet draws as without.
  Not covered: a picture under the cap decodes in full unbounded (a few seconds at most); image files and `PdfEdit`'s
  editing documents run unbounded; a hostile page holds its engine (its neighbours, its thumbnails) for up to 10 s once.
  `PageCheckTests` (Windows' names where they apply); mac/docs/PLAN.md "A hostile file's time".
- **Build:** a benchmark kept in the repo and run before each release, with published results: a 5,000-page text PDF, a
  500-page scan, a 1 GB drawing set, a file with 10,000 comments. Targets on a mid-range ARM64 laptop: first page in
  under 1 s, scrolling at 60 fps without blank pages after a 200 ms pause, find across 5,000 pages in under 5 s, the
  comment list ready in under 2 s, memory under 1.5 GB. A release that misses a target says so.
- **Effort** M. Windows: the benchmark, the first round of fixes and Find in worker processes are done (2026-10-30),
  page checks that draw the render's picture (2026-11-06); the drawing set's scroll, first Find and (on the line) first
  page remain over target; Mac: the benchmark and Find on threads done (E16,
  2026-11-02), the same two over target.

### 3.7 Spanish interface

- **Built (Windows, 2026-11-03):** every string the app shows, and what Core shows (the accessibility check, the
  redaction check, What's in This PDF, Batch), moved to resources (`Strings`, 3,294 strings; `PdfStrings`, 1,878) and
  translated as Inkvolt Print's (`print/docs/SPANISH-REVIEW.md`), the language following Windows or Settings ›
  Language; the shared library's scanner and printer text through `CoreLanguage`. 0 UIA findings on the Spanish window,
  panes and dialogs, light and at Text size 150 %; the shots in `docs/ux-review/spanish-pdf/`. The command line stays
  English. Not checked: a PC whose Windows really is in Spanish (`--lang es`, and the choice's logic in
  `LocalizationTests`), every dialog by eye (about 30 of them were).
- **Built (Inkvolt PDF for Mac, 2026-11-06):** every sentence of the app and of PdfCore through PrintCore's `loc`
  (`mac/InkvoltPdf/Resources`: `Localizable.xcstrings`, 1,738; `PdfStrings.xcstrings`, 1,912; Windows' Spanish word for
  word where the sentence is the same, about 2,800), the menus in macOS's own Spanish names, the language following
  macOS's per-app choice or Settings › Language (next launch), the command line English. What's New in Spanish on the
  Mac (`WHATS-NEW.es.md`, the appcast's `xml:lang="es"` notes). Checked: `PdfStringsTests` on the PC, `--self-test
  --strings` complete and the self-test passing in both languages on `ignia-mac` (but Vision's known flake) (mac/docs/PLAN.md, 3.7). The Mac-only
  wording: `pdf/docs/SPANISH-REVIEW.md`, "Inkvolt PDF for Mac".
- **Next:** the owner reviews the wording (`pdf/docs/SPANISH-REVIEW.md`, the Mac's section too); the Store listing loses
  "La aplicación está en inglés." and "What's in This PDF" becomes "Qué hay en este PDF" when it ships; What's New in
  Spanish on Windows.

## Where we already win

Kept up with the same rule: a claim here has a test or a source.
- **Price and privacy:** free, no account, no telemetry. Acrobat's AI Assistant runs on Adobe's servers (Azure OpenAI),
  caching the document 12 hours ([Adobe](https://helpx.adobe.com/ph_fil/acrobat/using/data-usage-and-handling.html)); Foxit's
  translate needs its cloud and credits. Ours works with a local model and shows every word before it goes.
- **Compare:** word-level over the whole document, pages lined up, visual overlay for scans, an annotated copy.
- **Sanitize:** counts and removes by kind, then reads the result back and lists anything left.
- **Recovery copies**, signed files edited by appending (signatures kept), protection kept through every edit.
- **Prepare Form** with field detection, Acrobat's own format scripts, fields that show filled in every viewer.
- **PDF/A-2b** checked with veraPDF on the test documents; **Bates**, header and footer, watermark; **measure** written
  as Acrobat writes it; **booklet and poster** printing; **Batch** of 16 actions on worker threads.
- **Native ARM64** on Windows, and a native Mac app (1.5.0 released), not a cross-platform shell.

## Not doing, and why

- **E-signature request workflows** (send for signature, track, remind): they need a server holding other people's
  documents and accounts. Signing locally (handwritten and digital, 3.4) stays.
- **Cloud review, shared comments and sync:** the same reason. Shared review works by passing the file, or XFDF (1.4),
  through whatever the user already shares files with.
- **AI of our own, or a default AI service:** against the principles; every AI item uses the user's endpoint.
- **Name and organization detection in redaction through a cloud model** (Foxit's Smart Redact): only with the user's own
  endpoint, after 1.1, and never on by default.
- **Print production preflight** (PDF/X, separations, ink coverage): a narrow professional market served by Acrobat and
  dedicated tools; not worth the effort for our users now.
- **XFA form design:** XFA is deprecated in PDF 2.0; XFA files are filled as far as their AcroForm part allows.
