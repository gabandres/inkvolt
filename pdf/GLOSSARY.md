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
- **Document export** (`Core/DocumentExport.cs`): a document's pages to Word, Excel (the tables found) or plain text:
  reads each page (a damaged page exports empty, a page without text goes to the recognizer when one is given), lays the
  document out (`DocLayout`) and writes the format, or reports that nothing was extracted and saves nothing. Used by
  File › Export, Batch and `tools/export-corpus`.
- **Recognizer**: text recognition (OCR) of a page without text; Windows' OCR in the app (`App/PageOcr.cs`), passed to
  Core as a function.
- **Redaction check** (`Core/RedactionCheck.cs`, `RedactionCheck.Data.cs`): what is still recoverable after a redaction
  (covered text, unapplied marks, leftovers of the redacted text anywhere in the file, earlier versions), each finding
  with where it is and its fix (redact, sanitize, rewrite). Runs after Apply, from Review › Check Redaction… and in Batch.
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
- **Pro check** (`Core/Pro.cs`): `Pro.Allows(feature)`, the one place a Pro feature asks whether it may run (no licence
  yet: always yes).
- **Content-only edit**: an edit that leaves the pages as they were (form values, Fill & Sign): the open field editor
  stays (`ContentChange.ContentOnlyEdit`).
