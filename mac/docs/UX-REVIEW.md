# UX review: Inkvolt PDF for Mac

A scored review of Inkvolt PDF for Mac (1.5.0 plus `master` of 2026-11-03) against the current macOS standards, with
**simplification first**: the owner found that the app "seems complex at first glance". Inkvolt Print for Mac is on
hold and in App Review, and was not touched. Round 1 (branch `mac-ux`, merged after the owner looked at its shots) took
it from 7.9 to 9.0; round 2 (branch `mac-ux-2`, not merged; below) every sheet and alert, the markup bar, the zoom and
text size: 9.0 to 9.4.

Everything was judged on the real app, rendered without a person at the screen (nobody sat at `ignia-mac`): the
`--ux-shots` dev step (below) draws the document window, the start page, Settings and the command palette to PNG with
AppKit's own drawing, title bar and toolbar included, in light, dark and Increase Contrast, at 1100 × 820 and 640 × 600;
lists the whole menu bar; and audits every control of those windows for a name VoiceOver can say. Scores are judged,
not measured; each names what earned it or what still holds it back.

Standards consulted (2026-11-03): Apple's Human Interface Guidelines for macOS: Toolbars (leading edge for the sidebar
button and title, common controls in the middle, search and essential items on the trailing edge, "choose items
deliberately to avoid overcrowding", "aim for a maximum of three" groups, every toolbar item also a menu command,
customization for apps with many commands, system symbols without borders); Settings ("App Name Settings" as the
title with a single pane, minimize and zoom dimmed, restore the last pane, no settings button in toolbars); Sidebars
(macOS 26's Liquid Glass: sidebars and toolbars float above the content; "avoid hiding the sidebar by default"; no more
than two levels); the Liquid Glass guidance to drop custom toolbar backgrounds and tints and let the system's materials
draw the bars. Nielsen Norman Group's 10 heuristics. And what Mac users know from Preview first (a seven-item toolbar:
sidebar, zoom, share, highlight, rotate, Markup, search; the markup tools in a second bar shown with ⇧⌘A; Tools ›
Annotate), then PDF Expert (a mode bar: View, Annotate, Edit, Fill & Sign) and Acrobat for Mac (a few tools in sight,
"All tools" behind one button).

## Rubric

The Windows review's fourteen criteria (`docs/UX-REVIEW.md`), re-weighted for the Mac: criterion 4 is consistency with
the current macOS HIG (it was Fluent 2); minimalist design weighs more (the owner's first aim); target size weighs less
(no touch on the Mac: pointer targets and crisp symbols only). Weights sum to 100; the app's score is the weighted mean.

| # | Criterion | Weight | Source |
|---|---|---|---|
| 1 | Visibility of system status | 8 | NN/g H1 |
| 2 | Plain words, no jargon | 6 | NN/g H2 |
| 3 | Control and freedom: undo, safe defaults | 8 | NN/g H3, H5 |
| 4 | Consistency with the macOS HIG (toolbar, sidebar, settings, menus, sheets, SF Symbols, Liquid Glass) | 9 | NN/g H4; HIG |
| 5 | Recognition over recall | 8 | NN/g H6 |
| 6 | Flexibility and efficiency: shortcuts, palette, customization | 6 | NN/g H7 |
| 7 | Aesthetic and minimalist design: what is on screen by default | 9 | NN/g H8 |
| 8 | Errors and dialogs: verbs on buttons, what to do next | 7 | NN/g H9; HIG Alerts |
| 9 | Empty, loading and error states | 6 | NN/g H1, H10 |
| 10 | Keyboard and focus | 8 | HIG Keyboard; WCAG 2.1.1, 2.4.7 |
| 11 | Accessible names (VoiceOver) | 8 | HIG Accessibility; WCAG 4.1.2 |
| 12 | Contrast and themes: light, dark, Increase Contrast | 6 | HIG Dark Mode, Color |
| 13 | Pointer targets, crisp at any scale | 4 | HIG Layout; SF Symbols |
| 14 | Responsiveness: narrow windows, window state | 7 | HIG Windows; WCAG 1.4.10 |

## Scores

| # | Criterion | Before | After | Evidence and change |
|---|---|---|---|---|
| 1 | Status | 8.5 | 8.5 | "Page 1 of 3" under the title, the notice bar with Undo, progress sheets. Unchanged; the zoom level still shows nowhere but the menu's checkmarks. |
| 2 | Plain words | 8.5 | 9.0 | The Tools menu now reads by task (Annotate, Fill & Sign, Redact, Forms, Measure, Accessibility). Jargon left in menus: PDF/A-2b, Flatten, Sanitize Document, Suspect Words (the Windows names; renaming is a both-apps decision). |
| 3 | Control | 9.0 | 9.0 | Undo for every edit, the close question, recovery copies. Settings lost its Cancel with apply-at-once, as every Mac app's; Reset to Defaults stays. |
| 4 | macOS HIG | 6.0 | 9.0 | Before: no window toolbar at all; a custom strip of 26 tool glyphs in the content (`before/doc-light.png`); Settings with Save and Cancel, titled "Settings"; the command palette with traffic lights; two Open Recent items in File; no Share. After: a unified, customizable NSToolbar (sidebar button and title leading, zoom, then Highlight, Markup, Fill & Sign, Share and Search trailing; a tracking separator over the sidebar's edge; `after/doc-light.png`), Liquid Glass from the system (no custom bar background), Settings applying at once and titled "Inkvolt PDF Settings" (`after/settings-light.png`), the palette without window buttons (`after/palette-light.png`), one Open Recent, File › Share…. Short: the markup bar is still a custom strip, not an NSToolbar of its own. |
| 5 | Recognition | 8.0 | 9.0 | Toolbar items have labels (shown in Customize Toolbar and Icon and Text mode) and tooltips with their shortcuts; the palette lists the document's commands first (it opened on About, Check for Updates, Hide Others); the start page names four tools. |
| 6 | Flexibility | 9.0 | 9.5 | Customize Toolbar… (18 items: Edit, Redact, Organize, Rotate, Inspector, Print, Commands, Go to Page and the defaults), ⇧⌘A for the markup bar, ⌥⌘T for the toolbar, every single-key tool kept (the submenus are `ToolsMenu`s too). |
| 7 | Minimalist | 5.5 | 9.0 | Before, every window showed 26 tool glyphs in 7 groups plus a color and a width pop-up, a 7-symbol sidebar picker with 3 of them greyed out; the start page ten tool cards; the Tools menu 58 items in one list, File 29. After: 7 toolbar items and nothing else over the pages; the markup tools come when asked (Markup, ⇧⌘A, or any tool picked from its menu or key); the sidebar picker shows only the panes the document has (4 for a plain PDF); the start page has Open, Recent and four tools, the other six behind Show All Tools (`after/start-light.png`, `after/start-more-light.png`); Tools 14 items, File 25 (with Share… added). |
| 8 | Errors and dialogs | 8.5 | 8.5 | Not re-shot this pass: the sheets' buttons already carry verbs (Save Changes, Apply Redactions, Insert Pages). |
| 9 | Empty states | 8.5 | 8.5 | The start page's "Files you open will appear here" with the ⇧⌘K tip; Combine's empty list. Unchanged. |
| 10 | Keyboard and focus | 8.5 | 9.0 | The toolbar is reachable with Full Keyboard Access; ⇧⌘A and ⌥⌘T added; Escape closes the palette. |
| 11 | Accessible names | 8.0 | 9.5 | The audit found 5 controls VoiceOver couldn't name: the markup bar's Color and Line width pop-ups, Settings' App theme and Open documents at pop-ups, the palette's search field (AppKit reports the cell, which the label hadn't reached; `before/report.txt`). Every audited window reports 0 now, the markup bar included (`after/report.txt`): `setAccessibleName` names control and cell. |
| 12 | Contrast and themes | 9.0 | 9.0 | Light and dark follow the Mac or Settings, dark pages. Increase Contrast can't be told apart in an off-screen drawing (`after/doc-contrast.png` looks like light): a person must look. |
| 13 | Targets and crispness | 9.0 | 9.0 | SF Symbols throughout; toolbar items at the system's size. |
| 14 | Responsiveness | 6.0 | 9.0 | A document window couldn't be narrower than about 1,300 points: the markup strip's full width, and Prepare Form's hidden bar (618 points), set the window's minimum through the content stack, so on a 13-inch Air a PDF couldn't share the screen with another app (`before/report.txt`: asked 640, got 1,313). Now about 624: the markup groups drop from the right as the window narrows (each tool stays in the menu), and every bar may clip rather than widen the window (`after/doc-narrow-light.png`). Window size and tabs restore as before. Short: AppKit has no app-wide text size; the largest Accessibility text size isn't covered. |
| | **Weighted** | **7.9** (7.87) | **9.0** (8.97) | |

## Findings, ranked by user impact, and what was done

First-glance complexity first.

1. **Twenty-six tool glyphs on every window** (H8, HIG Toolbars). The tool strip showed every comment, drawing, stamp,
   Fill & Sign, edit and redaction tool, with Color and Line width, above every document, read-only ones included.
   Preview shows seven toolbar items and keeps its markup tools in a bar of their own. Now: `WindowToolbar.swift` (an
   NSToolbar, `ToolbarLayout.defaults` in PdfCore, tested), the strip hidden by default as the markup toolbar
   (`AppSettings.markupShown`), shown by the Markup button, View › Show Markup Toolbar (⇧⌘A, Preview's), or by picking
   any markup tool (`revealMarkup`); hiding it goes back to Select Text. Highlight in the toolbar highlights the selected
   text at once, or picks the highlighter (Preview's button). Fill & Sign picks Add Text.
2. **No window toolbar, no zoom or search in sight** (H4, H6). Zoom and Find were in menus only. The toolbar has zoom out
   and in, Search (⌘F's find bar) on the trailing edge, Share (the system picker; also File › Share…).
3. **Ten cards on the start page** (H8). Open a file, then Recent (what a person comes back for), then four tools (Fill &
   sign, Edit text & images, Combine files, Create a PDF); Export to Word, Compare, Protect, Recognize text, Organize and
   Batch behind Show All Tools (remembered). The recent card shows its folder's name, not its whole path (it wrapped
   over five lines). The caption is one sentence.
4. **The Tools menu: 58 items in one list** (H8, H4). Fourteen now: Hand and Select Text, then Annotate, Fill & Sign,
   Edit Text & Images, Redact (every redaction command, the checks and Sanitize with it), Recognize Text and Review
   Suspect Words, Forms, Measure, Accessibility, AI Assistant, then Show Inspector and Command Palette. Nothing removed;
   every tool keeps its single key and every command its shortcut. File: the four New PDF commands in a New PDF submenu,
   the two PDF/A saves in Save as PDF/A, Batch and Watched Folders moved near the end, Share… added.
5. **Sidebar picker with greyed-out symbols** (H8). Signatures, Layers and Suspect Words were always there, disabled on
   most files. The picker now holds only the panes the document offers: Pages, Bookmarks, Comments, Attachments, plus
   Signatures, Layers, Suspect Words and Accessibility once there is something to show (`SidebarController.panes`).
6. **Windows that wouldn't narrow** (criterion 14). See the score above: hidden bars no longer set the window's minimum.
7. **Settings with Save and Cancel** (H4). macOS settings apply as they change: each control applies at once, the author
   name as it is typed; Reset to Defaults applies at once; the window is titled "Inkvolt PDF Settings" (HIG, one pane);
   the AI line no longer runs off the right edge.
8. **Command palette** (H4, H6). The shortcut column was cut off at the right ("⌘" without its letter); the title column
   now takes what the shortcuts leave. No window buttons (Escape closes it). The document's menus come first; Hide,
   Hide Others, Show All, Quit and Clear Menu are left out.
9. **Two Open Recent items** in the File menu (H4): AppKit added its own beside the app's; the app's submenu is now named
   as AppKit's recent-documents menu, so AppKit fills that one.
10. **Nameless controls** (criterion 11): five, see the score. The audit (`AxAudit`, PdfCore, tested) leaves out AppKit's
    own window, tab-bar and scroller buttons, which VoiceOver names outside the app's view tree.

## Still short after round 1 (round 2 below took up each)

- **Sheets and dialogs weren't re-shot** (criteria 8, 9): `--ux-shots` covers the four main windows. Every sheet
  (Protect, Reduce File Size, Redact by Pattern, Batch, Compare…) still needs a look at the HIG's sheet layout, and its
  empty and error states.
- **No person at the screen**: Liquid Glass's look, the toolbar's overflow menu at narrow widths, Customize Toolbar's
  sheet, the tab bar under the unified toolbar, Increase Contrast and Reduce Motion were not seen live; nor was
  VoiceOver run by hand (only the AX tree was read).
- **The markup bar is a custom strip** rather than a second NSToolbar or a toolbar item group, and its Color and Width
  pop-ups aren't the system's color well.
- **Jargon kept for parity with Windows**: PDF/A-2b and 2a, Flatten, Sanitize Document, Suspect Words, Calibrate Scale
  from a Known Length. Renaming belongs to both apps.
- **Text size**: AppKit has no Dynamic Type; the largest Accessibility text size (macOS 26's per-app text size) wasn't
  checked.
- **Status**: no zoom percentage in sight.
- **Trackpad gestures, Quick Look, Services**: not reviewed this pass (pinch zoom works through NSScrollView's
  magnification already).

## Round 2 (2026-11-03, branch `mac-ux-2`)

Round 1's "Still short" list, simplification first again: every sheet, panel and alert shot and fixed, the markup bar
made system-native, the zoom in sight, the text size checked, plain words proposed. Not merged; the owner reviews the
shots first (`ux-review/round2/before`, `ux-review/round2/after`).

Standards consulted (2026-11-03, the HIG's own pages): **Sheets** ("present a sheet in a reasonable default size",
"display only one sheet at a time", "for complex or prolonged user flows, consider alternatives to sheets"); **Alerts**
("write a title that clearly and succinctly describes the situation… avoid … 'Error'", "include informative text only if
it adds value", "aim for a one- or two-word title that describes the result of selecting the button", "Avoid using OK as
the default button title unless the alert is purely informational", the default button trailing, Cancel leading, Escape
cancels); **Disclosure controls** ("hide details until they're relevant", "more advanced functionality hidden by
default", a triangle labeled with what it shows, such as "Advanced Options"); **Toolbars** (round 1's); Apple's support
page *Make text and icons bigger* (Accessibility › Display › Text size: "a single preferred size for text across
multiple apps", applied "on the desktop, in app sidebars, and in the apps listed").

How: `--ux-shots` now drives every dialog of the document window as a person would (its menu command), waits for the
sheet, the modal alert or the window it opens, shoots it in light and dark, audits it, notes its Return and Esc buttons,
then cancels it (`UxDialogs.swift`); a second state where there is one (Go to Page's problem; More Options open). 31
dialogs, 98 shots in all, under `ux-review/round2/`. The dialogs' shots were each looked at. AppKit's `cacheDisplay`
doesn't draw an alert's material (the window server does), so the first dark shots showed white text on nothing: the
shots are now laid on the window's background color; the "before" set keeps only the light alerts for that reason.

### Scores, round 2

"Before" is round 1's "after".

| # | Criterion | Weight | Before | After | Evidence and change |
|---|---|---|---|---|---|
| 1 | Status | 8 | 8.5 | 9.5 | The zoom shows in the window's subtitle beside the page, as a percentage when it isn't 100 % ("Page 1 of 3 · 134%", `round2/after/doc-light.png`), `WindowStatus` in PdfCore, tested. Progress sheets shot (`progress-light.png`): a title, what it's doing, a bar, Cancel. |
| 2 | Plain words | 6 | 9.0 | 9.0 | The dialogs say it plainly now: Reduce File Size's "downsampled… JPEG, identical streams merged… unused objects" is "Makes the file smaller, mostly by storing its pictures at a lower resolution", its pop-up "Medium (150 dpi, for e-mail)"; "XMP metadata" became "document details"; Sign Digitally's "hash" and "distinguished name" are gone; Recognize Text's seven-line paragraph is one sentence. The jargon left is in command names (PDF/A-2b, Flatten, Sanitize Document, Suspect Words, Calibrate…), now with a plain note as their tooltip; the renames are proposed below, so the score waits for them. |
| 3 | Control | 8 | 9.0 | 9.5 | Every one of the 31 dialogs has Cancel and closes with it (the step cancels each one that way; none changed the document). Protect can't be pressed with nothing chosen; the progress sheet's Cancel stops the work. |
| 4 | macOS HIG | 9 | 9.0 | 9.5 | The markup bar is a titlebar accessory under the toolbar, in the toolbar's material (Liquid Glass), the system drawing its background and edge, as Preview's (`after/doc-markup-light.png`; it was a strip in the content painted with the window's color); its color is the system's color well (swatches and Show Colors…), its width a standard pop-up. Sheets follow the HIG's layout: labels right-aligned with a colon, the controls after, sized to what they hold (Header & Footer's rows were clipped and unlabeled, `before/header-footer-light.png`; Flatten's last box cut off; Sanitize was a 520-point panel half blank), no stacked three-button alerts (Document Properties). |
| 5 | Recognition | 8 | 9.0 | 9.5 | Every dialog control has a visible label (Reduce's and OCR's pop-ups had none); the page choice shows its range box only for Page range (it showed "1" beside "All pages"); Batch's empty lists say what to do. |
| 6 | Flexibility | 6 | 9.5 | 9.5 | Unchanged; More Options remembers being open, per dialog. |
| 7 | Minimalist | 9 | 9.0 | 9.5 | Dense dialogs keep the common choices in sight and the rest behind More Options with good defaults: Sign Digitally 12 rows → 4, Header & Footer 7 rows of fields → 4, Recognize Text 5 options + 7 lines of text → 2 + 1 sentence, Redact by Pattern's own pattern and case, Reduce File Size 4 → 1, Watermark 9 → 6, Batch's 5 result options; Split shows only the rows of the way you split; Sanitize lists only what the document holds (on a plain file: 11 greyed-out boxes in 5 groups → one line). Nothing removed. |
| 8 | Errors and dialogs | 7 | 8.5 | 9.5 | The titles state the situation, the buttons are verbs (Reduce, Flatten, Find and Mark, Sign, Recognize, Export…), OK only on information. Errors no longer show a debug dump: "The document couldn't be saved." had "Error Domain=NSCocoaErrorDomain Code=513 …" possible through `"\(error)"`; `NSAlert.plainText` over `ErrorWords` (tested) gives the system's sentence or a fallback that says what to do. Go to Page says "There's no page “99”. Type a page from 1 to 3." (`after/go-to-page-error-light.png`). |
| 9 | Empty states | 6 | 8.5 | 9.5 | Batch: "No files yet. Drop PDFs or folders here, or choose Add Files…" and "No actions yet…" over the lists, no idle progress bar (`after/batch-light.png`); Sanitize: "Nothing hidden found" and what the document doesn't hold; Sign Digitally without a digital ID says where to make or import one; Combine's empty list (round 1). |
| 10 | Keyboard and focus | 8 | 9.0 | 9.5 | Every question has a Return button and an Esc button (the report names both for each shot: `after/report.txt`); the windows (Batch, Report a Problem) close with ⌘W, the one-button error alert with Return, the progress sheet's Cancel with Esc. More Options is a focusable disclosure triangle. |
| 11 | Accessible names | 8 | 9.5 | 9.5 | The audit of the dialogs found 88 controls VoiceOver couldn't name (fields and pop-ups after a "Label:", passwords; `before/report.txt`); `DialogNames` names each from the label beside it when a window becomes key: 0 left (`after/report.txt`). VoiceOver itself not run by hand. |
| 12 | Contrast and themes | 6 | 9.0 | 9.5 | Every dialog shot and looked at in dark mode too (`after/*-dark.png`); nothing custom-colored in them but the red problem lines. Increase Contrast still not seen on a screen. |
| 13 | Targets and crispness | 4 | 9.0 | 9.0 | Unchanged: SF Symbols, system controls; the markup segments 28 points wide. |
| 14 | Responsiveness, text size | 7 | 9.0 | 9.0 | The markup bar as an accessory still drops its groups from the right in a narrow window. Text size: see below; only the sidebars can follow it. |
| | **Weighted** | | **9.0** (8.97) | **9.4** (9.42) | |

### Findings, round 2, ranked by user impact

1. **Dense sheets** (H8, HIG Disclosure controls). Sign Digitally, Header & Footer, Recognize Text, Redact by Pattern,
   Watermark, Reduce File Size and Batch showed every option at once. `SheetForm` (an alert's controls in the HIG's
   layout) puts the advanced ones behind a More Options triangle that remembers per dialog; good defaults kept.
2. **Clipped and unlabeled dialogs** (HIG Sheets, criterion 4). Header & Footer (`before/header-footer-light.png`):
   the header and footer labels missing, fields cut off; Flatten's last checkbox and Split's note cut at the right;
   Sanitize a 520-point panel with half of it blank; fixed frames on the accessory views. Every dialog now sizes to what
   it holds.
3. **Debug dumps in error alerts** (H9, HIG Alerts). `showError`, a document that wouldn't open, PDF/A and Batch put
   `"\(error)"` in the text. `ErrorWords` keeps the system's sentence (and its reason or suggestion once, not twice) or
   says what to do.
4. **88 nameless dialog controls** (criterion 11): `DialogNames`.
5. **The markup bar's look** (HIG Toolbars, Liquid Glass): a titlebar accessory now, the system's color well.
6. **Jargon in dialogs** (H2): see row 2; renames below.
7. **Sanitize's wall of "none found"**; **Batch's blank lists**; **Go to Page's** "Enter a page from 1 to 3." without
   saying what was wrong; **the page range box** beside "All pages"; **Document Properties' three stacked buttons**.
8. **No zoom in sight**: the subtitle.

### Plain words: renames proposed (not applied; both apps rename together)

The Mac shows each note as the command's tooltip now (`PlainWords` in PdfCore, tested: no note uses the word it
explains).

| Now (both apps) | Proposed | The note shown now |
|---|---|---|
| Save as PDF/A-2b… | Save as Archive Copy (PDF/A)… | Saves a copy made to be kept for years: fonts and colors inside the file, nothing that can change. |
| Save as PDF/A-2a (Accessible Archive)… | Save as Accessible Archive Copy (PDF/A)… | An archive copy that also keeps the reading order and headings for screen readers. |
| Flatten… | Make Comments & Fields Permanent… | Draws comments and form fields into the pages, so nobody can move or change them. |
| Sanitize Document… | Remove Hidden Information… | Removes what the file carries besides its pages: hidden text, attachments, scripts, authors and dates. |
| Review Suspect Words | Check Uncertain Words | Words the text recognition wasn't sure of, to check against the scan. |
| Calibrate Scale from a Known Length | Set Scale from a Known Length… | Draw along something whose real length you know, so measurements show real sizes. |

Acrobat says "Flatten" too and Preview has none of these, so "PDF/A" stays in brackets for people who search for it.

### Text size

macOS's Text size (System Settings › Accessibility › Display) sets "a single preferred size for text across multiple
apps", applied "on the desktop, in app sidebars, and in the apps listed" there; the list is Apple's own apps, and a
third-party AppKit app can't join it (AppKit has no Dynamic Type: `NSFont.preferredFont(forTextStyle:)` doesn't follow
the setting, and system controls draw at their fixed sizes). What AppKit does follow is the **sidebar size**: source-list
tables with the default row size take the system's small, medium or large size. The thumbnails' and bookmarks' lists
already did; the comment list had a fixed 11-point custom row and now follows it (`SidebarText`, tested; medium is the
size it always had). Run with the sidebar at Large (`-NSTableViewDefaultSizeMode 3 --ux-main`): the main windows' 16 shots, 0 audit findings;
its shot shows the thumbnails pane, which has no text rows, and the synthetic document has no comments, so the comment
list's larger rows are tested (`SidebarText`) but not seen. Everything else stays at the system's sizes; the pages have their own zoom. Windows (round 2) follows
its Text size everywhere because WPF lets it; the Mac can't without its own text-size setting, which would be a design
change.

### Still short after round 2 (why 9.4, not 9.5)

- **Plain words (criterion 2)**: the command names; the renames above wait for the owner and for Windows.
- **Text size (14)**: AppKit can't follow it beyond the sidebars (above).
- **No person at the screen**: Liquid Glass under the markup accessory, the color well's popover, the toolbar's
  overflow, Customize Toolbar's sheet, Increase Contrast, Reduce Motion, VoiceOver by hand, the More Options triangle
  growing a sheet that is already showing (shot only after it settled), and the system's save and open panels (not
  drawable off-screen).
- **Not driven**: the AI pane's own windows beyond its settings sheet, Watched Folders, the Accessibility Check's pane
  (its progress sheet is the shared one), the close question (the system's), Compare's result window.
- **Targets (13)**: unchanged at 9; nothing found to fix.

## How to reproduce

On the Mac (or from the PC, `bash mac/tools/mac.sh pdf-app`, then over SSH):

```sh
open -n -a "Inkvolt PDF" --args --self-test /tmp/ux.txt --snapshots /tmp/ux --ux-shots --synthetic --quit
```

`/tmp/ux.txt` gets one line per shot, the menu bar (each menu with its items and shortcuts), each window's audit
(controls seen, findings), and the window sizes asked and got; `/tmp/ux/*.png` the shots: `doc-{light,dark,contrast}`,
`doc-narrow-{light,dark}`, `doc-markup-light`, `doc-find-light`, `start-{light,dark,contrast}`, `start-more-light`,
`settings-{light,dark,contrast}`, `palette-{light,dark}`; and since round 2 each dialog in light and dark
(`go-to-page`, `go-to-page-error`, `properties`, `protect`, `reduce`, `flatten`, `header-footer`, `watermark`, `crop`,
`extract`, `split`, `redact-pattern`, `sanitize`, `ocr`, `export-word`, `export-text`, `signature-draw`,
`signature-type`, `sign-digitally`, `ai-settings`, `ai-summarize-not-set-up`, `scanner`, `compare`, `batch`,
`combine-empty`, `report-problem`, `web-page`, `password-open`, `password-wrong`, `password-permissions`, `error-save`,
`progress`; a `-more` shot where More Options opens), each with a report line giving its size, its buttons and which of
them Return and Esc press. `--ux-main` leaves the dialogs out. Only the app's synthetic documents are shown, never a
real file.
The shots and reports kept here: `ux-review/before/` (master at 44fac72, plus the dev step) and `ux-review/after/`;
round 2's under `ux-review/round2/before/` (master at 261ff4c plus the dialog step) and `ux-review/round2/after/`.
