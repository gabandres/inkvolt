# 3. A translated copy's apply stage stays in ContentEditor

Accepted, 2026-11-21.

## Context

The architecture review of 2026-11-21 found the apply stage of a translated copy (`ContentEditor.Translate*.cs`, about 2,000
lines) driven by `Translation` through eight internal functions in a fixed order, and proposed one apply module.

## Decision

Not now. The translation roadmap is finished on Windows; the code is tuned against `pdf/tools/export-corpus` and
`pdf/tools/pdfjs-check`, and it leans on ContentEditor's paragraph layout internals (layout, kerning, looks) throughout.
Moving it is risk without a bug it would fix.

## Consequences

Reopen it when translation work starts again and a change has to touch both `Translation` and several of the
`ContentEditor.Translate*` functions: that's the friction this module would remove.
