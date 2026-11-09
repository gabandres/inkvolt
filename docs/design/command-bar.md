# Command bar: familiar groups, one click (design, for the owner's approval)

Status: **proposal + prototype** on branch `t3/2df29816`. Nothing is merged. The owner's brief is `docs/HANDOFF.md`,
"Owner, 2026-11-08 (evening)", item 2.

## 1. Map: where the others put each task

Sources are the vendors' own help. *Old* means the fact comes from an older version's guide. Adobe's help pages refuse
automated reads, so the Acrobat rows come from Adobe's pages as search engines quote them (links below). Click counts
start with the document open and end when the file is written.

**Top-level groups, in order**

| App | Groups, left to right |
|---|---|
| Nitro PDF Pro (Win) | Home, then Convert, Review, Page Layout, Forms, Share, Erase, Protect, Accessibility, Help, Smart Tools [N1]. *Old* (Pro 11): Home, Edit, Review, Forms, Protect, Page Layout, with Convert as a group on Home [N2] |
| Foxit PDF Editor 13 | File, Home, Edit, Comment, View, Form, Protect, Share, "etc." [F1]. Convert and Organize are tabs too (tasks below) |
| Acrobat (new UI) | Global bar: **All tools, Edit, Convert, E-sign**, with search, save, print and share on the right. Other tools sit in the left "All tools" panel [A1] |
| PDF-XChange Editor 11 | File, Home, View, Comment, Protect, Form, Organize, Convert, Share, Review, Accessibility, Bookmarks, Help [X1] |
| PDFgear (Win) | A **Convert** menu at the top, plus a floating "To Word" button at the top right [G1]. A Tools tab holds Password and Compress [G2] |

**Tasks** (path · clicks)

| Task | Nitro | Foxit 13 | Acrobat | PDF-XChange 11 | PDFgear |
|---|---|---|---|---|---|
| To Word | Convert › To Word, then a window (files, pages, folder, "Open files after conversion") › Convert · **3**; scans get OCR on their own [N3]. *Old*: Home › Convert › To Word [N2] | Convert › To MS Office › Word, then the Save dialog · **4**; Explorer right-click › Convert to Word [F2] | Convert › Word (DOCX) › Convert to DOCX › Save · **4** [A2] | Convert tab › export [X1] · ~3 | Convert › To Word, then a dialog with the folder › Convert · **3**; the result is shown in its folder [G1] |
| To Excel, PowerPoint | Convert › To Excel, To PowerPoint (same window) [N2] | To MS Office › Excel or PowerPoint [F2] | Convert panel [A2] | Convert [X1] | Convert › To Excel, To PPT [G1] |
| Edit text | the Edit button at the left of the ribbon (*old*) [N2] | Edit › Edit Text [F3] | Edit (global bar) [A1] | Home [X1] | — |
| Highlight, note | Review › Markup › Highlight, Add Note (*old*) [N2] | Comment › Highlight (Shift+H), Note (Ctrl+Shift+N) [F4] | floating quick-action toolbar [A1] | Home, Comment [X1] | — |
| Fill & sign | Home › QuickSign (*old*) [N2] | Home or Protect › Fill & Sign [F5] | E-sign (global bar) [A1] | Home [X1] | — |
| Certificate signature | Protect › Sign; Forms › Digital Signature (*old*) [N2] | Protect › Sign & Certify › Place Signature [F6] | All tools › Use a certificate [A3] | Protect [X1] | — |
| Password | Protect › Password Security [N4] | Protect › Secure Document › Password Protect [F6] | All tools › Protect a PDF [A4] | Protect [X1] | Tools › Password [G2] |
| Redact | Erase tab [N1]; *old*: Redact tab › Mark Content, Apply Redactions [N2] | Protect › Mark for Redaction; Hidden Data › Sanitize [F6] | All tools › Redact a PDF (Sanitize sits beside it) [A5] | Protect [X1] | Protect › Redact (Mac guide) [G3] |
| OCR | Review › OCR (*old*) [N2] | Convert › Recognize Text › Current File [F7] | All tools › Scan & OCR [A6] | Convert [X1] | an option in the conversion [G1] |
| Combine | Home › Create › Combine (*old*) [N2] | Convert › Combine Files [F7] | All tools › Combine files [A1] | Convert [X1] | — |
| Organize pages | Home or Page Layout › Pages: Rotate, Insert, Delete, Extract (*old*) [N2] | Organize › Insert, Delete, Move, Rotate… [F8] | All tools › Organize pages [A1] | Organize [X1] | — |
| Compress | File › Optimize PDF (*old*) [N2] | File › PDF Optimizer › Reduce File Size [F8] | All tools › Compress a PDF [A1] | — | Tools › Compress, pick a level › Compress [G2] |

**Shortcuts.** Foxit 13: Hand Alt+3, Select Alt+6, Snapshot Alt+7, Highlight Shift+H, Note Ctrl+Shift+N, Typewriter
Shift+T, Strikeout Shift+S, Delete pages Ctrl+Shift+D, Insert from file Ctrl+Shift+I, Search panel Ctrl+Shift+F, F4
panels, F11 full screen [F4]. PDF-XChange 11: Insert/Delete/Extract/Rotate pages Ctrl+Shift+I/D/E/R, hold Space for the
hand, Ctrl+F, F3 [X2]. Nitro: Alt plus a letter for each ribbon command (Alt, R = Review) [N1]; Ctrl+O/P/F/Z/Y (*old*)
[N2]. Acrobat: single-key tools only after Preferences › General "Use single-key accelerators" (H = Hand) [A7].
**Inkvolt already matches**: Ctrl+Shift+D/I/E (Foxit, PDF-XChange), Ctrl+Shift+F, F4, F11, Ctrl+Shift+Y; H/T/G page keys.

**Inkvolt today, set against them.** The bar is Hand/Select, Fill & Sign, Comment, Draw, Redact, Organize; Combine
is in "…". To Word is File › Export › Word… › Export (options window) › Save · **4 clicks and 2 windows**. Convert,
Protect and OCR are not on the bar at all, and those are exactly the tasks the others put first (Acrobat: Edit, Convert;
Nitro and PDFgear: Convert).

## 2. Proposal

**Groups, in order:** (Save, Print, Undo, Redo) | Pointer | **Edit · Convert · Comment · Fill & Sign · Organize ·
Protect · Scan & OCR** | … . This is the starting point, unchanged: the map backs Edit and Convert first (Acrobat's bar,
Foxit's and Nitro's early tabs) and Protect late (all five). **Draw** goes into Comment's flyout as a submenu (Foxit:
Comment › Drawing). **Redact** goes into Protect (Foxit, PDF-XChange, Nitro's Protect/Erase, PDFgear). The pointer
group becomes **icon-only** (Hand, Select and Snapshot are known by their icons in Acrobat and Foxit). That frees about
45 DIPs, which is what lets 1280 keep its labels.

**Per group:** the main job is first and semibold. Each item has an icon, a label and one line under it; the key is the
existing shortcut, shown by the menu.

| Group | Main job (one click) | Flyout (rest) |
|---|---|---|
| Edit (E70F) | Edit Text & Images: the tool turns on | Add Image (I), Add Link (N) · Header & Footer, Watermark |
| Convert (EDE1) | **Word (.docx)**: see below | Excel (.xlsx)…, PowerPoint (.pptx)… · Plain text, Web page, Images · PDF/A for archiving |
| Comment (E90A) | Highlight the selection (Ctrl+Shift+H); with no selection, the highlighter tool | Underline, Strike out, Note, Stamp (S) · Draw › (pen P, highlighter M, rectangle R…) |
| Fill & Sign (E76D) | Sign: places your saved signature; **asks** the first time, to make one | Add text (A), Check (K), Cross (X) · Prepare Form |
| Organize (E8B3) | Organize Pages (Ctrl+Shift+O) | Insert (Ctrl+Shift+I), Extract (Ctrl+Shift+E), Split · Combine files, Reduce size |
| Protect (E72E) | Password: **asks** for the password (nothing to default) | Redact (**needs a selection** or marks; Apply asks to confirm), Redact by Pattern, Check Redaction, Sanitize · Sign with certificate (**asks** for the ID) · Remove protection |
| Scan & OCR (E8C1) | Recognize Text on every scanned page, with Windows' recognizer; already-text pages are skipped | Scan to PDF (**asks** for the scanner), Insert from Scanner · Review Suspect Words |

**One click, Convert › Word** (prototyped). It saves `name.docx` next to the PDF, never over a file (`name (2).docx`,
through `PdfFiles.UniquePath`). It uses all pages, with scanned pages recognized when Windows has a recognizer, and then
opens the file. The notice says **"Saved name.docx · Show in folder · Change options…"**; the last link opens today's
Export window. **Shift+click** opens that window first. It still asks when the document has no folder (new or unsaved:
the Save dialog), when the file is protected (today's "export anyway?"), and when nothing could be read (today's
message). Not yet handled: a read-only folder (proposal: fall back to the Save dialog instead of the error). Excel and
PowerPoint should get the same one click (`name.xlsx`, `name.pptx`); the prototype only does Word. File › Export keeps
its "…" items, which open the window, and the palette lists both "Convert to Word" (at once) and "Export to Word…"
(asks).

**Split button or dropdown?** Recommended: a Fluent **split button**. Its body runs the main job and its chevron opens
the flyout, so Word is 1 click (Nitro 3, Acrobat 4). The prototype keeps today's dropdown (Convert › Word = 2 clicks).

**Fitting** (`CommandBarLayout` rules, unchanged: lowest priority into "…" first; icons-only only when a group of
priority 80 or more would go). Priorities: Save, Undo 100 · Convert 90 · Fill & Sign 86 · Pointer 85 · Edit 84 ·
Comment 80 · Organize 70 · Protect 60 · Print 55 · Scan & OCR 50 · Redo 45. Measured in the app at 100 %:

| Window | Bar | In "…" |
|---|---|---|
| 1700 | every group labeled | Redo |
| 1280 | Save, Undo, Pointer, Edit, Convert, Comment, Fill & Sign, labeled | Print, Redo, Organize, Protect, Scan & OCR |
| 1100 | icons only (3 DIPs short of the five labels) | Redo |
| 1200 at Text size 150 % | icons: Save, Undo, Pointer, Convert, Fill & Sign | the rest |

Then "…" lists rotate, delete pages and find, and Appearance under 1100. Every command stays in the menus and Ctrl+K.

**Keyboard and screen readers:** every group is a toggle button named after its label (`ShowBarGroups`, from the
table), with tooltip "Convert: Convert to Word (click for more)". Flyout items keep their name and a help text (the
line), and Tab and the menu keys work as today. No new letter keys: U for highlight (Acrobat) would be free, but
Ctrl+Shift+H already exists.

**Spanish:** Editar, Convertir, Comentar, Llenar y firmar (146 DIPs, the longest), Organizar, Proteger, Escanear y OCR.
At 1700, Scan & OCR goes into "…"; at 1280 the bar is icons only. A shorter "Firmar" would win back about 50 DIPs (open
question 3).

**Mac:** the same groups as `NSMenuToolbarItem`s. With an action and `showsIndicator`, the body runs the main job and
the arrow opens the menu: the split button for free. Proposed defaults: sidebar, Edit, Convert, Comment (today's
Highlight/Markup), Fill & Sign, Organize, Protect, Search. Scan & OCR goes in View › Customize Toolbar…, and the system's
» chevron is the overflow. Cmd replaces Ctrl.

## 3. Prototype and screenshots

Branch `t3/2df29816`: the new table in `CommandBarLayout` (tests updated, 43/43 green with `LocalizationTests`), the
groups in `MainWindow.xaml`, flyouts with sections, Draw inside Comment, and one-click Word (`Cmd.ConvertWord`,
`ExportActions.ConvertAtOnce`, a second link in `Toast`). Dev step `shellopen off` keeps a script from launching Word.
Taken with `--script`: `contract.docx`, then `contract (2).docx` on a second run.

- Bar: [1700 light](bar-1700-light.png) · [1700 dark](bar-1700-dark.png) · [1280](bar-1280-light.png) · [1100](bar-1100-light.png)
- Convert flyout: [light](convert-flyout-light.png) · [dark](convert-flyout-dark.png) · [Spanish](convert-flyout-es.png)
- "…": [1700 dark](more-1700-dark.png) · [1100 dark](more-1100-dark.png)
- One-click Word's notice: [light](convert-word-notice-light.png)
- Spanish bar: [1700](bar-1700-es.png) · [1280](bar-1280-es.png)

Left for the real change: split buttons; one-click Excel and PowerPoint; the main-job click of each group; the
read-only folder; removing the strings left unused (Bar_Draw, Bar_Redact, Main_Draw, Main_DrawTip, Main_RedactTip);
README "Command bar"; the Mac.

## 4. Open questions for the owner

1. **Split button** (1 click, recommended) or dropdown (2 clicks)?
2. **Narrow windows:** between about 1100 and 1270 DIPs the bar is icons only (today labels hold to about 1150). Accept
   this, or demote Edit below 80 so it goes into "…" first and the labels hold to about 1180?
3. **Spanish:** "Llenar y firmar" or a shorter "Firmar"?
4. The menu bar's **Edit** and **Organize** sit next to the bar's Edit and Organize groups. Keep both, or rename the
   bar's (e.g. "Edit text")?
5. Fill & Sign's main job: **Sign** (proposed) or Add text?
6. Are Pointer as icons only and Draw inside Comment OK?

## Sources

- [N1] Nitro PDF Pro, Explore the user interface (updated 2026-07-28): https://www.gonitro.com/user-guide/pro/article/explore-the-user-interface ; Ribbon shortcuts: https://www.gonitro.com/user-guide/pro/article/ribbon
- [N2] Nitro Pro 11 User Guide (Nitro's PDF, *old*): https://gemsoft.ro/wp-content/uploads/2017/09/Nitro-pro-11-user-guide.pdf
- [N3] Nitro, Convert PDF to Microsoft Word: https://www.gonitro.com/user-guide/pro/article/convert-pdf-to-microsoft-word (as indexed; the page now returns 404)
- [N4] Nitro, How to secure a PDF: https://www.gonitro.com/resources/how-to-secure-a-pdf
- [F1–F8] Foxit PDF Editor 13 User Manual: https://cdn01.foxitsoftware.com/pub/foxit/manual/phantom/en_us/foxit-pdf-editor-user-manual-13.pdf (Workspace; Export PDFs; Edit Text; Keyboard Shortcuts; Fill & Sign; Protect; Recognize Text and Combine Files; Organize and PDF Optimizer)
- [A1] Adobe, New Acrobat experience: https://helpx.adobe.com/acrobat/using/new-acrobat-experience.html
- [A2] Adobe, Convert PDFs to other formats (new experience): https://helpx.adobe.com/uk/acrobat/using/convert-pdfs-to-other-formats-new-experience.chromeless.html
- [A3] https://helpx.adobe.com/acrobat/desktop/e-sign-documents/manage-digital-signatures/certify-pdfs.html · [A4] https://helpx.adobe.com/acrobat/desktop/protect-documents/protect-with-passwords/add-passwords-to-pdfs.html · [A5] https://helpx.adobe.com/acrobat/desktop/protect-documents/redact-pdfs/redact.html · [A6] https://helpx.adobe.com/acrobat/using/create-verify-pdf-accessibility.html · [A7] https://helpx.adobe.com/acrobat/current/keyboard-shortcuts.html
- [X1] PDF-XChange Editor 11, Workspace Basics: https://help.pdf-xchange.com/pdfxp11/workspace-basics.html · [X2] Keyboard Shortcuts: https://help.pdf-xchange.com/pdfxp11/keyboard-shortcuts.html
- [G1] PDFgear Windows guide, Convert PDF to other formats: https://www.pdfgear.com/windows-user-guide/convert-pdf-to-other-formats.htm · [G2] https://pdfgear.com/windows-user-guide/password-protect-pdf.htm , https://www.pdfgear.com/windows-user-guide/compress-a-pdf.htm · [G3] https://www.pdfgear.com/mac-user-guide/redact-pdf.htm
