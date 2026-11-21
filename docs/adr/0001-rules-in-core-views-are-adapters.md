# 1. Interaction rules live in Core; the views are adapters

Accepted, 2026-11-21.

## Context

The test projects reference `InkvoltPdf.Core` and `InkvoltPrint.Core`, not the WPF apps. On Windows, what a click, drag,
key or panel action does in Prepare Form, the Reading Order panel and the measuring tools was written inside the views
(`PageViewer.FormDesign`, `DocumentTab.FormDesign`, `DocumentTab.ReadingOrder`, `PageViewer.Measure`), so it was checked only
by driving the app (`DevScript`, 81 hooks in the views for it). The Mac had already moved the same rules into PdfCore
(`FormDesigner`, `ReadingOrder`, `MeasureDraft`), with tests.

## Decision

A rule that decides something (what is selected, what an input does, what can run) is a Core module with a test. A view
turns mouse, keys and bindings into the module's inputs and draws what it says. Where the Mac deepened a module first, its
interface and test names are the spec for the Windows port (the usual direction, .NET first, is in `CODING_STANDARDS.md`).

## Consequences

- New interaction rules go in Core even when only one view uses them; a reviewer treats an untested rule in a view as a
  finding (`CODING_STANDARDS.md`, "Logic sits where its tests reach it").
- `DevScript` drives whole commands; a `Dev*` hook in a view that only reaches a rule is a sign the rule is in the wrong place.
