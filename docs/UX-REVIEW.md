# UX review: Inkvolt PDF and Inkvolt Print

How both Windows apps' UX and UI are judged, and the last result. Every finding of the reviews (2026-10-30 to
2026-11-04) is fixed; the scores after them: **Inkvolt PDF 9.62, Inkvolt Print 9.61** (from 8.7 and 9.0). The Mac
review (`mac/docs/UX-REVIEW.md`) reuses the rubric below. Scores are judged, not measured: each half point names what
earned it or what still holds it back.

## Method

The real UI, rendered off-screen with the apps' own dev aids (Inkvolt PDF's `--script`, Inkvolt Print's
`--demo --snapshot`): every window, pane, dialog and state, in light and dark, at 1400 × 900, 1180 × 800 and 900 × 620,
and with Windows' Text size at 150 % (200 % for Inkvolt Print); plus the UI Automation audit of every visible control
(Inkvolt PDF's `a11yaudit` step, Inkvolt Print's `--a11y-audit` switch: no accessible name, a target under 24 × 24).

Standards: Nielsen Norman Group's 10 usability heuristics; Microsoft's Windows 11 design principles, layout, typography
(Segoe UI Variable, the type ramp: caption 12, body 14, subtitle 20, title 28), iconography (Segoe Fluent Icons), color
and materials (Mica), dialogs and commanding guidance; WCAG 2.2 AA (contrast, 2.4.7 focus visible, 2.5.8 target size
minimum 24 × 24, 2.1.1 keyboard, 4.1.2 name/role/value, 1.4.4 resize text); Microsoft's accessibility guidance for WPF
(UIA names, AutomationProperties, Narrator); and what people expect from Acrobat, PDFgear, Sumatra, Edge's PDF viewer and
PDF Expert (toolbar, find bar, side rail, tabs, context menus, shortcuts, drag and drop, recent files, undo, recovery).

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

## Where each app stands

| # | Inkvolt PDF | Inkvolt Print |
|---|---|---|
| 1 | 9.5 | 9.5 |
| 2 | 9.5 | 9.5 |
| 3 | 9.5 | 9.5 |
| 4 | 10 | 10 |
| 5 | 10 | 9.5 |
| 6 | 9.5 | 10 |
| 7 | 9.5 | 9.5 |
| 8 | 9.5 | 9.5 |
| 9 | 9.5 | 9.5 |
| 10 | 9.5 | 9.5 |
| 11 | 9.5 | 9.5 |
| 12 | 9.5 | 9.5 |
| 13 | 9.5 | 9.5 |
| 14 | 10 | 10 |
| **Weighted** | **9.62** | **9.61** |

Choices that hold a score where it is, not findings: Inkvolt PDF's command bar keeps its labels by sending lower-priority
groups into "…" first, so at Text size 150 % on a 1200-DIP window most groups are in "…" (`CommandBarLayout`,
`docs/design/command-bar.md`); Inkvolt Print's shortcuts cover the review, Photos, presets and the palette, not every
button.

## How to run it again

- Inkvolt PDF: `InkvoltPdf.exe --script docs/ux-review/pdf-audit.txt` (and the other `pdf-*.txt` there) with
  `INKVOLTPDF_DATA` set to a scratch folder; the sample PDFs come from the tests with `INKVOLTPDF_SAMPLES` set. Edit the
  output paths in the scripts first. `textscale 1.5` stands in for Windows' Text size; `barstate`, `barclick` and
  `menushot` give the command bar's state, a group's menu and a shot with it open.
- Inkvolt Print: `pwsh -File docs/ux-review/print-runs.ps1 -Exe …\InkvoltPrint.exe -Out C:\ux` (each run:
  `InkvoltPrint.exe --demo --snapshot out.png --a11y-audit findings.txt [--tab Scan --scan 3 | --dialog confirm …]`).
  `INKVOLT_TEXTSCALE=1.5` stands in for Windows' Text size in both apps; `--delete n` and `--undo` drive the review's
  Undo; `--palette [words]`, `--run-palette` and `--nav open` (the folded sidebar).
- The rules behind the fixes, with their tests: `UiAudit`, `DialogText`, `TextSize` and `UndoHistory`
  (`shared/InkvoltPrint.Core`, `UxTests`); `PaletteText` (`PaletteTextTests`);
  `CommandBarLayout` and `SettingsSession` (`pdf/src/InkvoltPdf.Core`, their tests); `PaletteSearch`, `PrintPalette` and
  `NavPane` (`PaletteTests`); `OrganizeGrid` (`OrganizeGridTests`); `ReviewMotion` (`ReviewMotionTests`); `ScreenFit`
  (Inkvolt Print's window kept inside a small screen's working area; `WindowsLookTests` presses Print at 860 × 560 and
  1024 × 576, as Windows 11 and as Windows 10).
