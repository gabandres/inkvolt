# Inkvolt PDF glossary

Domain terms that modules are named after. Architecture words (module, interface, depth, seam, adapter, leverage,
locality) are used in their usual sense: the interface is everything a caller must know, and it is the test surface.

- **Document session** (`Core/DocumentSession.cs`): one open document: its bytes, the MuPDF engine over them, the
  passwords that open them, undo/redo steps and the saved/dirty state. The tab shows it; it never touches WPF.
- **Find worker** (`Core/FindWorkers.cs`, its parent's side in `Core/PdfEngine.Find.cs`): the app started again with
  `--find-worker <pipe name>`, reading pages' text for one long search and sending each page's text and hits back over
  a private pipe. It writes nothing and shows nothing, and ends with the search or the app. A worker that fails loses
  nothing: this process's threads read its pages.
- **Folder index** (`Core/FolderIndex.cs`, `FolderIndex.Search.cs`): one folder's search index in one local file in the data folder's `FolderIndex`:
  the words of its PDFs' pages (**terms**, `Core/IndexTerms.cs`: folded so whatever Find reads alike is one term) leading to
  the pages they are on, each page's text compressed, and each file's size, time and state. Written only at its end, a
  **commit** at a time; **compacting** writes what is live to a new file. A search narrows by terms, then runs Find on the kept text.
- **Index worker** (`Core/IndexWorkers.cs`): the app started again with `--index-worker <pipe name>`, the only thing that
  parses a PDF for the index: told a path, it sends the pages' text back. A file that kills it costs that worker and is **skipped**.
- **Indexer** (`Core/FolderIndexer.cs`; in the app `IndexedFolder`, `FolderSearches`, `App/FolderSearch.cs`): keeps one folder's index
  current: lists the folder (**a look**), has workers read what is new or changed, commits, waits for a change notice or the next look.
- **Interface language** (`App/AppLanguage.cs`, the choice in the shared `UiLanguage`): the language the app's own words
  are in, English or Spanish, picked once at start-up and read from `Strings` (the app) and `PdfStrings` (Core, English
  unless the app opts in through `PdfLanguage`, so the command line stays English). What a document says stays as it is.
- **Edit transaction** (`DocumentSession.EditAsync`, `Core/DocumentSession.Edit.cs`): one edit from request to undo
  step: runs the edit off the UI thread keeping the document's protection and signatures where it can, asks for a
  missing password and retries, asks before breaking signatures, then commits. Outcomes: Done, NoChange, Busy,
  Declined, Failed.
- **Translated copy** (`Core/Translation.cs`, `Core/ContentEditor.Translate.cs`): a new document in another language, made in
  three stages: the **plan** (the pages' paragraphs, nothing sent), the **answers** (what the model said, each checked; a
  stopped run keeps its answers) and **apply** (one pass over the pages, each paragraph written in its box at the largest
  **fit**, its size against its own, that it has room for). A **flag** is what the reader should look at: most get a comment in the copy.
- **Undo step**: one committed edit; its id (`UndoStepId`) stays with it through undo and redo, so a toast's Undo acts
  only on the edit it announced.
- **Edit prompts** (`IEditPrompts`): the questions an edit transaction asks the user (signed file, open password,
  permissions password, signature rewrite, breaking edit). WPF adapter: `App/EditPrompts.cs`; the dev script's adapter
  answers open passwords (`openpw`) and passes the rest on; tests answer from a script.
- **Kept protection** (`Core/KeptProtection.cs`): an encrypted document stays encrypted, with the same passwords and
  permissions, through an edit.
- **Signed edit** (`Core/SignedEdits.cs`): an edit of a signed document is appended after the signed bytes when it can
  be; otherwise it needs the user's consent to rewrite the file.
- **Long-term data** (`Core/Ltv.cs`, `Core/Dss.cs`): the certificates, OCSP answers and CRLs a signature will need when it is
  checked years from now, stored in the file's /DSS as an incremental update. `LtvClient` is the one way online for it, and what it
  will contact is listed first (`LtvPlan`). `RevocationPool` holds such data while a check judges it, as hostile until its signature
  checks out; `LongTermCheck` says what a signature's level is from what the file holds, and goes nowhere.
- **Simple shape** (`ExportShape`, `Core/ExportShapes.cs`): a line, rectangle or ellipse a page draws, which becomes a shape on
  a PowerPoint slide. MuPDF reports only a path's bounds, so what the rendered page shows decides; any other path stays a
  picture.
- **Slide page** (`SlidePage`, from `DocLayout.AnalyzeSlides`): a page laid out for a slide. Unlike the flow Word and HTML
  use, every line stays on its page, so a running head shows on the slide, and it says where those are so one never becomes
  the slide's title.
- **Document export** (`Core/DocumentExport.cs`): a document's pages to Word, Excel (the tables found), plain text, PowerPoint or HTML:
  reads each page (a damaged page exports empty, a page without text goes to the recognizer when one is given), lays the
  document out (`DocLayout`) and writes the format, or reports that nothing was extracted and saves nothing. Used by
  File › Export, Batch and `tools/export-corpus`.
- **Recognizer** (`ITextRecognizer`, `shared/InkvoltPrint.Core/Imaging/TextRecognizer.cs`): text recognition (OCR) of
  a page image, on the device, returning words with boxes in reading order and no confidence. Windows' is
  `WindowsRecognizer` (`shared/InkvoltPrint.Windows/Ocr`, one per installed OCR language); the Mac's is Vision; a second
  engine would be another. `App/PageOcr.cs` picks it; Core gets it as an interface or a function.
- **Scan cleanup** (`shared/InkvoltPrint.Core/Imaging/ScanCleanup.cs`): what a page image goes through before the
  recognizer reads it: straightened (skew up to ±15°), turned upright (sideways, upside down), smoothed, the paper evened
  out to white, lone specks removed. The **cleaned page** is its result; it replaces the scan only when the user asks
  (Replace the scans with the cleaned pages, `Core/ScanPage.cs`).
- **Recognized page** (`Core/ScanText.cs`): one page through render, cleanup and recognizer, its words mapped back to the
  page (`ScanFrame`: through the quarter turns and the straightening, each word turned with the text), with its skew and
  turns.
- **Page recognizer** (`PageRecognizer`, `Core/PageRecognizer.cs`): a recognizer with how it reads (`RecognizeOptions`: cleaned or
  as scanned, suspect words, the cleaned pages kept) and the spell checker for its language, reading a document's pages
  without text into words (`RecognizedPages`: the words per page, the pages that had text, the cleaned pages, the suspect
  count), which it writes as the text layer. Recognize Text, Batch's Recognize Text (`BatchHost.Ocr`, as Recognize Text was
  last set: `PageOcr.ForBatch`), File › Scan and the redacted pages (`Redaction.TextBack`) read through it. The Mac has no
  `PageRecognizer` yet: Batch and export read through `PageOcr.recognizer(_:options:spelling:)` with Recognize Text's
  choices (the app's `SavedOcr`), Recognize Text and Scan through `PageOcr.recognizeText`.
- **Text layer** (`Core/TextLayer.cs`): the invisible OCR text over a scanned page; it keeps its words, boxes, suspect
  marks and language in comment lines at its start, so it can be read back, reviewed and corrected in place.
- **Suspect word** (`Core/SuspectWords.cs`): a recognized word worth a second look, found by a heuristic, never a
  confidence (Windows' recognizer has none): not in the spell checker's dictionary for the language, letters and digits
  mixed inside, odd characters, or read as a different real word before cleaning. Listed in the Suspect words pane
  (`App/DocumentTab.SuspectWords.cs`), corrected or kept as read.
- **Redaction check** (`Core/RedactionCheck.cs`, `RedactionCheck.Data.cs`): what is still recoverable after a redaction
  (covered text, unapplied marks, leftovers of the redacted text anywhere in the file, earlier versions), each finding
  with where it is and its fix (redact, sanitize, rewrite). Runs after Apply, from Review › Check Redaction… and in Batch.
- **Redact Patterns run** (`PatternRedaction`, `Core/PatternRedaction.cs`): one Redact Patterns after its hits were chosen
  (accepted, skipped): the redaction, with the redacted pages' text recognized again (`Redaction.ApplyWithText`), run as one
  edit the caller's way; then the read-back, the redaction check, its **verdict** (passed, still there, left in the file,
  incomplete) and the removal report. Its **mode** says what checks it: **reviewed** (Review › Redact by Pattern: the full
  check, only leftovers of what was removed fail) or **unattended** (Batch: the removed values only, anything found fails).
- **Document inventory** (`Core/DocumentInventory.cs`, `InventoryReportFiles.cs`): "What's in this PDF": everything a
  file carries besides what its pages show (scripts and what they call, actions that run by themselves, addresses and
  whether they are reached without a click, attachments, metadata, signatures, earlier versions, hidden content, form
  values, covers that hide nothing), each item with where it is and the Sanitize kind that removes it. Nothing is
  changed or contacted. Review › What's in This PDF…, Batch, saved as HTML or JSON.
- **Accessibility check** (`Core/AccessibilityCheck*.cs`): the machine-checkable failure conditions of the Matterhorn
  Protocol 1.1 (PDF/UA-1) run on a document: each **finding** has its condition number ("13-004"), page, element, what is
  wrong and what fixes it; the **human checks** are the checklist of what only a person can judge. The **report** is the
  findings, the ticked checklist and every condition's result as one web page (`AccessibilityReportHtml`). Runs from
  Review › Accessibility Check… (the Accessibility pane) and in Batch. On the Mac: `PdfCore/Accessibility`, Tools ›
  Accessibility Check…, the same pane as a segment of the sidebar.
- **Make Accessible** (`Core/AutoTag*.cs`): tagging a document from its layout. The **tag plan** (`TagPlan`) is what
  will be written: the **blocks** (`TagBlock`: paragraph, heading, list, table, figure, caption, footnote, table of
  contents, formula) of each page in reading order, the running headers and footers (artifacts), the title and
  language; the **reading order panel** edits it (order within a page, the **reading page** a piece is read with when it
  moved to another page, a piece's kind, alternate text, decorative pictures) and **writing** it puts each piece of page content in
  marked content with an MCID and builds the structure tree, replacing tags the document had, and gives characters
  without Unicode theirs (`FontUnicode`, `TexGlyphs`). In the app: `AccessibleActions`, `DocumentTab.ReadingOrder.cs`; in
  Batch: Make Accessible. Make Accessible, the panel's fixes and Save as PDF/A-2a are Pro features (`ProFeature`).
- **Batch preset** (`Core/BatchPresets.cs`): a saved batch (its actions in order with their settings, the output
  names and choices) as a plain JSON file with a version; never holds passwords. Run by the Batch window, a watched
  folder and the command line.
- **Watched folder** (`Core/WatchedFolder.cs`): a folder whose new PDFs and images run through a preset once complete
  (size and time unchanged for the quiet period, nobody holding them), taken by a move into `working`, then moved to
  `done` or `failed` with a log line. In the app: `FolderWatches` (`App/BatchAutomation.cs`); unattended: `--watch`.
- **Comment file** (`Core/CommentFiles.cs`): a document's comments outside it, as XFDF, FDF or CSV, with their ids,
  replies and (FDF; a stamp's in XFDF) appearances. Importing one merges: comments whose id is already there are skipped.
- **Comment summary** (`Core/CommentSummary.cs`): a new PDF of each page with comments beside its numbered list of them,
  numbers on both sides joined by a line.
- **Form data file** (`Core/FormDataFiles.cs`): a form's values outside it, as XFDF, FDF, CSV (one row) or JSON.
- **Merge** (`Core/FormMerge.cs`): Fill Forms from CSV: one filled copy of a form per CSV row, rows with refused values
  reported instead of saved.
- **Pro check** (`Core/Pro.cs`, on the suite's `ProCheck` in `InkvoltPrint.Core/Suite`): `Pro.Allows(feature)`, the one
  place a Pro feature asks whether it may run: yes with a **licence** (a signed key, `ProKeys`, kept in the file both
  Inkvolt apps read and verified on the PC), and yes for everyone while `Pro.Enforced` is off (the launch period).
- **Measuring scale** (`Core/Measurement.cs`, `MeasureScale`): what a length on the page stands for ("1 in = 10 ft"),
  kept by a page in a viewport (/VP, the PDF's own way; several per page for details, the last listed wins where they
  overlap) and by each **measurement** (a Line, PolyLine or Polygon comment with /Measure, labeled with its value).
  Without one, values are real size. The Mac calls a measurement still being clicked a **measurement under way**
  (`MeasureDraft`, in PdfCore; Windows keeps it in `PageViewer.Measure`).
- **Reading order state** (`ReadingOrder.state`, `ReadingOrderState`; Mac, in PdfCore): what the Reading Order pane shows for a
  tag plan on a page: its pieces numbered, the boxes on every page, the summary, what can be done. Windows keeps the same rules
  in `DocumentTab.ReadingOrder`.
- **What is sent, where** (`AiActions.ConfirmSend`; on the Mac `AiConfirmSheet` over PdfCore's `AiConsent`): the window before each send of the AI assistant, with where the text goes, how much, and every message under a disclosure. **Reach** (`AiReach`) is where an endpoint keeps text, as its address is written: this PC or this Mac, your network, or the internet; a connection only ever goes to an address that keeps that promise.
- **Prepare Form's designer** (`FormDesigner`, with `FormDesignRules`; Mac, in PdfCore): what Prepare Form has selected and under way on the page, and what a click, drag, key or typed value does. Windows keeps
  the same rules in `PageViewer.FormDesign` and `DocumentTab.FormDesign`. It hands over the edits; `FormDesign` makes them.
- **Document command table** (`DocumentCommands`; Mac, in PdfCore `Ux/DocumentCommands.swift`): every menu bar command
  once, each a **document command** (title, key, the action it sends, its place in the menus, its plain-words note and
  what it **needs**, a `Requirement`), from which the app builds the menu bar (`MainMenu`) and decides what can run over a
  window's **document state** (`DocumentState`: pages, selection, busy, signing…); the command palette lists the menus so
  built. Windows keeps its commands in the ribbon's XAML and each command's CanExecute.
- **Content-only edit**: an edit that leaves the pages as they were (form values, Fill & Sign): the open field editor
  stays (`ContentChange.ContentOnlyEdit`).
