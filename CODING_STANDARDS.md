# Coding standards (read in review)

For the reviewer of a diff, before it is merged: the judgement calls no check makes. What a check can catch belongs in a
check (CI, `tools/test.ps1`, the `mac` job's grep steps), not here. Each rule names the finding that earned it.

## Input from outside is hostile

A PDF, a scanner's or printer's reply, a file on disk and a number the user types can hold anything.

- **Sizes and counts are bounded before anything is allocated or looped over**: pixels, pages, stream lengths, labels,
  styles. (Go to Page hung on thousands of page-label styles; a scanner PDF's page size crashed the Mac app.)
- **A floating-point value is checked finite and in range before it becomes an integer.** In Swift, `Int(x)` traps on
  NaN, infinity or out of range; check in Double first. (A watermark width of "inf" quit the app.)
- **Text from outside is shortened before it fills a line** (Document Properties' producer text pushed the window off
  screen).

## One behaviour, one module

- **Two callers doing the same work go through one Core module**, not two copies. Copies drift. (Batch's Redact
  Patterns lost the text layer the review dialog kept, until both went through `PatternRedaction`.)
- **Logic sits where its tests reach it**: Core or Kit, through the module's interface. An app file that decides
  something (what is enabled, what an edit selects) is a finding when no package test covers it.

## Redaction and other data-safety paths

- **Whatever removes content proves it**: read back, searched again, the redaction check, and a failed check means nothing
  is saved. A report never says "Removed" for a file that wasn't saved (`RedactionFileReport.WithoutResult`).
- **A redaction report never holds the value removed**: masked only.

## The .NET code is the Mac's spec

- **A Mac port keeps the Windows test names** and reads the fixtures in place. A Mac difference is written in
  `mac/docs/PLAN.md`; an undocumented one is a finding.

## Privacy and the user's data

- **Nothing leaves the machine without the user's action**: no telemetry, analytics, crash upload or update check the
  user didn't allow; a network call names what it sends.
- **No real printer serial, IP, hostname or UUID in the repo, logs or fixtures** (192.0.2.x, the scrubbed fixtures).

## Words the user reads

- **New interface text in Inkvolt PDF and Inkvolt Print for Windows has its Spanish** in the `.es.resx` next to it, with
  the same placeholders and access key (`LocalizationTests` checks placeholders, not the wording). The voice is the one in
  `print/docs/SPANISH-REVIEW.md`.
- **A message says what happened and what to do, in plain words**: no exception text, codes or stack traces.
