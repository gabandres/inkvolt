# Inkvolt for macOS

Native Swift versions of Inkvolt Print (first, Mac App Store) and Inkvolt PDF (later, notarized DMG). Decisions, scope,
layout and steps: `docs/PLAN.md`. Sandbox, entitlements, CUPS and App Review facts with sources:
`docs/research/print-v1-platform.md`; read it before picking an API, and add what the Mac proves (or disproves) there.

- **Machines.** Builds, tests and runs happen on the owner's Mac (`ignia-mac`). The Windows PC can plan and port code
  and tests, but can't build them; say so instead of claiming a Swift change works.
- **The .NET code is the spec.** Port a module by porting its tests first, with the same names, then the code. Read
  fixtures in place from `print/tests/InkvoltPrint.Tests/Fixtures` (and `pdf/tools/export-corpus` later); never copy or
  edit them for the Mac. Where the Mac must behave differently, write it down in `docs/PLAN.md`.
- **Names** come from `print/GLOSSARY.md` and `pdf/GLOSSARY.md` (printer reading, printer status, printer session,
  connection recipe, identity before data, printer list, environment, made-up PC). Mac terms go into those glossaries
  too, not into a separate one.
- **PrintCore** uses Foundation only (no AppKit, Network, CUPS or ImageCaptureCore) and value types that are `Sendable`;
  everything that touches the system sits in **PrintMac** behind a protocol, so tests use fakes the way the .NET tests
  use `FixtureHandler` and `SnmpAgent`.
- **The sandbox is fixed.** Only the entitlements in the research file's TL;DR; no helpers, no Authorization Services, no
  updater, no launch at login without the user's say. Local Network denied is its own visible state, never a silent
  "no printers".
- **Privacy.** No telemetry, analytics, crash upload, account or third-party SDK. Apple frameworks only; ask the owner
  before adding any package.
- **Device data.** Never put a real printer's serial, IP, hostname or UUID in the repo (use 192.0.2.x). Probe reports
  stay out of the repo; record only what was learned.
- **Done** means `swift test` green and 0 warnings on the Mac, and `mac/README.md` and `docs/PLAN.md` updated. Commit
  only when the owner says, message style per `git log --oneline -6`.
