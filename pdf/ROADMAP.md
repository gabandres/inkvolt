# Inkvolt PDF: roadmap

What Inkvolt PDF builds to do better than the paid PDF apps (Acrobat Pro, Foxit PDF Editor Pro/+, Nitro PDF Pro, PDF
Expert, PDFelement Pro, ABBYY FineReader PDF, Power PDF Advanced, PDF-XChange Editor Plus), feature by feature. What
exists today: [README.md](README.md) ("Using it", "Known limits"); the Mac port: [../mac/docs/PLAN.md](../mac/docs/PLAN.md).

**Principles.** Free (AGPL), local only: no account, no cloud service of ours, no telemetry. AI only through the
user's own endpoint (a local model or their own key), with the "what is sent, where" window before anything leaves.
Every claim is checked: each item has acceptance criteria that a test, a corpus run or an outside validator (veraPDF,
EU DSS, Acrobat, pdf.js) can confirm.

**Ranking.** value × fit ÷ effort. Value: how many users miss it and how often reviews name it. Fit: how well it works
locally, without a service, on what we already have (MuPDF, `DocLayout`, the edit transaction, Batch). Effort: S (about a
week), M (2-4 weeks), L (more than a month).

**Priority** (the owner): the features other apps keep behind their paid tiers come first, on both platforms. Second
engines and other additions with no known demand wait for it (Tesseract in 2.2 is an optional download, the owner's call).

**Platforms.** Full parity: an item is done only when it ships on Windows and on the Mac, so a person or an office picks
the platform, not the features. Windows goes first (it has the code to port); the Mac follows. One Pro key works on both.
**State:** every item below is done on Windows. The Mac has had no work since 2026-11-17; what it still lacks is under
each item's **Mac** line and waits for the new Mac (`docs/HANDOFF.md`).

## Free and Pro

Decided with the owner: everything Inkvolt PDF did at launch stays free, and so does whatever a person needs to read,
fill, sign, edit and protect their own documents. **Inkvolt Pro** is a one-time purchase (**$19**; a yearly price for
updates may come later) that unlocks the power features below, the ones the paid apps keep for their top tiers. A
business licence (invoices, MSI/Intune packages, a support contact, priority fixes) follows once there are business users.

- **The source stays open.** Inkvolt PDF is AGPL (MuPDF is), so the Pro features' source is published like the rest
  and anyone may build them. A purchase buys the ready, signed, updating build and the licence; the unlock is a
  convenience, not a lock. Closing the source would take Artifex's commercial MuPDF licence (quoted per customer, per
  copy with quarterly minimums): only worth a quote if Pro sells well.
- **No account, still.** A licence is a key signed with our private key (ECDSA P-256: in .NET's own library and in
  CryptoKit, where Ed25519 would have needed a package) and checked on the PC against the public key in the app: no
  server is asked, the key works offline and survives reinstalling. One check (`Pro.Allows(feature)`) decides what
  shows; a feature without the licence shows what it would do and where to get Pro, and never takes away a result
  already made.
- **Selling.** Windows: our own checkout through a merchant of record (Paddle, Lemon Squeezy: sales tax and VAT
  worldwide for about 5% plus a small fee), since the Microsoft Store leaves non-game apps that use their own commerce
  100% of the revenue, against 15% through Store add-ons ([Microsoft](https://developer.microsoft.com/ja-jp/store/publish-apps));
  a Store add-on stays possible. Mac: the same key, sold the same way (the PDF app is outside the App Store).
- **Against PDFgear.** It is free and does a lot, so nothing a person needs day to day goes behind Pro. Pro is what
  PDFgear and the free tiers don't do well: rule-based and batch redaction, automation, accessibility remediation,
  folder-wide work, archival-grade signatures.

| Item | Free | Pro |
|---|---|---|
| 1.1 Redaction by pattern | Redacting areas, selections and search matches; the built-in patterns on the open document | Saved custom pattern sets, regex, pattern redaction in Batch over many files, the removal report |
| 1.2 Batch presets, watched folder, command line | Batch itself | Saved presets, the watched folder, the command line (`--fill` stays free) |
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
| 3.3 Compare Office files, scans, formatting | Comparing two PDFs, moves, the overlay and lining up scans, the annotated copy (free before Pro, so it stays free) | Office files and scans against a PDF, formatting changes |
| 3.4 Long-term validation for signatures | Verifying | Adding LTV data, certifying with field locks |
| 3.5 Indexed folder search | Searching open documents | Indexing folders and searching them |
| 3.6 Speed on huge files | All of it | |
| 4.10 AI redaction suggestions | | Suggestions from the user's own AI endpoint, and the names and terms list |

**Built, gate off.** `Pro.Allows(feature)` in Core (`Pro.cs`; `ProFeature` is the table's rows) sits on the suite's
`ProCheck` (`InkvoltPrint.Core/Suite`: `ProKeys`, `ProKeyFile`), so one key licenses both apps; the key format and its
test vector: `pdf/tools/pro-key/README.md`. **Enforcement is off** (`ProCheck.Enforced`): everyone gets everything while
Inkvolt PDF launches; a key is still verified and shown, and buying is presented as supporting the project or as a
licence a business can invoice. It flips on, in a release noted in WHATS-NEW, once Inkvolt PDF has a few thousand
installs or about 50 Store ratings (the UI and tests for both states are in place). **Still to do:** the checkout itself
(the owner sets it up with a merchant of record; Get Inkvolt Pro opens the product page, `ProCheck.BuyUrl`, until then).

## Wave 1

### 1.1 Redaction by pattern
Done, Windows and Mac. Redact by Pattern (`RedactionPatterns`: SSN, phone, email, card with Luhn, date, IBAN with mod 97,
IP, ZIP, phrases, a regex with a timeout), scans searched through OCR (`RedactionSearch`), named sets (`RedactionPatternSets`,
plain JSON), the review list (`RedactReviewDialog`), the read-back and the removal report (`RedactionReport`, CSV), Batch's
Redact Patterns; Pro split through `ProFeature.PatternRedaction`. Acceptance (`RedactionCorpusTests`: line-broken,
hyphenated, split runs, rotated, scanned, encrypted through Batch): 21 of 21 found, 0 left, in the app with Windows'
recognizer too.
- **Why scans are never called clean:** a page counts as read by OCR when pictures cover half of it (even under a text
  layer, which can be poor or planted), when it has no text and some ink, or ink no word explains (a logo, text drawn as
  shapes); each is flagged, ink where nothing was read is read again alone at 300 dpi (Windows' recognizer can skip a
  line), and what stays unread is outlined and can be blacked out unread. A value OCR can't read is found only by a person.
- Dates and ZIP codes are looked for in the rest of the file only by pattern: a file's own time stamps hold the same digits.
- **Not checked:** a real scan (every scan here is synthetic), OCR languages other than en-US, a screen reader on the
  list, the sets' buttons and regex box pressed by hand with the gate on.
- **Mac** differences (ICU regex, Vision): `mac/docs/PLAN.md`, "Redaction by pattern, Windows' additions".

### 1.2 Saved batch presets, a watched folder and a command line
Done, Windows and Mac. `BatchPresets` (plain JSON, strict on reading), `WatchedFolder` (a file runs once its size and time
hold for 3 s and nobody holds it open; moved into `working`, then `done` or `failed`; `inkvolt-watch.log`),
`BatchCommandLine` (`--batch`, `--watch`, `--fill`; exit codes in README "Command line"). Acceptance (Windows, ARM64): 500
generated PDFs, hostile ones among them, over this PC's loopback SMB share, through `--batch` and `--watch` killed and
restarted mid-run: every file once, none twice; also through the Store package's alias (`smoke-msix.ps1`'s `Test-CommandLine`).
- MuPDF's output redirect took over .NET's console writers (lines ended "\r\r\n"; typed in a terminal the command line
  ended at once printing nothing): `CommandOutput` keeps its own writers.
- **Memory gate** (`BatchPlan.MemoryBudget`): a file is priced by the larger of its size and what its streams unpack to
  (`BatchRunner.Unpacked`, counted a chunk at a time before admission, 8 bytes a byte), since a 200 KB file can unpack a
  200 MB stream and take 1.6 GB in Reduce File Size; such a file runs alone.
- **Not checked:** a share on another PC over a real network; a run as a scheduled task.
- **Mac:** pricing a file by what its streams unpack to isn't ported.

### 1.3 Accessibility checker
Done, Windows and Mac. `AccessibilityCheck`: Matterhorn Protocol 1.1's machine-checkable conditions (83 of 87) plus
PDF/UA's basics, each failure with its number, page and element; the human conditions as a checklist; an HTML report;
Batch's Check Accessibility. Widths (31-016) checked against TrueType, CFF and Type 1 programs (`CffProgram`,
`Type1Program`). Not checked, as veraPDF doesn't either: 09-007, 09-008 (Ruby, Warichu), 28-018, 31-023. Against
veraPDF: `pdf/tools/a11y-corpus` (latest results in its README).
- **Mac:** the CFF and Type 1 widths aren't ported.

### 1.4 Comments and form data in and out
Done, Windows and Mac. `CommentFiles` (XFDF, FDF, CSV; import merges by /NM and lets in only an allow-list, cleaned),
`FormDataFiles` (XFDF, FDF, CSV, JSON), `FormMerge` (Fill Forms from CSV, `--fill`), `CommentSummary`. Real forms:
`pdf/tools/forms-corpus` (Mac: `mac/tools/forms-corpus`).
- **Not checked:** the round trip through Acrobat itself (checked against the XFDF rules and Adobe-style samples instead).
- A highlighter pen's blend comes back as a plain pen through XFDF (XFDF has no field for it; FDF keeps it).

### 1.5 Redaction check (differentiator)
Done, Windows and Mac. `RedactionCheck`, after every Apply, as Review › Check Redaction… and in Batch: text under covers or
drawn in the color behind it (found by drawing each character), pictures under dark boxes, unapplied marks, leftovers of
the redacted text anywhere in the file (every earlier version too), and boxes drawn into pictures with text beside them
(`GlyphSpacing`). A study of 11 tools found removed text inferred from the glyph positions around it
([arXiv 2206.02285](https://arxiv.org/pdf/2206.02285)), so Inkvolt's own pixel redaction lays out each line it cuts again
(`RedactionLines`, through `Redaction.Redact`): words keep their order from the line's alignment edge, a quarter-height
space between them, each box rounded to steps of twice the line's height; `/PdLaidOut` records the boxes it laid out.
- **Limit, by MuPDF's nature:** a moved word keeps the anti-aliased shading of where it was (under a pixel, 0.24 pt at
  300 dpi): MuPDF renders on the pixel grid, so a word can't be drawn again at a sub-pixel offset.
- **Mac:** `RedactionLines` and `GlyphSpacing` aren't ported.

### 1.6 Store update check
Done. `UpdateCheck` (Core, decisions tested with a fake Store) through `Windows.Services.Store`. Mac: Sparkle 2.

## Wave 2

### 2.1 Paragraph text editing
Done, Windows. `ContentEditor`: a click selects a paragraph (part a: `GroupParagraphs`, Word export's rules) and typing
rewraps it in its box; characters the subset lacks come from the closest installed font (part b: `StandInFonts`,
`CidFontWriter`, `/InkFbN_` names, always named under the editor); font, size, color, bold and italic per stretch
(part c: `TextLook`, each stretch in an `/InkvoltLook` marked-content sequence so it reads back); text inside form XObjects
(part d: `ContentEditor.Forms.cs`; a shared form is copied for the Do clicked). Also turned text, mixed faces, families,
sizes and colors, kerning (the TJ pairs the text carried, else the font's own GPOS/kern table, `FontKerning`), pictures
in the flow (`InlinePictures`, `PictureEdits`, Picture… on the bar) and Crop (`ContentEditor.Crop.cs`: the pixels cut off
leave the file). Tests: `ParagraphEditTests` and its parts, `FontKerningTests`; pdf.js reads edited pages in order
(`pdf/tools/pdfjs-check`).
- Standard Symbol and ZapfDingbats not embedded are measured, not replaced: Symbol with Windows' Symbol (Adobe's widths);
  ZapfDingbats with Adobe's own AFM in `Core/Fonts` (Windows has no twin: Segoe UI Symbol's dingbats are other shapes).
- CFF and Type 1 programs have no kerning of their own and no AFM ships for them, so they kern only through an
  installed twin whose widths match within 1.5%.
- **Not checked:** the Acrobat half of the test (an edited page reads the same in Acrobat; Acrobat isn't on this PC).
- **Mac:** done but for the Windows additions of 2026-11-20 (mixed sizes and colors, the font's own kerning, pictures
  in the flow, Crop). Differences (Type 3 stand-ins from Core Text): `mac/docs/PLAN.md`, "Paragraph editing".

### 2.2 Better OCR
Done, Windows. Results: `pdf/tools/ocr-corpus` (RESULTS.md, RESULTS-photos.md).
- **Stage A:** `ScanCleanup` (shared) straightens, turns upright, smooths and whitens before Windows' recognizer reads;
  the cleaned page can replace the scan. **Suspect words** (`SuspectWords`) are a heuristic, never a score, because
  Windows' `OcrWord` has only text and a box; Tesseract's words have a confidence, so under 60 is suspect too.
- **Lines Windows' recognizer skips** (`MissedLines`): it now and then leaves out a whole line; ink no word covers is read
  again alone. The cause found: four 1s in a row ("1111"), which it never reads and for which it drops the line, so such
  runs are read three strokes at a time (`ReadOnes`). A page whose lines don't say which way up it is turns over only
  when that reads clearly more real words (digits count neither way).
- **Tesseract** (the owner: an optional download, never bundled): `TesseractStore`, `TesseractCatalog`, `TesseractRecognizer`.
  Source: the Tesseract project's own GitHub release (UB Mannheim's signed build, GitHub's SHA-256), chosen over UB
  Mannheim's server (no published digest), conda-forge and MSYS2 (dozens of packages to pin) and NuGet bindings (a new
  package). The NSIS installer asks for elevation, so it is **never run**: Inkvolt decodes its LZMA stream itself (`Lzma`)
  and keeps only the pinned files (`pdf/tools/tesseract-pin`). In the Store package it lives in LocalCache: run from the
  redirected `%LOCALAPPDATA%`, tesseract.exe started but never loaded its DLLs and hung. Each page runs in a separate
  bounded process (`BoundedProcess`: time, output and a 3 GB job), its TSV parsed as hostile (`TesseractTsv`).
- **Mixed languages:** two of Windows' languages read the page each and keep each line from the reading that looks more
  like real words (`MixedRecognizer`); with a Tesseract language, Tesseract reads both in one run. The choice is saved
  only once installed (`PageOcr.Choose`) and everything else reads with it, never downloading.
- **Photographed pages** (`Imaging/PageWarp.cs`, shared): trapezoid correction and straightened lines, each only on a page
  that clearly needs it. Limits by nature: letters squeezed near a spine aren't widened (that needs the camera's
  distance, which a photo doesn't give); a page with no desk around it has no edges for the trapezoid; two facing pages
  aren't split.
- **Make Text Editable** (`EditableText`, `FontMatch`): recognized text becomes real text in the closest installed face,
  paragraphs laid out so the paragraph editor reads them as one.
- **Mac:** stage A done with Apple's Vision. Vision skips no line on the corpus (`VisionProbeTests`), so `MissedLines` and
  `ReadOnes` aren't needed there. Not ported: Tesseract, photographed pages, Make Text Editable, and writing both
  languages' tags back into a text layer ("en-US+es-MX": the Mac keeps one).

### 2.3 USB scanners (WIA, TWAIN)
Done, Windows and Mac. Windows: File › Scan lists WIA scanners (`WiaScanner` over `WindowsWia`, the shared library) and
64-bit TWAIN sources (`WindowsTwain`, when TWAINDSM.dll is installed) beside eSCL ones, with feeder, duplex, blank pages
and presets (`PresetPlan`); tests with a fake device (`UsbScannerTests`). Mac: ImageCaptureCore.
- **Not checked (needs hardware):** the acceptance test, a WIA flatbed and a WIA feeder scanner each scanning a 10-page
  stack into one PDF with OCR. No page has gone through a real WIA or TWAIN driver yet.

### 2.4 Tags, reading order, alt text, PDF/UA
Done, Windows and Mac. Make Accessible (`AutoTag`: a tag plan from `DocLayout`, marked content with MCIDs, the structure
tree), the Reading order pane (moves, other pages, a piece's kind, alternate text typed or suggested by the user's own
vision model), Save as PDF/A-2a, Batch; Unicode for glyphs without it (`FontUnicode`, `TexGlyphs`, Type 3 bitmap fonts
named by code); forms tagged piece by piece; row spans, ruled and (from a first column of group labels) unruled. Corpus
(`pdf/tools/a11y-corpus`, `run.ps1 -Tag`; latest results in its README): both untagged pdfTeX papers pass PDF/UA-1 after Make
Accessible; 5 of 12 re-tagged office files pass, the other 7 fail only on what tagging doesn't touch (form-field tooltips,
fonts).
- A form drawn more than once stays one piece where it is drawn: a stream can hold one set of MCIDs.
- A Type 3 font whose glyph names say nothing (dvips's "Fa") gets no Unicode: a symbol font's codes are other glyphs, and
  wrong text is worse than none.
- The Kind list makes nothing a table or a list from a paragraph (their cells and entries aren't known).
- **Not checked:** Acrobat's and PAC's view of the output (neither is installed here).
- **Mac:** row spans in tables without lines (2026-11-20) aren't ported.

### 2.5 What's in this PDF (differentiator)
Done, Windows and Mac. `DocumentInventory`: one report of what a file carries and does when opened, each item saying
whether Sanitize removes it; HTML or JSON; Batch's Report What's in Each File.

## Wave 3

### 3.1 Translate side by side (bring your own AI)
Done, Windows. `Translation` (plan, answers, apply), `ContentEditor.Translate.cs`, `TranslationMarkup`,
`ContentEditor.TranslateLinks.cs`, through the user's endpoint and the "what is sent, where" window; free. Each paragraph
is written in its box (wraps, uses the space below, shrinks to half or 5 pt, else flagged with a comment); tables cell by
cell, turned tables in their own frame (`TranslationFrame`); looks (bold, italic, scripts, underlines, up to three other
colors or families) travel as tags the reply must keep; links follow the words they stayed on; right-to-left text shaped
line by line. Tests: `TranslationTests`, `TranslationLooksTests`, `TranslationMarkupHostileTests`, the 100-page report
through a real socket to a stand-in, `TranslationCorpusTests` and `TranslationPdfJsTests` (opt-in), `TranslationRealModelTests`
(opt-in, a real endpoint).
- **Why the choices:**
  - When the page's font lacks a letter, the whole paragraph is drawn in the closest installed font (a subset rarely holds
    a translation's letters, and letter-by-letter stand-ins read like a ransom note).
  - A new line is written where the lowest old line it reaches was drawn: a page that paints a white band under each line
    before drawing it hid every new line after the first (tests read text, so `TranslationInk` now measures each line's ink).
  - A reply's tags are trusted only when they are ours, balanced, nested, and cover about as much as was sent; anything
    else is written plain. A request names only the tags its text has (a model told of `<font>` wrote `<font color=…>`).
    A prompt line asking to keep every pair "even around words you leave as they are" made no clear difference: not kept.
  - Right-to-left lines are written in stretches (`GlyphOrder.Stretches`): each right-to-left stretch left to right, the
    stretches and the figures and Latin words between them in reading order, so MuPDF (search, copy, export, the redaction
    check) and pdf.js both read them. Tried and dropped: the whole line in visual order (MuPDF read figures backwards) and
    /ActualText over it (MuPDF turned it around). Not built: the figures written twice (Acrobat, which reads /ActualText,
    would get them backwards, and MuPDF wouldn't see visible text).
  - A right-to-left line is drawn in a font whose joined letters stay on the baseline (`RightToLeftFont`): MuPDF reads a
    line whose letters sit on more than one baseline (Calibri's Arabic) backwards.
- **What one content stream can't give both readers:** pdf.js runs a right-to-left word into the figure or Latin word
  beside it, and a line with a bold, other-font or raised word inside right-to-left text keeps reading order (no spaces
  in pdf.js). MuPDF reads Arabic-Indic digits backwards.
- **Real model** (latest, Qwen3 4B Instruct 2507 Q4_0 on llama-server, 8,192 tokens): NIST p. 1, attn-v7 p. 3 and fw9 p. 1
  into Spanish, French, German, Arabic and Japanese, 30-155 s a page; every answer's words show; tags kept whole in
  11/11/12/5/6 of 16 marked texts (es/fr/de/ar/ja). The model's own faults, not bugs: a term translated several ways, an
  identifier changed ("SP 800-63A" as "DE 800-63A"), words of another script slipped in (asked again, then flagged).
- **Not checked:** another model or a cloud endpoint; a model's refusal or an answer to the text instead of its
  translation can't be told from a translation; a screen reader or Acrobat on a copy; long runs over sleep and Wi-Fi drops.
- **Mac:** done (2026-11-10) as Windows was then; the looks and right-to-left work of 2026-11-19 and 11-20 isn't ported.
  Differences: `mac/docs/PLAN.md`, "Translate side by side". Not checked on the Mac: a real model.

### 3.2 Export to PowerPoint and HTML
Done, Windows and Mac. `PptxWriter` (one slide per page, editable text boxes, the first top heading the title, tables,
pictures stored once, `ExportShapes` telling lines, rectangles and ellipses apart from a rendering since MuPDF gives only
a path's bounds) and `HtmlWriter` (one reflowing file, no script or request, a Content-Security-Policy); both carry the
PDF's links on their words (`ExportSpan.Link`; http, https, mailto and exported pages only). Checked by
`pdf/tools/export-corpus` (Open XML SDK, PowerPoint, the W3C Nu validator, reading order).
- **Not checked:** LibreOffice (`-LibreOffice`, not installed where it ran); a real screen reader.
- **Mac:** links in the exports (2026-11-20) aren't ported.

### 3.3 Compare: Office files, scans and formatting
Done, Windows and Mac. Either side an Office file (through the installed Office; LibreOffice on the Mac), a picture of a
page or a PDF; scans recognized first; formatting (`CompareLooks`) and moves (`CompareMoves`) apart from wording; scans
lined up for shift, skew, size and a quarter turn before the overlay (`CompareAlign`). Acceptance (`CompareContractTests`,
the PDFs in the tests' `Data`, `INKVOLTPDF_WORD` makes them again): a contract and its edited .docx with 30 planted changes
list all 30, none extra.
- **Not checked:** a real scan; on the Mac, a real .docx through LibreOffice against Word's PDF.
- **Mac:** another size or a quarter turn in `CompareAlign` (2026-11-20) isn't ported.

### 3.4 Long-term validation for signatures
Done, Windows and Mac. Sign Digitally and Add Verification Information store OCSP answers or CRLs for the whole chain
(/DSS, /VRI) and document timestamps (B-LT, B-LTA) as incremental updates; certifying with fields locked (FieldMDP);
Batch's long-term action (one `LtvClient` a run, answers reused, a silent server not asked again). Online only through
`LtvClient`, after a window listing every address. Opening or signing a file no longer goes online by itself (Windows
fetching issuers a file's certificates name let a file probe the local network). Encrypted files are refused
(`Incremental` can't append to them). Checked: `LtvTests`, `FieldLockTests`, `BatchLongTermTests` against a generated
authority on loopback; EU DSS 6.5.1 run locally (`pdf/tools/pades-check`) reports PAdES-BASELINE-LTA, TOTAL_PASSED.
- **Not checked:** Acrobat's "LTV enabled" and its view of a field lock (`pdf/tools/pades-check` says how, by hand); real
  certificate authorities and timestamp servers (an OCSP answer issued ahead of a fresh timestamp by a CDN is accepted
  only as far as "still in force at that time" in our check; EU DSS may ask for a later one); smart cards; many files
  against a real authority. Watched folders don't go online (their files fail "may not go online").
- **Mac** differences (`LtvClient` resolves names itself, SecTrust with fetching off): `mac/docs/PLAN.md`, "Long-term
  validation". Not checked on the Mac: EU DSS on its files, Acrobat, a real authority.

### 3.5 Indexed folder search
Done, Windows and Mac. Edit › Search Folders… (Pro). A small inverted index of our own, no new dependency (`FolderIndex`:
one file per folder, commits, compaction; `IndexTerms` folds as Find compares, so the index only proposes pages and Find
on the kept text has the last word). Only **index workers** parse PDFs (`IndexWorkers`, below normal priority), so a
hostile file costs a worker; `FolderIndexer` follows change notices and looks every 30 s. Runs longer than 48 characters
are filed in overlapping pieces (`IndexTerms` version 2). Latest (`pdf/tools/bench` `index-run`, 10,000 generated PDFs,
72,797 pages): indexed in about 2.5 minutes on a quiet PC, word queries to the last result under 0.25 s, a changed file
found in seconds, a phrase of two common words to 500 pages in under 1 s.
- **Slow index runs are Windows Defender**, not the app: a file a worker opens waits for its real-time scan, and when
  Defender is busy the workers sit idle with processors free (`index-read` shows it). An exclusion is the user's call.
- **Not checked:** real-world PDFs at this scale, a real hostile PDF (a worker's death is simulated), a network drive, a
  disk filling up; of cloud drives, only placeholders on a test sync root and one OneDrive folder already on the PC.
- **Mac:** reads in process on reading threads through the engine's page check (no workers), Spotlight not used (its
  text isn't Find's): `mac/docs/PLAN.md`, "Indexed folder search". The phrase speed-up (2026-11-20) isn't ported. Not
  checked on the Mac: the 10,000-PDF bench, a real crashing PDF, a network volume.

### 3.6 Speed on huge files (differentiator)
Acrobat users report freezes on 200-500 page files and large drawings
([Adobe Community](https://community.adobe.com/t5/acrobat-discussions/acrobat-becomes-very-slow-when-i-open-large-pdf-files-200-pages/td-p/15579541));
no vendor publishes numbers. **Targets** on a mid-range ARM64 laptop: first page under 1 s, scrolling at 60 fps with no
blank page after a 200 ms pause, Find across 5,000 pages under 5 s, the comment list under 2 s, memory under 1.5 GB. The
benchmark (`pdf/tools/bench`, a release step) measures them; the latest run is
[tools/bench/RESULTS.md](tools/bench/RESULTS.md): every target met but the 1 GB drawing set's scroll and Find (the
accepted limit, below). A release that misses a target says so.
- **Find workers** (`Core/FindWorkers.cs`): a long Find reads text in helper processes of the app (`--find-worker`),
  because MuPDFCore's native wrapper guards MuPDF's allocations with process-wide mutexes: threads in one process don't
  scale, processes do. A file with a password stays in process (no secret crosses a pipe).
- **Page checks** (`Core/PageChecks.cs`, `PdfEngine.Checks.cs`): MuPDF's inflating isn't bounded in time (a 7 KB page
  inflating to 4 GB drew for a minute) and MuPDFCore 2.0.1 passes no cookie where content is read, so each page is first
  drawn small in a check process (`--page-check`, 10 s, 2 GB) and refused past it. Chosen over a pre-scan of the streams
  (`InflateGuard`, rejected). When no check process starts, pages run unchecked (failing safe would leave every document
  blank on that PC). No verdict passes to another engine: two parsers a hostile file can make disagree. The check's
  small drawing stays smoothed: unsmoothed, a page twice over the limit passed. The check also draws the render's
  picture for the page waiting on it (`PictureLimit` 1.5 s, outside the verdict's time), and a document slow to check
  (a drawing set) gets more check processes for pages ahead (`SlowWorkers`). Not covered: documents with a password and
  formats other than PDF run unchecked.
- **The comments' first page:** the review panes' first PDFsharp read waits until the view has settled
  (`PageViewer.SettledAsync`), since its garbage collections paused a scroll begun just after opening for seconds.
- **Still missed, and why:** the drawing set's Find (400 sheets of about 250 ms of MuPDF's content lexer each; a
  text-only reading needs MuPDF entry points MuPDFCore 2.0.1 doesn't export, a native change for the owner to decide;
  our own content reader was ruled out for disagreeing with MuPDF; keeping text across sessions would write it to disk)
  and its scroll (a sheet's list and drawing take 450 ms or more in one process; the Mac's bands on every core don't
  port, as threads in one process wait on MuPDFCore's locks). Tried and dropped: a display list kept per sheet (the
  engine keeps 32 already; painting is three quarters of the cost), the check drawing the render's picture in place of
  its small drawing, two strips a check process.
- **Mac:** `mac/tools/bench`. Find on threads in process (MuPDF instances don't wait on each other there), drawings in
  bands on every core, a hostile page bounded in process (the shim's cookie and own stream): `mac/docs/PLAN.md`, "A
  hostile file's time". The drawing set's scroll and Find are over target there too.

### 3.7 Spanish interface
Done, Windows and Mac: every string in resources (`Strings`, `PdfStrings`; Mac `Localizable.xcstrings`,
`PdfStrings.xcstrings`), the language following the system or Settings › Language, What's New in Spanish
(`WHATS-NEW.es.md`); the command line stays English. The owner approved the Windows wording; the Store listing is in
Spanish (`pdf/packaging/README.md`, "Spanish listing (es)").
- **Next:** the owner's review of the Mac-only wording (`pdf/docs/SPANISH-REVIEW.md`, "Inkvolt PDF for Mac").
- **Not checked:** a PC whose Windows really is in Spanish (`--lang es` and `LocalizationTests` cover the choice);
  every dialog by eye.

## Wave 4 (market check, 2026-11-21)

From a fresh comparison with Acrobat Pro, Foxit, Nitro, PDF-XChange, PDFgear, UPDF, PDFelement and Edge (the owner: "do all
of them", 2026-11-21). Built in the order of the batches; each item's line says Done when merged, with its Mac half waiting
for the new Mac. Sizes: S about a week, M 2-4 weeks, L more. Free unless it says Pro.

- **Batch A (paper and pages):**
  - 4.3 Interleave two scans (fronts, then backs reversed; Organize and File › Scan). Done on Windows (`PageEditor.Interleave`, Scan the Backs); the Mac's waits.
  - 4.4 Remove blank pages, and split at blank separator pages (Organize, Batch). Done on Windows (`BlankPages`, both Batch actions); the Mac's waits.
  - 4.5 Bookmarks from headings (`DocLayout`'s headings, nested by level). Done on Windows (`HeadingBookmarks`); the Mac's waits.
  - 4.7 Resize pages (Letter and A4, scale or add margins). Done on Windows (`PageEditor.Resize`); the Mac's waits.
  - 4.13 Replace pages (keeping bookmarks and links to them). Done on Windows (`PageEditor.Replace`); the Mac's waits.
  - 4.14 Edit page labels (i, ii, then 1, 2; prefixes). Done on Windows (`PageLabels`); the Mac's waits.
- **Batch A (text):** 4.1 Spell check where people type (edited text, notes, text boxes, callouts, form fields; Windows'
  own spell checker): Done, Windows (`SpellChecker`, tests `SpellCheckerTests`; the app's `Spelling`); Mac waits
  (NSSpellChecker behind the same rules). 4.2 Find & Replace across the document (Replace, Replace All, case and whole word, one undo step,
  the replacements a font can't draw listed): Done, Windows (`TextReplace` over `ContentEditor.ReplaceParagraphIn`, one save
  for all; tests `TextReplaceTests`, pdf.js `ReplacedTextReadsTheSameInPdfJs`; the app's `ReplaceDialog`); Mac waits.
- **Batch B:** 4.8 Smaller black-and-white scans as CCITT G4 (the shared encoder from Inkvolt Print's 4.4; JBIG2 needs a
  package: the owner's call). 4.6 Copy text from an area of a scan, and an area as a table. 4.15 Links from the addresses
  in the text. 4.18 Mark every search hit. 4.17 Proofreading marks (Insert Text, Replace Text). 4.10 AI redaction
  suggestions through the user's own endpoint (Pro; never on by default; the review list and Check Redaction as for
  patterns). 4.20 Save an AI answer (Word, PDF, a comment; the conversation kept).
  - 4.17 Proofreading marks. Done on Windows (`Annotations.AddInsertText`, `AddReplaceText`: a caret, and a strike-out grouped with it as Acrobat groups them; the Comments pane, Summarize Comments, XFDF and FDF); the Mac's waits.
  - 4.10 AI redaction suggestions (Pro). Done on Windows (`RedactionSuggestions`: the user's endpoint only, the send window always shown, the answer read as quotes and kept only where the text sent holds them; `RedactionTerms`, the no-AI names and terms list; both into Redact by Pattern's review list, read-back, check and report); the Mac's waits.
  - 4.20 Save an AI answer. Done on Windows (`AiAnswerExport`: an answer or the conversation to Word through `DocxWriter` or to a PDF, or an answer as a note on the page it cites; `AiConversation` kept on the `DocumentSession`); the Mac's waits.
- **Batch C:** 4.9 Two documents side by side (a second window; a tab dragged out). 4.16 Reflow view (`HtmlWriter`'s one
  column in the tab). 4.12 Calculated form fields, and several fields aligned and sized together. 4.19 Rulers, guides, a
  grid and snapping. 4.22 Turn a picture or text block to any angle. 4.11 Ask across a folder (the folder index picks
  the pages, the user's endpoint answers; Pro). 4.21 Search by meaning (embeddings from the user's endpoint beside the
  folder index; Pro). 4.24 A summary read aloud to a file. 4.23 Edit by asking (the user's endpoint with the command
  palette's commands as tools, each step shown and undoable; last, a weak fit for small local models).
  - 4.9 Two documents side by side. Done on Windows (`DocumentWindows`: which window owns which tab, moves, tear-off, the window in use, what is remembered; `TabDrag`; File › New Window, a tab dragged out or onto another window, the jump list's New Window); the Mac's waits.
  - 4.16 Reflow view. Done on Windows (`Reflow`: `HtmlWriter`'s column with a look that follows Text size, the view's zoom and Dark pages, links out to the browser, the commands that run; `ReflowPosition`: the page kept both ways; shown in WebView2, View › Reflow, Ctrl+3); the Mac's waits.
- **Watch, not built:** filling XFA-only forms (Nitro and PDFelement do; an XFA layout engine, L, likely a package);
  ZUGFeRD/Factur-X e-invoices (no desktop editor has them; PDF/A-3b first).

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
  as Acrobat writes it; **booklet and poster** printing; **Batch** on worker threads.
- **Native ARM64** on Windows, and a native Mac app, not a cross-platform shell.

## Not doing, and why

- **E-signature request workflows** (send for signature, track, remind): they need a server holding other people's
  documents and accounts. Signing locally (handwritten and digital, 3.4) stays.
- **Cloud review, shared comments and sync:** the same reason. Shared review works by passing the file, or XFDF (1.4),
  through whatever the user already shares files with.
- **AI of our own, or a default AI service:** against the principles; every AI item uses the user's endpoint.
- **Name and organization detection in redaction through a cloud model** (Foxit's Smart Redact): not through a service of
  ours. Built under these conditions as 4.10 (Suggest Redactions, Pro): only through the user's own endpoint, never on by
  default, the send window always shown, every suggestion reviewed before anything is removed.
- **Print production preflight** (PDF/X, separations, ink coverage): a narrow professional market served by Acrobat and
  dedicated tools; not worth the effort for our users now.
- **XFA form design:** XFA is deprecated in PDF 2.0; XFA files are filled as far as their AcroForm part allows.
