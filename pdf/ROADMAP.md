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
| 3.3 Compare Office files, scans, formatting | Comparing two PDFs (today) | Office files and scans against a PDF, formatting changes, the change report |
| 3.4 Long-term validation for signatures | Verifying | Adding LTV data, certifying with field locks |
| 3.5 Indexed folder search | Searching open documents | Indexing folders and searching them |
| 3.6 Speed on huge files | All of it | |

**Built (2026-10-30), gate off.** Decided with the owner: **$19**, one time. `Pro.Allows(feature)` in Core (`Pro.cs`) is
the one check every Pro feature asks (presets, watched folders, the command line); behind it the licence is real: a key
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
- **Effort** M. Windows now; Mac: done with E1 (2026-10-28; your own pattern in ICU syntax) and Batch's action with E8 (2026-10-30).

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
  originals move right, an interrupted file never runs twice, the command line's exit codes. Mac: done with E8 (2026-10-30: presets, watched folders, `--batch` and `--watch`; `--fill` comes with 1.4). Still to do: a
  500-file run over a real network share; the alias tested in an installed Store package.
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
  conditions for 49 (the other is a veraPDF inconsistency, see the tool's README); veraPDF's own 297 PDF/UA-1 test
  files: 296 of 297 (the other can't be opened by PDFsharp). Still to do: the Mac.
- **Beat it when:** a local checker covers the machine-checkable Matterhorn conditions and agrees with veraPDF's
  PDF/UA-1 result on a corpus of 50 files (tagged and untagged, Word, InDesign and LaTeX output); each failure links to
  the page and element, says in plain words what is wrong and what fixes it, and the human-check items are a checklist
  in the same panel; the report saves as HTML; runs in Batch. Test: the corpus result matches veraPDF file by file.
- **Effort** M. Windows; Mac after 1.0.

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
  keeps it); the Mac.
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
  busy PC), in the background (Apply itself unchanged). Mac: done with E1 (2026-10-28) and Batch's action with E8 (2026-10-30). Still to
  do: glyph-spacing inference around pixel redactions.
- **Effort** S. Windows with 1.1; Mac with its redaction.

### 1.6 Store update check (done 2026-10-27)
- **Why.** Store apps update when Windows gets to it, so people can sit on an old version for weeks.
- **Now.** Windows: packaged installs ask the Store (`Windows.Services.Store`) ~30 s after startup and from Help › Check
  for Updates…; a ready update shows in the title bar ("Update required" when mandatory, never blocking reading); Update
  settles unsaved documents as closing does, then the Store installs it. Setting to turn the startup check off; only
  Windows' Store service is asked. Decisions tested with a fake Store (`UpdateCheck`). Mac: the PDF app ships outside
  the App Store, so its update check comes with that distribution.
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
  that begins with another family doesn't join at all. `ParagraphEditTests.Mixed` (3). Still to do: paragraphs in
  turned text (they edit line by line); paragraphs mixing font families (a symbol font, a word in another family).
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
  flatbed and a WIA feeder scanner, 10 pages each) is still to run. 2.2's cleanup (deskew, despeckle) isn't built, so
  scans get OCR only. Mac (ImageCaptureCore) pending.
- **Beat it when:** WIA 2 scanners (and 64-bit TWAIN sources) are listed beside eSCL ones in the same dialog with feeder,
  duplex, color and dpi; blank pages are dropped on request; every scan goes through 2.2's cleanup and OCR; scan presets
  are saved. Test: a WIA flatbed and a WIA feeder scanner each scan a 10-page stack into one PDF, OCR included.
- **Effort** M. Windows; the Mac through ImageCaptureCore after 1.0.

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
  decorative) fails both only on the same math-font glyphs. Still to do: glyphs without Unicode (a ToUnicode from TeX
  glyph names would fix the pdfTeX papers), Caption/Note/TOC/Formula tags, nested lists, row headers, content inside
  form XObjects tagged piece by piece, cross-page moves and changing a piece's kind in the pane, charts with many
  labels read as tables (`DocLayout`), the Pro gate (`Pro.cs` has no Accessibility feature yet; enforcement is off),
  Acrobat and PAC checks of the output, and the Mac.
- **Beat it when:** Make Accessible tags an untagged PDF on the PC from `DocLayout` (H1-H6, P, L/LI, Table/TR/TH/TD with
  header scope, Figure, Artifact for running headers and page numbers), sets title, language and tab order; a reading
  order panel shows the order as numbered boxes, reordered by drag; alt text is typed per figure, or suggested by the
  user's own vision model (sent only after the usual window); output passes veraPDF PDF/UA-1 on the 1.3 corpus after
  the human checks; Save as PDF/A-2a. Test: 1.3's checker and veraPDF both pass on the corpus's untagged Word and
  LaTeX files after Make Accessible plus alt text.
- **Effort** L. Windows; Mac after 1.0.

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
- **Effort** M. Windows; Mac with Compare (the compare itself came with E3, 2026-10-30; Office files, scans and
  formatting are still to do on both).

### 3.4 Long-term validation for signatures
- **Leader.** Acrobat: Add Verification Information stores revocation data (DSS) after signing, and timestamped
  signatures with revocation are LTV-enabled ([SSL.com](https://www.ssl.com/how-to/long-term-validation-ltv-of-pdf-digital-signatures-in-adobe-acrobat/)).
- **Beat it when:** signing embeds OCSP/CRL responses for the whole chain (DSS/VRI) and can add a document timestamp
  (PAdES B-LT, B-LTA); Add Verification Information works on any signed file; DocMDP and FieldMDP are enforced when
  verifying. Test: Acrobat shows "LTV enabled" and the EU DSS validator reports B-LTA for our signed files.
- **Effort** M. Windows; Mac with signatures (verifying and signing came with E2, 2026-10-30, DocMDP and FieldMDP enforced
  as on Windows; the long-term data is still to do on both).

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
  instances use four times the CPU of one for no gain), while four processes run four times as fast. Next: read text
  for Find in worker processes (the app started again with a worker switch, the hits sent back), and a display list
  kept per sheet across scrolls. Mac: still to do.
- **Build:** a benchmark kept in the repo and run before each release, with published results: a 5,000-page text PDF, a
  500-page scan, a 1 GB drawing set, a file with 10,000 comments. Targets on a mid-range ARM64 laptop: first page in
  under 1 s, scrolling at 60 fps without blank pages after a 200 ms pause, find across 5,000 pages in under 5 s, the
  comment list ready in under 2 s, memory under 1.5 GB. A release that misses a target says so.
- **Effort** M. Windows: the benchmark and the first round of fixes are done (2026-10-30), Find in worker processes
  and the drawing set's scroll remain; Mac: both.

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
