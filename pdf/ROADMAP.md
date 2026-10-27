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

**Platforms.** Full parity (decided 2026-10-27): an item is done only when it ships on Windows and on the Mac, so a
person or an office picks the platform, not the features. Windows usually goes first (it has the code to port); the Mac
follows in the same release cycle. Until the Mac reaches parity with today's Windows app (PLAN.md's "Parity with
Windows": 1.0, then steps E1-E13), new items queue behind those steps on the Mac. One Pro key works on both.

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
- **No account, still.** A Pro licence is a key signed with our private key (Ed25519) and checked on the PC against
  the public key in the app: no server is asked, nothing is sent, the key works offline and survives reinstalling.
  Inside the app one entitlement check (a single `Pro` seam in Core) decides what shows; a feature without the licence
  shows what it would do and where to get Pro, and never takes away a result already made.
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
| 3.3 Compare Office files, scans, formatting | Comparing two PDFs (today) | Office files and scans against a PDF, formatting changes, the change report |
| 3.4 Long-term validation for signatures | Verifying | Adding LTV data, certifying with field locks |
| 3.5 Indexed folder search | Searching open documents | Indexing folders and searching them |
| 3.6 Speed on huge files | All of it | |

The seam is in (with 1.2): `Pro.Allows(feature)` in Core (`Pro.cs`) is the one check every Pro feature asks, today always
yes; presets, watched folders and the command line ask it. Not built yet: the key format, its check behind that seam and
the checkout.

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
  the document; Batch's Redact Patterns action applies them over many files. Still to do: saved named pattern sets,
  scanned pages through OCR text, a per-hit list with context, the removal report, the Pro split (the read-back check
  is 1.5's check after Apply).
- **Beat it when:** patterns for SSN, phone, email, card, date, plus regex and named custom patterns saved on the PC;
  a match is found across line breaks, hyphenation and split text runs; cards pass Luhn and SSNs the SSA's number rules,
  so near-misses aren't marked; scanned pages are searched through their OCR text; every hit is listed with page and
  context, accepted or skipped one by one or all, before anything is applied; Batch runs a pattern set over a folder
  (password files asked for, as Batch does now); a report (CSV and a page in the app) lists per file the page, pattern
  and a masked value of each removal; after applying, the result is read back and searched again, and any remaining hit
  fails the file. Test: a corpus with planted values (line-broken, hyphenated, rotated page, scanned page, encrypted file)
  finds 100% of them and leaves 0 after applying.
- **Effort** M. Windows now; Mac with its redaction step.

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
  originals move right, an interrupted file never runs twice, the command line's exit codes. Still to do: the Mac; a
  500-file run over a real network share; the alias tested in an installed Store package.
- **Beat it when:** an action list is saved as a named preset (a plain JSON file, readable and diffable, exported and
  imported); a watched folder runs a preset on each new file once it has stopped growing, moves originals to "done" or
  "failed", and writes a log line per file; no page cap; `InkvoltPdf.exe --batch <preset> <files or folder>` runs the
  same preset without a window and returns a non-zero exit code on any failure; the new actions Save as PDF/A and
  Redact by pattern. Test: a preset round-trips through export and import unchanged; 500 files dropped into a watched
  folder all come out once, none twice, including files copied in slowly over the network.
- **Effort** M. Windows; Mac with Batch.

### 1.3 Accessibility checker
- **Leader.** Acrobat Pro: Accessibility Check against PDF/UA and WCAG, each rule passed, failed or "needs manual check"
  ([Adobe](https://helpx.adobe.com/acrobat/current/create-verify-pdf-accessibility.html)). The free PAC follows the
  Matterhorn Protocol (31 checkpoints, 136 failure conditions, 89 machine-checkable)
  ([axes4](https://support.axes4.com/hc/en-us/articles/7371943734930)). Why now: US Title II deadlines moved to
  April 26, 2027 (entities of 50,000+) and April 26, 2028 (smaller), WCAG 2.1 AA
  ([JD Supra](https://www.jdsupra.com/legalnews/doj-extends-title-ii-ada-web-2176958/)).
- **Now.** Screen-reader names in the app; no checker; tags kept but not made.
- **Beat it when:** a local checker covers the machine-checkable Matterhorn conditions and agrees with veraPDF's
  PDF/UA-1 result on a corpus of 50 files (tagged and untagged, Word, InDesign and LaTeX output); each failure links to
  the page and element, says in plain words what is wrong and what fixes it, and the human-check items are a checklist
  in the same panel; the report saves as HTML; runs in Batch. Test: the corpus result matches veraPDF file by file.
- **Effort** M. Windows; Mac after 1.0.

### 1.4 Comments and form data in and out
- **Leader.** Acrobat Pro: export and import comments as FDF or XFDF
  ([Adobe](https://helpx.adobe.com/acrobat/current/importing-exporting-comments.html)), comment summaries, form data
  import and export.
- **Now.** None.
- **Beat it when:** comments export and import as XFDF and FDF (replies, colors, authors, appearances of stamps and
  drawings kept) and as CSV; form data exports as XFDF, FDF, CSV and JSON and imports from them, and a CSV of many rows
  fills one copy of the form per row (a merge); Summarize Comments makes a PDF with each page beside its comments, numbered
  and connected. Test: XFDF exported by Inkvolt imports into Acrobat and back with every comment equal; a 200-row CSV
  makes 200 filled forms whose values read back right.
- **Effort** S-M. Windows; Mac after 1.0.

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
  picture. Fix redacts, sanitizes and rewrites. Tests: the corpus (8 kinds flagged, each properly redacted 0), a value
  planted in each place, an earlier revision, ordinary files 0. 100-page file: 1.2-1.9 s after Apply (Debug build,
  busy PC), in the background (Apply itself unchanged). Still to do: the Mac, glyph-spacing inference around pixel
  redactions.
- **Effort** S. Windows with 1.1; Mac with its redaction.

## Wave 2

### 2.1 Paragraph text editing
- **Leader.** Acrobat Pro: text reflows inside its box, font, size and color from a panel; but the font must be installed:
  embedded-only fonts allow only size and color, otherwise it falls back to Minion Pro
  ([Adobe](https://helpx.adobe.com/acrobat/using/edit-text-pdfs1.html)). PDF Expert detects paragraphs and keeps font,
  size and opacity ([Readdle](https://support.readdle.com/pdfexpert/edit-pdfs/edit-text-in-pdf-files)).
- **Now.** One text operator at a time, in its embedded font only, no reflow (README, Known limits).
- **Beat it when:** a click selects the paragraph (lines joined by `DocLayout`, as Export to Word does); typing reflows it
  inside its box with the paragraph's alignment and line spacing, and the box grows downward or warns before it
  overlaps what follows; characters the embedded subset lacks come from the installed font closest in metrics and
  class (named in the panel, never silently), and the rest of the paragraph stays in its own font; font, size, color,
  bold and italic change for a selection; text inside form XObjects edits too. Test: on the export corpus, 20 words
  added to a paragraph re-extract in order, nothing overlaps the next block, and the page opens in Acrobat and pdf.js
  with the same text; a file whose fonts aren't installed is still editable (where Acrobat isn't).
- **Effort** L. Windows, then the Mac (its 1.0 has the line-level editor; this follows after 1.0).

### 2.2 Better OCR
- **Leader.** ABBYY FineReader PDF: about 190 OCR languages ([Wikipedia](https://en.wikipedia.org/wiki/ABBYY_FineReader)),
  preprocessing (deskew, noise, straightened lines, trapezoid correction)
  ([ABBYY](https://help.abbyy.com/en-us/finereader/12/adjustimage)). Acrobat: suspect words shown beside the image and
  corrected in place ([Section 508](https://www.section508.gov/training/pdfs/aed-cop-pdf04/)).
- **Now.** Windows' recognizer only: installed OCR languages, printed text, no straightening (Known limits). The Mac 1.0
  uses Apple's Vision.
- **Beat it when:** pages are deskewed (±15°), turned upright, despeckled and their background cleaned before recognition,
  optionally written back as the cleaned image; a second, local engine (Tesseract, Apache-2.0, 100+ languages;
  [tessdata](https://github.com/tesseract-ocr/tessdata)) is an optional download for languages Windows lacks, with
  mixed languages per page; low-confidence words are listed beside their image and corrected in place, the text layer
  updated; "make the text editable" turns a page's recognized text into real text in a matching font (for 2.1).
  Test: on a scan corpus (skewed 3-10°, noisy, two languages) the word error rate is lower than today's on every file,
  and a corrected word is found by search.
- **Effort** L. Windows; the Mac gets deskew and correction after 1.0 (Vision already does the languages).

### 2.3 USB scanners (WIA, TWAIN)
- **Leader.** Acrobat: scans through TWAIN or WIA (Windows) and Image Capture (Mac), presets, deskew, background removal,
  descreen ([Adobe](https://helpx.adobe.com/acrobat/using/scan-documents-pdf.html)). PDF-XChange keeps knowledge-base
  articles on scanners its 64-bit build can't find ([PDF-XChange](https://www.pdf-xchange.com/knowledgebase/all/search?q=tag:WIA)).
- **Now.** eSCL network scanners only.
- **Beat it when:** WIA 2 scanners (and 64-bit TWAIN sources) are listed beside eSCL ones in the same dialog with feeder,
  duplex, color and dpi; blank pages are dropped on request; every scan goes through 2.2's cleanup and OCR; scan presets
  are saved. Test: a WIA flatbed and a WIA feeder scanner each scan a 10-page stack into one PDF, OCR included.
- **Effort** M. Windows; the Mac through ImageCaptureCore after 1.0.

### 2.4 Tags, reading order, alt text, PDF/UA
- **Leader.** Acrobat Pro: Autotag in Adobe's cloud (headings, borderless tables, nested lists, multi-column reading
  order), a reading order tool and tag editor ([Adobe](https://helpx.adobe.com/acrobat/using/cloud-auto-tagging-accessibility-pdfs.html));
  reviewers note that sending the file to a server is itself a risk ([Apryse](https://apryse.com/blog/auto-tagging-pdf-ua-compliance)).
- **Now.** `DocLayout` already finds headings, lists, tables, columns, headers and footers for Export to Word.
- **Beat it when:** Make Accessible tags an untagged PDF on the PC from `DocLayout` (H1-H6, P, L/LI, Table/TR/TH/TD with
  header scope, Figure, Artifact for running headers and page numbers), sets title, language and tab order; a reading
  order panel shows the order as numbered boxes, reordered by drag; alt text is typed per figure, or suggested by the
  user's own vision model (sent only after the usual window); output passes veraPDF PDF/UA-1 on the 1.3 corpus after
  the human checks; Save as PDF/A-2a. Test: 1.3's checker and veraPDF both pass on the corpus's untagged Word and
  LaTeX files after Make Accessible plus alt text.
- **Effort** L. Windows; Mac after 1.0.

### 2.5 What's in this PDF (differentiator)
- **The gap.** Acrobat's sanitize step removes hidden data when redacting
  ([Adobe](https://helpx.adobe.com/acrobat/current/removing-sensitive-content-pdfs.html)), but no app gives one readable
  report of what a file carries and what it would do when opened.
- **Build:** a report (Properties, before Sanitize, and in Batch) of: scripts and what they call; actions that run on
  open, print or close; every web address and whether it is contacted without a click (remote GoTo, submit, URI on
  open); attachments; metadata and authors per object; earlier revisions recoverable from incremental saves (with the
  text that changed); hidden layers, white or off-page text; form values; the 1.5 redaction check. Saved as HTML or
  JSON. Test: a corpus with each item planted reports all of them; Sanitize afterwards reports none.
- **Effort** S (most of it is Sanitize's scan). Windows; Mac with Sanitize.

## Wave 3

### 3.1 Translate side by side (bring your own AI)
- **Leader.** Foxit: AI translate keeping layout, original and translation side by side, 25+ languages, in Foxit's cloud,
  credits per month ([Foxit](https://www.foxit.com/ai/pdf-translator/)). PDFelement: side by side or interleaved, 35-50
  languages, scans through OCR ([Wondershare](https://pdf.wondershare.com/online-pdf/ai-pdf-translator.html)).
- **Beat it when:** translation runs through the user's endpoint (Ollama, LM Studio, or their key), paragraph by
  paragraph, with the usual window showing what is sent; a translated copy keeps each paragraph in its box (2.1's
  reflow, text shrunk to fit and flagged when it can't), tables cell by cell; the two documents scroll together; no
  page or size cap. Test: a 100-page report translated with a local model keeps page count and figure positions, every
  paragraph translated, nothing sent beyond localhost.
- **Effort** M (after 2.1). Windows; Mac with the AI features.

### 3.2 Export to PowerPoint and HTML
- **Leader.** Acrobat exports to PowerPoint and HTML, with "retain page layout" or flowing text
  ([Adobe](https://www.adobe.com/learn/acrobat/web/convert-pdf-retain-page-layout)).
- **Beat it when:** PowerPoint: one slide per page at the page's size, text as editable text boxes in reading order,
  pictures as pictures, simple shapes as shapes, slide titles from headings; HTML: one file, reflowing, with real
  headings, lists and tables from `DocLayout`, pictures embedded, alt text from tags, valid HTML5 with no external
  requests. Test: export-corpus runs open in PowerPoint and LibreOffice with no repair prompt; the HTML passes the W3C
  validator and reads in order in a screen reader.
- **Effort** M. Windows; Mac after its Word export.

### 3.3 Compare: Office files, scans and formatting
- **Leader.** ABBYY (Corporate) compares a Word file or a scan with a PDF, OCR in the background; it ignores formatting
  ([ABBYY](https://help.abbyy.com/en-us/finereader/16/user_guide/overview_compare)). Acrobat reports text, fonts,
  images and page order ([Adobe](https://helpx.adobe.com/acrobat/current/compare-documents.html)).
- **Beat it when:** either side can be an Office file (made into a PDF by the installed Office, as now) or a scan (OCR
  first); font, size, color and style changes are listed apart from wording; moved paragraphs show as moves; shifted
  or skewed scans are aligned before the visual overlay; the annotated copy includes visual differences. Test: a
  contract and its edited .docx with 30 planted changes (wording, moves, bold, size) lists all 30, none extra.
- **Effort** M. Windows; Mac with Compare.

### 3.4 Long-term validation for signatures
- **Leader.** Acrobat: Add Verification Information stores revocation data (DSS) after signing, and timestamped
  signatures with revocation are LTV-enabled ([SSL.com](https://www.ssl.com/how-to/long-term-validation-ltv-of-pdf-digital-signatures-in-adobe-acrobat/)).
- **Beat it when:** signing embeds OCSP/CRL responses for the whole chain (DSS/VRI) and can add a document timestamp
  (PAdES B-LT, B-LTA); Add Verification Information works on any signed file; DocMDP and FieldMDP are enforced when
  verifying. Test: Acrobat shows "LTV enabled" and the EU DSS validator reports B-LTA for our signed files.
- **Effort** M. Windows; Mac with signatures.

### 3.5 Indexed folder search
- **Leader.** Acrobat Pro's catalog: a full-text index (.pdx) over a folder, searched in Advanced Search
  ([Adobe](https://helpx.adobe.com/acrobat/current/creating-pdf-indexes.html)).
- **Beat it when:** a folder is indexed in the background (a local file beside our settings), kept current as files
  change, OCR text included; results with context, opened at the hit; accents and case ignored as Find does. Test:
  10,000 PDFs indexed once, a word query answered in under 1 s, a changed file found again within a minute.
- **Effort** M. Windows; Mac after 1.0 (Spotlight covers part of it there).

### 3.6 Speed on huge files (differentiator)
- **The gap.** Acrobat users report freezes on 200-500 page files and on large drawings, and Adobe staff suggest
  leaving continuous scrolling ([Adobe Community](https://community.adobe.com/t5/acrobat-discussions/acrobat-becomes-very-slow-when-i-open-large-pdf-files-200-pages/td-p/15579541)).
  No vendor publishes numbers.
- **Build:** a benchmark kept in the repo and run before each release, with published results: a 5,000-page text PDF, a
  500-page scan, a 1 GB drawing set, a file with 10,000 comments. Targets on a mid-range ARM64 laptop: first page in
  under 1 s, scrolling at 60 fps without blank pages after a 200 ms pause, find across 5,000 pages in under 5 s, the
  comment list ready in under 2 s, memory under 1.5 GB. A release that misses a target says so.
- **Effort** M. Windows and Mac.

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
  as Acrobat writes it; **booklet and poster** printing; **Batch** of 12 actions on worker threads.
- **Native ARM64** on Windows, and a native Mac app (in progress), not a cross-platform shell.

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
