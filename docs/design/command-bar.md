# Command bar: familiar groups, one click

Status: **approved by the owner 2026-11-08 and built for Windows** on branch `t3/2df29816` (not merged; the Mac comes
next, as its own task). The owner's brief is `docs/HANDOFF.md`, "Owner, 2026-11-08 (evening)", item 2.

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

## 2. Design

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
| Convert (EDE1) | **Word (.docx)**: see below | Excel (.xlsx), PowerPoint (.pptx) · Plain text, Web page (at once too) · Images…, PDF/A for archiving… |
| Comment (E90A) | Highlight the selection (Ctrl+Shift+H); with no selection, the highlighter tool | Underline, Strike out, Note, Stamp (S) · Draw › (pen P, highlighter M, rectangle R…) |
| Fill & Sign (E76D) | Sign: places your saved signature; **asks** the first time, to make one | Add text (A), Check (K), Cross (X) · Prepare Form |
| Organize (E8B3) | Organize Pages (Ctrl+Shift+O) | Insert (Ctrl+Shift+I), Extract (Ctrl+Shift+E), Split · Combine files, Reduce size |
| Protect (E72E) | Password: **asks** only for the password (a small window; AES-256, nothing restricted) | Redact (the selection marked at once; with none, the marking tool; Apply asks to confirm), Redact by Pattern, Check Redaction, Sanitize · Sign with certificate (**asks** for the ID) · Remove protection |
| Scan & OCR (E8C1) | Recognize Text on every scanned page, with Windows' recognizer; already-text pages are skipped | Scan to PDF (**asks** for the scanner), Insert from Scanner · Review Suspect Words |

**One click, Convert › Word** (Excel, PowerPoint, text and HTML too, from their flyout items). It saves `name.docx`
next to the PDF, never over a file (`name (2).docx`, through `PdfFiles.UniquePath`). It goes to Documents when the PDF
isn't saved yet or its folder can't be written to (`ExportTarget`), and the notice then says "Saved name.docx in
Documents". It uses all pages, with scanned pages recognized when Windows has a recognizer, and then opens the file.
The notice says **"Saved name.docx · Show in folder · Change options…"**; the last link opens the Export window.
**Shift+click** opens that window first, and so do File › Export and Ctrl+K. It still asks when the file is protected
(the "export anyway?" question) and says so when nothing could be read.

**Split button** (the owner's choice): every group with a main job is a Fluent split button. The body runs the main
job, so Convert › Word takes 1 click (Nitro 3, Acrobat 4), and the arrow opens the flyout. The pointer group is a plain
dropdown.

**Fitting** (`CommandBarLayout` rules, unchanged: lowest priority into "…" first; icons-only only when a group of
priority 80 or more would go). Priorities: Save, Undo 100 · Convert 90 · Fill & Sign 86 (Spanish 75) · Edit 84 ·
Comment 80 · Pointer 79 · Organize 70 · Protect 60 · Print 55 · Scan & OCR 50 · Redo 45. Measured in the app at 100 %:

| Window | Bar | In "…" |
|---|---|---|
| 1700 | every group labeled | Redo |
| 1280 | Save, Undo, Pointer, Edit, Convert, Comment, Fill & Sign, labeled | Print, Redo, Organize, Protect, Scan & OCR |
| 1100 | Save, Undo, Edit, Convert, Comment, Fill & Sign, labeled | the above and the pointer tools (H, T, G still work) |
| 1200 at Text size 150 % | icons: Save, Undo, Edit, Convert, Fill & Sign | the rest |
| Spanish 1280 and 1100 | Save, Undo, Pointer, Edit, Convert, Comment, labeled | Llenar y firmar goes first, then the same |

Then "…" lists rotate, delete pages and find, and Appearance under 1100. Every command stays in the menus and Ctrl+K.

**Keyboard and screen readers:** a group's body and arrow are both tab stops. Enter or Space runs the body; Alt+Down,
on either part, opens the flyout, and so does the arrow. Names: "Convert: Word (.docx)" (help text: the main job's
line) and "Convert: more commands (Alt+Down)". The arrow is 24 DIPs wide, the audit's smallest target (`a11yaudit`: 0
findings).

**Spanish:** Editar, Convertir, Comentar, Llenar y firmar (147 DIPs, the longest), Organizar, Proteger, Escanear y OCR.
The label stays, and the group goes into "…" before the others lose their labels.

**Colour** (approved 2026-11-08; the rest of the bar is monochrome). There are three touches:
- **File types:** Convert's Word blue, Excel green, PowerPoint orange and PDF/A grey, on our own document glyphs.
- **The tool in use:** Windows' accent, the same on the pointer group (when it isn't the hand) and on a group's body.
  The arrow is a plain button, so the accent never marks an open flyout.
- **Apply Redactions:** its icon is red, in Protect's flyout, in "…" and on the Redact bar's Apply button. That button
  is no longer an accent button, which a red icon couldn't sit on.

`BarColors` (Core) holds each colour with a dark-theme variant, tested at 3:1 or more against the flyout's and the
bar's backgrounds in both themes. `App.ApplyBarColors` sets them as resources, again when the theme, Windows'
light/dark or its high contrast changes. Under high contrast every one is the system text colour, and the accent comes
from Fluent's high-contrast theme. Labels always stay, so colour never carries meaning alone.

**Mac** (its own task): the same groups as `NSMenuToolbarItem`s. With an action and `showsIndicator`, the body runs
the main job and the arrow opens the menu. Proposed defaults: sidebar, Edit, Convert, Comment, Fill & Sign, Organize,
Protect, Search. Scan & OCR goes in View › Customize Toolbar…, and the system's » chevron is the overflow.

## 3. Built (Windows) and screenshots

Branch `t3/2df29816`, as approved on 2026-11-08:
- `CommandBarLayout`: the groups, each group's main job (`Entry.Main`, `HasMainJob`) and icon, `Command.AtOnce` and
  `IconBrush`, `RunAtOnce`, and `FillSignPriority`.
- `BarGroupButton`: the split button.
- `ExportTarget`: next to the PDF, or Documents.
- One-click paths: `ExportActions.ConvertAtOnce`, `SecurityActions.ProtectAtOnce`, `SignAtOnce`,
  `RecognizeText(atOnce)`, and Highlight with no selection.
- Dev steps: `barclick Id main` and `shellopen off`.

Screenshots, taken with `--script`. They are saved as taken: an earlier 256-colour reduction washed out the icons'
colours. The dev step `iconcolors` checks each coloured icon as drawn against its resource; it matched exactly in both
themes.
- Bar: [1700 light, Select in use](bar-1700-light.png) · [1700 dark, Edit in use](bar-1700-dark.png) · [1280](bar-1280-light.png) · [1100](bar-1100-light.png) · ["…" at 1100](more-1100-light.png)
- Flyouts: [Convert light](convert-flyout-light.png) · [Convert dark](convert-flyout-dark.png) · [Comment, with Draw](comment-flyout-light.png) · [Protect, Apply Redactions in red](protect-flyout-light.png)
- High contrast: [Convert](convert-flyout-highcontrast.png). This shot is the dev step `highcontrast on`: Fluent's own high-contrast resources over the light theme. Windows' High Contrast isn't switched on, because this PC is shared.
- One click: [Word's notice](convert-word-notice-light.png) · [Protect's password](protect-password-light.png) · [Comment with no selection: the highlighter](comment-main-light.png)
- Spanish: [1700](bar-1700-es.png) · [1280](bar-1280-es.png) · [1100](bar-1100-es.png) · [Convert](convert-flyout-es.png)

## 4. The owner's answers (2026-11-08)

1. Split buttons for every group with a main job (done).
2. Labels kept at the middle widths: lower-priority groups go into "…" first (done; the pointer tools give way at 1100).
3. Spanish keeps "Llenar y firmar" and lets it go into "…" sooner (done).
4. Both the menu bar's and the bar's Edit and Organize stay.
5. Fill & Sign's main job is Sign.
6. Yes to the icon-only pointer group and to Draw inside Comment.

Pending: the Mac (built 2026-11-09, below; for the owner to look at before it ships).

**Later (the owner's brief): Explorer's right-click "Convert to Word with Inkvolt PDF".** Built for Windows on 2026-11-10
(branch `t3/4964c14e`, not merged): `--convert-to word <files…>` (`ConvertCommand`, `ConvertQueue`, `ExplorerConvert`),
the one-click Convert › Word for each file, its notice in the open window, or a small window listing the files. A
declared verb on `.pdf` (the package's `uap3:Verb`, `install.ps1`'s `SystemFileAssociations` key), not an
`IExplorerCommand` DLL loaded into Explorer: so Windows 11 shows it under "Show more options", Windows 10 in the menu, and the Store build shows it only while Inkvolt PDF is the default PDF app (checked on this PC: registered on the package's ProgId, not listed with PDF-XChange as the default)
(Foxit's sits at the top of Windows 11's menu through such a DLL; that would be a native C++ project of its own). The Mac
(a Finder Quick Action or Services item) isn't built.

## 5. Mac (built 2026-11-09, branch `t3/b9736669`)

The same groups, order, main jobs and colours in the Mac's own toolbar: each group an `NSMenuToolbarItem` (icon and
label side by side, the body runs the main job, the arrow opens the menu, each item with its line under it), the
pointer tools an icon-only group, the toolbar's » as the overflow (labels never drop; Edit, Convert, Comment and Fill &
Sign stay longest). Option-click asks first (the Mac's Shift+click). Save, Print, Undo and Redo stay in the menus, as
on Mac toolbars. Details and the Mac differences: `mac/docs/PLAN.md`, "Command bar". Screenshots, taken by the app's
self-test (`--edit --only-command-bar --snapshots`, menus drawn while open):
- Toolbar: [light](mac/toolbar-light.png) · [dark](mac/toolbar-dark.png) · [1000 pt, the » overflow](mac/toolbar-1000-light.png)
- Menus: [Convert light](mac/convert-menu-light.png) · [Convert dark](mac/convert-menu-dark.png) · [Protect, Apply Redactions in red](mac/protect-menu-light.png) ([dark](mac/protect-menu-dark.png)) · [Comment, with Draw](mac/comment-menu-light.png) ([dark](mac/comment-menu-dark.png)). A menu's material is drawn by the window server, which the app can't capture: the shots paint a flat stand-in of its colour under the items
- One click: [Word's notice](mac/saved-notice-light.png)
- Spanish: [toolbar](mac/toolbar-light-es.png) · [1000 pt](mac/toolbar-1000-light-es.png) · [Convert](mac/convert-menu-light-es.png) · [notice](mac/saved-notice-light-es.png)

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
