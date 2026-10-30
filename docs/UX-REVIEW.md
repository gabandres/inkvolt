# UX review: Inkvolt PDF and Inkvolt Print

A scored review of both apps' UX and UI against the current desktop standards, the fixes it led to, and the score after
them. Everything was judged on the real UI: every window, pane, dialog and state was rendered off-screen with the apps'
own dev aids (Inkvolt PDF's `--script`, Inkvolt Print's `--demo --snapshot`), in light and dark, at 1400 × 900, 1180 × 800
and 900 × 620, plus a UI Automation audit of every visible control (the `a11yaudit` step and `--a11y-audit` switch added
for this review). The review ran in two passes on 2026-10-30; the scores below are before the first and after the
second. The scripts and the before/after shots that carry the findings are in `docs/ux-review/`; the full set reproduces
with the scripts there. Scores are judged, not measured: each half point names what earned it or what still holds it
back.

Standards consulted (current pages, 2026-10-30): Nielsen Norman Group's 10 usability heuristics; Microsoft's Windows 11
design principles, layout, typography (Segoe UI Variable, the type ramp: caption 12, body 14, subtitle 20, title 28),
iconography (Segoe Fluent Icons), color and materials (Mica), dialogs and commanding guidance; WCAG 2.2 AA (contrast,
2.4.7 focus visible, 2.5.8 target size minimum 24 × 24, 2.1.1 keyboard, 4.1.2 name/role/value, 1.4.4 resize text);
Microsoft's accessibility guidance for WPF (UIA names, AutomationProperties, Narrator); and what people expect from
Acrobat, PDFgear, Sumatra, Edge's PDF viewer and PDF Expert (toolbar, find bar, side rail, tabs, context menus,
shortcuts, drag and drop, recent files, undo, recovery).

## Rubric

Fourteen criteria, weighted to 100. Each is scored 0–10 per app; the app's score is the weighted mean.

| # | Criterion | Weight | Source |
|---|---|---|---|
| 1 | Visibility of system status: progress, counts, what just happened, what is busy | 8 | NN/g H1; Windows progress guidance |
| 2 | Plain words, the person's vocabulary, no jargon | 6 | NN/g H2; Windows text guidance |
| 3 | Control and freedom: undo everywhere, safe defaults, confirmation before loss | 8 | NN/g H3, H5 |
| 4 | Consistency with Windows 11 / Fluent 2: 4-px grid, type ramp, Segoe Fluent Icons, Mica, controls | 8 | NN/g H4; Windows 11 design principles |
| 5 | Recognition over recall: labels, placeholders, tooltips with shortcuts, discoverable commands | 8 | NN/g H6; WinUI commanding |
| 6 | Flexibility and efficiency: shortcuts for everything, a command palette, Help that lists them | 7 | NN/g H7 |
| 7 | Aesthetic and minimalist design: nothing on screen that isn't earning its place | 6 | NN/g H8 |
| 8 | Errors and dialogs: the question as the title, verbs on the buttons, what to do next, no stack traces | 8 | NN/g H9; Windows dialog guidance |
| 9 | Empty, loading and error states that say what to do next | 6 | NN/g H1, H10; WinUI empty-state guidance |
| 10 | Keyboard operability and visible focus: every control reachable, Fluent focus ring, F6 between regions | 8 | WCAG 2.1.1, 2.4.7, 2.4.11 |
| 11 | Accessible names and structure: every control has a name a screen reader can say; live regions | 8 | WCAG 4.1.2; WPF accessibility guidance |
| 12 | Contrast and themes: light, dark, follows Windows, high contrast | 6 | WCAG 1.4.3, 1.4.11; Windows color guidance |
| 13 | Target size, touch and pen, crisp at any DPI (vector icons) | 6 | WCAG 2.5.8; Windows iconography |
| 14 | Responsiveness: narrow windows, scaling, window state memory, motion short and reducible | 7 | Windows layout guidance; WCAG 1.4.4, 2.3.3 |

## Inkvolt PDF

### Scores

| # | Criterion | Before | After | Evidence and change |
|---|---|---|---|---|
| 1 | Status | 9.0 | 9.5 | Toasts, taskbar progress, dirty dot, "7 of 10" in Find, pane counts. The palette now says when nothing matches instead of going blank. |
| 2 | Plain words | 9.0 | 9.5 | Menus, dialogs and tips read in plain words ("Make a PDF small enough to e-mail"). Sanitize and Reduce said "XMP metadata", "rewritten as a single version" and "unused objects" (`before/pdf-dlg-sanitize.png`); they say "document properties (title, author, keywords…)", "saved afresh, so nothing of its earlier versions stays in it" and "leftover pieces of earlier edits" now. |
| 3 | Control | 9.5 | 9.5 | Undo for every edit, Undo in the toast, "Save changes to X?" with Save / Don't save / Cancel, recovery copies. A "Delete 1 page · Undo" toast outlived its document and showed on the start page (`before/pdf-toast-after-close.png`); toasts now go with the document they came from (`after/pdf-toast-after-close.png`). |
| 4 | Fluent consistency | 9.0 | 9.5 | Mica, tabs in the title bar, Segoe Fluent Icons, 34-px flat buttons on the 4-px grid, the type ramp. Toasts and the command palette now arrive with Fluent's "fast" motion (167 ms, decelerate) instead of blinking on. Settings still applies on Save rather than at once (see "Still short"). |
| 5 | Recognition | 7.5 | 9.5 | Search, Find, the comment filter and the shortcuts filter were empty boxes (`before/pdf-pane-search.png`); they show what goes in them now (`after/pdf-pane-search.png`). The Combine list says "No files yet". |
| 6 | Flexibility | 9.5 | 9.5 | Ctrl+K palette, every shortcut listed in Help from the menus themselves, letter keys for tools. |
| 7 | Minimalist | 9.0 | 9.0 | One-row command bar that overflows, floating pill, panes on demand. |
| 8 | Errors and dialogs | 8.5 | 9.5 | Information and error dialogs closed with "OK"; they say Close now (`after/pdf-dlg-updates.png`). Questions already had verbs. |
| 9 | Empty states | 8.0 | 9.5 | The palette's no-match state was blank (`before/pdf-palette.png`), now it says why and what to try (`after/pdf-palette-nomatch.png`); the Batch actions hint was clipped mid-sentence (`before/pdf-batch.png` → `after/pdf-batch.png`). |
| 10 | Keyboard and focus | 8.0 | 9.5 | The side rail (Pages, Bookmarks, Search, Comments…) was `Focusable=False`: not in the Tab order, and F6's hand-off to it did nothing. It is focusable with the Fluent focus ring now. |
| 11 | Accessible names | 8.0 | 9.5 | The audit found 31 nameless boxes across Settings, Document Properties, Header & Footer, Watermark, Export, Crop, Protect, Reduce (a labeled row didn't pass its label to the control). Every audited window reports 0 findings now. |
| 12 | Contrast and themes | 9.5 | 9.5 | Light, dark, Windows setting, dark pages, high-contrast palette for the page view. |
| 13 | Targets and DPI | 9.5 | 9.5 | Icon glyphs (vector), 34-px buttons, 24-px tab close; the audit found no target under 24 × 24. |
| 14 | Responsiveness | 8.5 | 9.5 | The Accessibility pane's tab headers wrapped into two rows (`before/pdf-a11y.png` → `after/pdf-a11y.png`); What's New's scrollbar covered the text. Windows' *Text size* (Settings › Accessibility) was ignored: WPF follows only the display scale. Dialogs, the command bar, the start page, the side rail and panes, the find bar, the info bars, toasts and the palette now scale with it, and dialogs widen to match (`after/pdf-reading-textsize150.png`, `after/pdf-start-textsize150.png`); the page view keeps its own zoom. The motion above is off when Windows' Animation effects is. Window position, size and state are remembered. |
| | **Weighted** | **8.7** | **9.5** (9.47) | |

### Findings, ranked by impact, and what was done

1. **Side rail not keyboard-reachable** (H10). `RailButton` had `Focusable=False`; `FocusPane()` already tried `PagesRail.Focus()` for F6, which silently failed. Now focusable with `DefaultControlFocusVisualStyle` (`pdf/src/InkvoltPdf.App/App.xaml`).
2. **Nameless controls in dialogs** (H11). `FormDialog.Add(label, control)` drew the label but didn't name the control; `PageRangePicker`, `PositionPicker`, the Crop margins and Document Properties' read-only boxes had none either. Fixed at the source (`Dialogs.cs`, `Organize.cs`, `FileActions.cs`), so every future dialog row is named.
3. **Command palette blank on no match** (H1, H9). `PaletteText.NoMatch` (Core, tested) says "Nothing matches 'x'…" and, with no document open, that the document commands come once a file is open.
4. **No placeholders** (H5). A `Placeholder.Text` attached property (adorner, follows the box's font and padding, hides with the box, names an unnamed box) on Search, Find, the comment filter and the shortcuts filter.
5. **"OK" on dialogs that only inform** (H8). `Prompt.Info` / `Prompt.Error` say Close.
6. **Accessibility pane tabs wrapping** (H14). "What fails (22)" and "For a person" became "Fails (22)" and "Checklist".
7. **Scrollbar over text** in What's New (H14): padding for the scrollbar.
8. **Batch empty hint clipped** (H9): the action list wraps.
9. **Combine's empty list** (H9): "No files yet. Press Add Files…, or drop PDFs here."
10. **Toast outliving its document** (H3): closing the active tab dismisses its toasts (an "Undo" for a closed document acted on nothing).
11. **Command-bar labels** (H5): the labeled tools (Add text, Sign, Stamp, Draw, Organize) now outrank the icon-only commands after them when room runs short: those overflow into "…" first; the bar goes icons-only only when the labeled tools themselves don't fit (`ToolbarPanel`). At 1400 DIPs that is still the case (the labeled set needs about 1700), so the gain shows on wide windows only.
12. **Windows' Text size ignored** (H14, WCAG 1.4.4). `TextScale` reads it (`UISettings.TextScaleFactor`, live) and scales
    every dialog's content, widening the dialog by the same factor (`TextSize.Widen`, never past the screen) and
    centering it again; the main window scales its chrome only (`TextScale.Scales`), and the side pane's width follows.
    The page view isn't scaled: it renders pages for the screen's own pixels, and a scaled bitmap would blur.
13. **Undo toast after its document closed** (H3): a toast remembers the tab it came from and closes with it, whichever
    way the tab closes (the first pass only cleared toasts when the active tab closed directly).
14. **Jargon in Sanitize and Reduce** (H2): see row 2.
15. **Motion** (H4, WCAG 2.3.3): `Motion.Enter`, a 167 ms fade and 8-px rise for toasts and the palette, skipped when
    `SystemParameters.ClientAreaAnimation` is off.

### Still short, and why

- **Text size in the title bar and Organize**: the tab strip in the title bar and the Organize page grid keep their size
  (the title bar's height is the caption's, and the Organize cards are page pictures, which the page zoom already enlarges).
- **Settings applies on Save**, not at once as Windows 11 settings do. The dialog is small and has Reset to defaults; changing it to instant-apply is a design change, not a fix.
- **Command-bar labels** show only on windows about 1700 DIPs wide; narrower ones get icons with tooltips (and the names in the palette and menus). A two-row or grouped bar would be a redesign.
- **Minimalist design** stays at 9: the command bar carries about twenty icons before "…" on a 1400-DIP window; grouping
  them (as Acrobat's All tools or Edge's split buttons do) would be a redesign of the bar.

## Inkvolt Print

### Scores

| # | Criterion | Before | After | Evidence and change |
|---|---|---|---|---|
| 1 | Status | 9.5 | 9.5 | Status line under every action, progress bars, the list says why a dot is amber ("Ready · Yellow ink is low"). |
| 2 | Plain words | 9.5 | 9.5 | "Sleeping to save power. It wakes up by itself when you print or scan." |
| 3 | Control | 9.0 | 9.5 | Every question has a verb and Cancel as the default; unsaved scans come back after a crash. Deleting a scanned page had no confirmation and no undo: the page was gone until scanned again. The review now has Undo (button and Ctrl+Z) for delete, turn, crop, move, file starts, separators, Keep and the photos, and the status line says "Deleted page 2. Undo (Ctrl+Z) puts it back." (`after/print-review-undo.png`). |
| 4 | Fluent consistency | 9.0 | 9.5 | Questions were a paragraph in a window titled "Inkvolt Print" (`ConfirmDialog`); they now have the question as heading and title with the explanation under it and a footer (`after/print-dlg-confirm.png`). "Remove from InkvoltPrint…" read as one word. |
| 5 | Recognition | 9.0 | 9.5 | Captions under every option; the address box in Add a printer shows an example now (`after/print-dlg-addprinter.png`). |
| 6 | Flexibility | 9.0 | 9.5 | Ctrl+1…9 presets, F1 lists the shortcuts, Shift+F10 menus. The review gains Ctrl+Z, Ctrl+R / Ctrl+L (turn, as in Photos) and Ctrl+S (save as PDF), shown in Help, the tooltips and the page menu. No command palette (the app has six tabs; not needed). |
| 7 | Minimalist | 9.5 | 9.5 | Cards that show only what the printer offers. |
| 8 | Errors and dialogs | 8.5 | 9.5 | The question is the dialog's title and heading now (`DialogText.Split`, Core, tested); "OK" on information became Close. |
| 9 | Empty states | 9.5 | 9.5 | No printers found (with Add a printer, Search again and a demo), no pages yet, the offline fixer's steps. |
| 10 | Keyboard and focus | 8.5 | 9.5 | `LinkButton` had no Fluent focus ring (WPF's dotted default); it has one now. Tabs, lists and buttons were already in order. |
| 11 | Accessible names | 9.5 | 9.5 | The audit found no nameless control on any tab or dialog. |
| 12 | Contrast and themes | 9.5 | 9.5 | Light, dark and Windows setting; the black-toner swatch gets an outline in dark mode. |
| 13 | Targets and DPI | 8.0 | 9.5 | The scan review's page buttons (turn, crop, delete) were 14 px wide and the About card's text fields 19 px tall (`before/print-scan-review.png`); links and those fields are at least 24 px now (`after/print-scan-review.png`). The audit finds nothing under 24 × 24 on the audited states. |
| 14 | Responsiveness | 8.5 | 9.5 | The Scan settings' scrollbar covered the captions (`before/print-scan.png` → `after/print-scan.png`), as did What's New's. Windows' *Text size* now scales every window (`after/print-overview-textsize150.png`); at large sizes the tabs wrap in their order (WPF's TabPanel moved the selected row to the bottom) and the printer's buttons go under its name instead of over its address. Window position and size are remembered. |
| | **Weighted** | **9.0** | **9.5** (9.50) | |

### Findings, ranked by impact, and what was done

1. **Question dialogs** (H4, H8): `ConfirmDialog` now splits the message with `DialogText.Split` (first question of the first paragraph = heading and window title; the rest = body) and lays it out as the Windows dialog guidance does; `Tell` closes with Close.
2. **Small targets** (H13): `LinkButton` gets `MinHeight`/`MinWidth` 24 with centered content, so the scan review's icon buttons and the sidebar links meet 2.5.8; the About card's read-only fields are 24 px tall.
3. **Scrollbar over captions** (H14): padding on the Scan settings' and What's New's scroll viewers.
4. **Focus ring on links** (H10): `DefaultControlFocusVisualStyle` on `LinkButton`.
5. **Placeholder** on the address box (H5), with the same `Placeholder` helper as Inkvolt PDF.
6. **"InkvoltPrint"** in the printer menu (H2).
7. **No undo in the scan review** (H3): `UndoHistory` (Core, tested; newest first, 50 steps) records how to put each
   review change back; the review's Undo button says which ("Undo delete page 2 (Ctrl+Z)"). Clear, which asks first,
   empties it.
8. **Windows' Text size** (H14): the same `TextScale` as Inkvolt PDF, here on whole windows, the main one included.
9. **The header at large text** (H14): the name and the Print a PDF / Scan buttons are a `HeaderPanel`, so the buttons
   go under the name when there is no room; the section tabs wrap in order (`WrapPanel`).
10. **Review shortcuts** (H7): Ctrl+R / Ctrl+L and Ctrl+S, listed in Help.

### Still short, and why

- **The sidebar at large text** keeps its 272-DIP width, scaled: at 200 % on a small window it takes much of it. Windows
  Settings folds its own pane at that point; doing so here is a layout change for another pass.
- **Motion**: none. The app's changes are in place (a status line, a page added to the review), which Fluent allows.
- **Flexibility**: shortcuts cover the review, Photos and presets, not every button; a palette would be more than the app
  needs.

## How to reproduce

- Inkvolt PDF: `InkvoltPdf.exe --script docs/ux-review/pdf-before.txt` (and `pdf-final.txt`, `pdf-audit.txt`) with
  `INKVOLTPDF_DATA` set to a scratch folder; the sample PDFs come from the tests with `INKVOLTPDF_SAMPLES` set. Edit the
  output paths in the scripts first.
  `pdf-textsize.txt` is the second pass (`textscale 1.5` stands in for Windows' Text size).
- Inkvolt Print: `InkvoltPrint.exe --demo --snapshot out.png --a11y-audit findings.txt [--tab Scan --scan 3 | --dialog confirm …]`
  (every run: `pwsh -File docs/ux-review/print-runs.ps1 -Exe …\InkvoltPrint.exe -Out C:\ux`). `INKVOLT_TEXTSCALE=1.5`
  stands in for Windows' Text size in both apps; `--delete n` and `--undo` drive the review's Undo.
- The audit rules (`UiAudit`: no name, under 24 × 24) and the dialog split (`DialogText`) are in
  `shared/InkvoltPrint.Core/Suite` with tests in `print/tests/InkvoltPrint.Tests/UxTests.cs`; the palette's no-match words
  in `pdf/src/InkvoltPdf.Core/PaletteText.cs` with `PaletteTextTests`; the Text size rules (`TextSize`) and the review's
  `UndoHistory` with `TextSizeTests` and `UndoHistoryTests`.
