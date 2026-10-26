# Inkvolt for macOS

Native Swift versions of Inkvolt Print (first, Mac App Store) and Inkvolt PDF (later, notarized DMG). Decisions, scope,
layout and steps: `docs/PLAN.md`. Sandbox, entitlements, CUPS and App Review facts with sources:
`docs/research/print-v1-platform.md`; read it before picking an API, and add what the Mac proves (or disproves) there.

- **Machines.** The Windows PC builds and tests PrintCore (Foundation only):
  `pwsh -File mac/tools/swift-dev.ps1 test --package-path mac/InkvoltPrintKit --build-system native`. Everything that
  imports an Apple framework (the probe, PrintMac, the app) builds only on the owner's Mac (`ignia-mac`) or in the `mac`
  CI job (macos-15, warnings as errors); say which one checked a change. Xcode's Swift gives up on expressions that
  Windows' compiles fast: build with `-Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=150` and break up
  what it flags before pushing.
- **The app on the Mac.** `ssh -o BatchMode=yes ignia-mac`; the clone is `~/Repos/inkvolt` (pull, or copy changed files
  over with LF endings for text only: a CRLF entitlements file fails `codesign`, and converting a PNG breaks it).
  `sh mac/InkvoltPrint/build.sh` installs `/Applications/Inkvolt Print.app` (process `Inkvolt Print`); `open -n` it with
  `--report <name> [--wait s] [--stay] [--demo]` and read the report from its container (README). Start automatic work
  from the app delegate, never a view (a locked screen shows no window). `screencapture` doesn't work over SSH: ask the
  owner what the screen shows. New files in `Sources/InkvoltPrint` and `Resources` join the Xcode project by themselves
  (synchronized folders).
- **App Store builds** go through `mac/InkvoltPrint/release.sh <build> --upload` only (README), run detached on the Mac;
  read its status file before running it again (a build number can't be uploaded twice), then check App Store Connect
  with `asc-builds.mjs <build> --wait`. Upload or submit for review only when the owner says. No Sentry or other crash
  SDK, unlike the mobile apps: the privacy rule below wins, and the preflight refuses one.
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
- **Done** means `swift test` green with 0 warnings in our code (locally for PrintCore, and in the `mac` CI job), and
  `mac/README.md` and `docs/PLAN.md` (step status, Mac differences) updated. Commit only when the owner says, message
  style per `git log --oneline -6`; pushes of mac/-only fixes for CI are approved.
