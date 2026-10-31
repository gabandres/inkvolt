# Inkvolt PDF glossary

Domain terms that modules are named after. Architecture words (module, interface, depth, seam, adapter, leverage,
locality) are used in their usual sense: the interface is everything a caller must know, and it is the test surface.

- **Document session** (`Core/DocumentSession.cs`): one open document: its bytes, the MuPDF engine over them, the
  passwords that open them, undo/redo steps and the saved/dirty state. The tab shows it; it never touches WPF.
- **Edit transaction** (`DocumentSession.EditAsync`, `Core/DocumentSession.Edit.cs`): one edit from request to undo
  step: runs the edit off the UI thread keeping the document's protection and signatures where it can, asks for a
  missing password and retries, asks before breaking signatures, then commits. Outcomes: Done, NoChange, Busy,
  Declined, Failed.
- **Undo step**: one committed edit; its id (`UndoStepId`) stays with it through undo and redo, so a toast's Undo acts
  only on the edit it announced.
- **Edit prompts** (`IEditPrompts`): the questions an edit transaction asks the user (signed file, open password,
  permissions password, signature rewrite, breaking edit). WPF adapter: `App/EditPrompts.cs`; the dev script's adapter
  answers open passwords (`openpw`) and passes the rest on; tests answer from a script.
- **Kept protection** (`Core/KeptProtection.cs`): an encrypted document stays encrypted, with the same passwords and
  permissions, through an edit.
- **Signed edit** (`Core/SignedEdits.cs`): an edit of a signed document is appended after the signed bytes when it can
  be; otherwise it needs the user's consent to rewrite the file.
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
- **Text layer** (`Core/TextLayer.cs`): the invisible OCR text over a scanned page; it keeps its words, boxes, suspect
  marks and language in comment lines at its start, so it can be read back, reviewed and corrected in place.
- **Suspect word** (`Core/SuspectWords.cs`): a recognized word worth a second look, found by a heuristic, never a
  confidence (Windows' recognizer has none): not in the spell checker's dictionary for the language, letters and digits
  mixed inside, odd characters, or read as a different real word before cleaning. Listed in the Suspect words pane
  (`App/DocumentTab.SuspectWords.cs`), corrected or kept as read.
- **Redaction check** (`Core/RedactionCheck.cs`, `RedactionCheck.Data.cs`): what is still recoverable after a redaction
  (covered text, unapplied marks, leftovers of the redacted text anywhere in the file, earlier versions), each finding
  with where it is and its fix (redact, sanitize, rewrite). Runs after Apply, from Review › Check Redaction… and in Batch.
- **Document inventory** (`Core/DocumentInventory.cs`, `InventoryReportFiles.cs`): "What's in this PDF": everything a
  file carries besides what its pages show (scripts and what they call, actions that run by themselves, addresses and
  whether they are reached without a click, attachments, metadata, signatures, earlier versions, hidden content, form
  values, covers that hide nothing), each item with where it is and the Sanitize kind that removes it. Nothing is
  changed or contacted. Review › What's in This PDF…, Batch, saved as HTML or JSON.
- **Accessibility check** (`Core/AccessibilityCheck*.cs`): the machine-checkable failure conditions of the Matterhorn
  Protocol 1.1 (PDF/UA-1) run on a document: each **finding** has its condition number ("13-004"), page, element, what is
  wrong and what fixes it; the **human checks** are the checklist of what only a person can judge. The **report** is the
  findings, the ticked checklist and every condition's result as one web page (`AccessibilityReportHtml`). Runs from
  Review › Accessibility Check… (the Accessibility pane) and in Batch.
- **Make Accessible** (`Core/AutoTag*.cs`): tagging a document from its layout. The **tag plan** (`TagPlan`) is what
  will be written: the **blocks** (`TagBlock`: paragraph, heading, list, table, figure, caption, footnote, table of
  contents, formula) of each page in reading order, the running headers and footers (artifacts), the title and
  language; the **reading order panel** edits it (order within a page, the **reading page** a piece is read with when it
  moved to another page, alternate text, decorative pictures) and **writing** it puts each piece of page content in
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
- **Prepare Form's designer** (`FormDesigner`, with `FormDesignRules`; Mac, in PdfCore): what Prepare Form has selected and under way on the page, and what a click, drag, key or typed value does. Windows keeps
  the same rules in `PageViewer.FormDesign` and `DocumentTab.FormDesign`. It hands over the edits; `FormDesign` makes them.
- **Content-only edit**: an edit that leaves the pages as they were (form values, Fill & Sign): the open field editor
  stays (`ContentChange.ContentOnlyEdit`).
