# UX/UI pass for the Mac apps (brief for a session running on the Mac)

Written 2026-10-30 for a T3/Claude session that runs on the Mac itself (`~/Repos/inkvolt`), so builds, tests and
screenshots are local. Goal: Inkvolt PDF for Mac and Inkvolt Print for Mac scored very close to 10 against
state-of-the-art standards, the way the Windows apps were (`docs/UX-REVIEW.md`: the rubric, rounds 1 and 2,
scores 9.62 / 9.61). Work on branch `mac-ux` from master; commit per area; push; don't merge (the Windows session
merges). Don't run `release.sh`, don't touch App Store Connect.

## Read first
- `CLAUDE.md`, `mac/CLAUDE.md` (rules: 0 warnings, the 150 ms type-check flag, PdfCore Foundation-only, privacy,
  no device identifiers in the repo), `mac/README.md`, `mac/docs/PLAN.md` ("Mac differences" sections).
- `docs/UX-REVIEW.md`: reuse its rubric and criteria, re-weighted for macOS where a criterion is Windows-specific.
- `git log --oneline -40 -- mac/InkvoltPdf/Sources mac/InkvoltPrint/Sources` for what the D7/E-steps built.

## Standards to consult (fetch the current pages)
Apple Human Interface Guidelines for macOS (layout, typography with SF and Dynamic Type sizes, color and
vibrancy, materials, sidebars and inspectors, toolbars and their customization, menus and keyboard shortcuts,
sheets vs. panels vs. alerts, windows and tabs, full screen, Dark Mode, Accessibility: VoiceOver, Reduce
Motion, Increase Contrast, Differentiate Without Color, keyboard navigation, pointer control); Apple's
Accessibility programming guide for AppKit/SwiftUI (accessibility labels, roles, rotor, focus); Nielsen Norman's
10 heuristics; what Mac users expect from Preview, PDF Expert and Acrobat on the Mac (toolbar layout, the
sidebar's thumbnails/outline/annotations, find bar, continuous scroll, trackpad gestures, Quick Look,
Services, Share, print panel).

## Method
1. Build both apps (`sh mac/InkvoltPdf/build.sh`, `sh mac/InkvoltPrint/build.sh`).
2. Capture every window, dialog, pane, sheet, empty and error state, light and dark, default and the largest
   Accessibility text size, Increase Contrast on, narrow windows. Print has `--snapshot`; add a snapshot step to
   Inkvolt PDF (`--report`/a `--snapshot` of its own through ScreenCaptureKit, like Print's) so screens can be
   re-shot after fixes. View the PNGs yourself.
3. Run the Accessibility Inspector audit (`xcrun accessibility-inspector` isn't scriptable; use the AX API from a
   dev step to list controls without labels, like Print's `--a11y-audit` on Windows) and VoiceOver by hand on the
   main flows (open, find, comment, fill and sign, scan, Batch).
4. Write `mac/docs/UX-REVIEW.md`: rubric, per-app score before with evidence (screenshot path + what's wrong),
   findings ranked by user impact, fix list.
5. Fix what moves the score: HIG spacing and typography, toolbar customization and sensible defaults, sidebar and
   inspector behaviour, menu organisation with every command in the menu bar and a shortcut where Apple's apps
   have one, sheets for document-modal questions with verbs on buttons, undo everywhere, progress with cancel,
   empty states with the next step, Dynamic Type sizes respected, Dark Mode and Increase Contrast correct,
   focus rings, full keyboard access, VoiceOver labels and rotor, trackpad gestures (pinch zoom, two-finger
   swipe between pages where sensible), Reduce Motion honoured, window state and tabs restored, Services and
   Share menu entries, Quick Look of the document, drag and drop (files onto the window and Dock icon, pages
   between windows). Keep the apps' plain-words voice and architecture; no restyling for its own sake.
6. Re-shoot, re-score honestly (target ≥ 9.5 per app; list what's still short and why), update
   `mac/docs/UX-REVIEW.md`, `mac/README.md`, `mac/docs/PLAN.md` ("Mac differences"), and both apps' What's New
   files (`mac/InkvoltPdf/WHATS-NEW.md` under `## Next`; Print's listing `whatsNew` is in
   `mac/InkvoltPrint/assets/store/listing.json`, change it only in the text file the owner submits).

## Rules
`swift test` green with 0 warnings for both packages; build with
`-Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=150` and split what it flags. Tests for any
logic added (shortcut tables, state restoration, audit rules). Commit in the repo's voice (`git log --oneline -8`:
long descriptive one-paragraph subjects; end with the `Co-Authored-By` line for the model used), push `mac-ux`,
watch the `mac` and `pdf` CI jobs. Final report under 300 words: scores before/after per app, the three biggest
changes, what's still short, test counts, branch head SHA.
