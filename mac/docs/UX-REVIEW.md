# UX review: Inkvolt PDF for Mac

A scored review of Inkvolt PDF for Mac against the current macOS standards, with **simplification first** (the owner
found that the app "seems complex at first glance"). Two rounds took it from 7.9 to 9.4; what they changed against
Windows is in `PLAN.md` (the Mac UX review's decisions). Inkvolt Print for Mac wasn't reviewed.

Everything was judged on the real app, rendered without a person at the screen (nobody sat at the Mac): the
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

## Scores (round 2, the latest)

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


## Plain words: renames proposed (not applied; both apps rename together)

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

## Text size

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

## Still short (why 9.4, not 9.5)

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
