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
  permissions password, signature rewrite, breaking edit). WPF adapter: `App/EditPrompts.cs`; tests answer from a script.
- **Kept protection** (`Core/KeptProtection.cs`): an encrypted document stays encrypted, with the same passwords and
  permissions, through an edit.
- **Signed edit** (`Core/SignedEdits.cs`): an edit of a signed document is appended after the signed bytes when it can
  be; otherwise it needs the user's consent to rewrite the file.
- **Content-only edit**: an edit that leaves the pages as they were (form values, Fill & Sign): the open field editor
  stays (`ContentChange.ContentOnlyEdit`).
