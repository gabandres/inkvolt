# Inkvolt for macOS: plan

Decided 2026-10-26 with the owner:

| | |
|---|---|
| Apps | Inkvolt Print first; Inkvolt PDF after it ships |
| Stack | Native Swift: SwiftUI with AppKit where needed; Apple frameworks only |
| Distribution | Print: Mac App Store (sandboxed). PDF: notarized DMG with Sparkle 2, MuPDF, AGPL |
| Minimum | macOS 15 Sequoia |
| Price | Free; no account, no telemetry, no cloud |
| Signing | The Apple team that signs the Inkvolt mobile builds |
| Repo | This monorepo, `mac/`; shares fixtures and glossaries with the Windows apps |

Platform facts and their sources: [`research/print-v1-platform.md`](research/print-v1-platform.md).

## Inkvolt Print v1 scope

In:
- printer status, supplies and alerts (LEDM, CDM, IPP, SNMP; same fallback order and identity-before-data rule);
- Add a printer: Bonjour, the subnet search (TCP 631/9100/515, SNMP broadcast), a typed address;
- scanning: eSCL presets with review, crop and straighten, crash recovery; USB scanners through ImageCaptureCore;
- the offline fixer, reduced to diagnosis, cancelling the user's own stuck jobs, and a guided hand-off to Printers &
  Scanners (the sandbox can't resume, re-enable, add or delete a CUPS queue);
- a menu bar item (the tray's equivalent) with alerts; launch at login only if the user turns it on;
- demo mode (the made-up environment), so App Review can use the app without a printer.

Later (Windows features not in v1): copy, print photos, print a PDF, HP maintenance (cleaning, alignment), firmware
update, LEDM settings, batch scans with separator sheets and patch codes, glass photos, mail and sync-folder routes,
Open in Inkvolt PDF.

## Layout

```
mac/
  CLAUDE.md, README.md
  docs/PLAN.md                   this file
  docs/research/                 platform research, one file per question set
  Probe/                         InkvoltProbe: throwaway sandboxed app that settles the open platform questions (P0)
  InkvoltPrintKit/               Swift package (from P1)
    Sources/PrintCore/           protocols and rules; Foundation only, so it also builds off the Mac
    Sources/PrintMac/            adapters: URLSession, BSD-socket SNMP, Bonjour (dns_sd), Local Network access; later
                                 the subnet scanner, libcups, ImageCaptureCore, Keychain, Core Image, PDFKit, Vision.
                                 Declared only when Package.swift is read on a Mac
    Tests/PrintCoreTests/        Swift Testing; reads print/tests/InkvoltPrint.Tests/Fixtures in place
    Tests/PrintMacTests/         the transports against loopback servers (Mac and CI only)
  InkvoltPrint/                  the app (SwiftUI): InkvoltPrint.xcodeproj (hand-made, synchronized folders, the package
                                 by relative path), Info.plist, entitlements, Resources (icon, privacy manifest);
                                 build.sh (development), release.sh + pkg-preflight.sh + asc-builds.mjs (App Store)
```

## Module map (.NET to Swift)

| `shared/InkvoltPrint.Core` | Swift | Notes |
|---|---|---|
| `Snmp/` (Ber, Oid, SnmpMessage, PrinterMib, SnmpPrinterStatus, SnmpPrinterClient) | `PrintCore/Snmp` | transport behind a protocol; `SnmpAgent` becomes the test fake |
| `Ipp/` | `PrintCore/Ipp` | the same encoder reads the local cupsd |
| `Ledm/`, `Cdm/` (parsers, status text) | `PrintCore/Ledm`, `PrintCore/Cdm` | `XMLParser` with external entities off and the same depth caps as `Net/DeviceXml` |
| `Net/` (DeviceHttp policy, FixtureHandler, HostRouter) | `PrintCore/Net` + `PrintMac/Http` | size caps, timeouts, certificate pins; `FixtureHandler` becomes a `URLProtocol` fake |
| `Model/`, `Probe/` | `PrintCore/Model`, `PrintCore/Probe` | PrinterReading, printer status, PrinterSession, connection recipe |
| `Alerts/`, `Suite/PrinterHealth`, tray text | `PrintCore/Alerts` | feeds the menu bar |
| `Discovery/` (NetworkSearch, DnssdJoin, PrinterAddress) | `PrintCore/Discovery` + `PrintMac/Discovery` | address planning stays pure; sockets and NWBrowser in PrintMac |
| `Queues/` (PrinterList, QueueKinds, SnmpQueueStatus) | `PrintCore/Queues` + `PrintMac/Cups` | Windows queues become CUPS destinations |
| `Escl/`, `Presets/` (ScanPreset, FileNameTemplate), `Imaging/ScanRecovery` | `PrintCore/Scan` | |
| `Imaging/PageImage` (rotate, deskew, crop) | `PrintMac/Imaging` | Core Image; the edit model stays in PrintCore |
| `Offline/` (diagnosis) | `PrintCore/Offline` | repairs become hand-off steps |
| `Wia/` | `PrintMac/Icc` | ImageCaptureCore; `FakeWiaSystem`'s role goes to a fake scanner protocol |
| `Pdf/PdfWriter` | `PrintMac/Pdf` | PDFKit / Core Graphics; searchable PDF with Vision |

Not ported: `Suite/ShellRegistration`, `Offline/RepairScripts`, `Queues/Spooler*`, `Wia/WorkThread`, and the v1
"Later" list above.

## Steps

Each port step ports the module's .NET tests first, under the same names (in lower camel case), then the code until
they pass. PrintCore builds and tests on the Windows PC too: `pwsh -File mac/tools/swift-dev.ps1 test --package-path
mac/InkvoltPrintKit --build-system native`.

| Step | What | .NET tests to port | Status |
|---|---|---|---|
| P0 | Probe app on `ignia-mac`: answer research open items 1 to 10; record results in the research file | | Builds in CI; run pending |
| P1 | Package skeleton, CI job (`swift test` on a macOS runner), Model, SNMP | SnmpTests | Done: 42 tests. The connection and Windows queue tests wait for P4 and P7 |
| P2 | IPP | IppAndPdfTests (IPP part) | Done: 22 tests (codec, text fixtures, status, supplies, Identify-Printer, from OtherBrandsTests, RobustnessTests and MaintenanceTests too). The HTTP client waits for P4 |
| P3 | LEDM, CDM, other brands' status text | LedmTests, CdmTests, OtherBrandsTests | Done: 22 tests (LEDM documents and manifest, CDM identity, supplies and status, brands, the hardened XML and JSON readers). The connection, eSCL and web-page tests wait for P4 and P8 |
| P4 | Device HTTP, printer status, printer session, certificate pins | PrinterReadingTests, PrinterSessionTests, RobustnessTests, CertificatePinTests | Done: 78 tests (device HTTP, pins per port, the fixture transport, LEDM, CDM, IPP and eSCL clients, the connection probe, printer reader and printer session, printer ids; with the connection tests SnmpTests, CdmTests and OtherBrandsTests left for here, and eSCL from P8). The TLS handshake tests wait for PrintMac |
| P5 | Alerts, status lines | AlertTests, StatusLineTests | Done: 35 tests (conditions, the tracker's holds, quiet hours, pause, memory across restarts, polling, menu bar text, list lines) |
| P6 | Discovery: typed addresses, network search planning, DNS-SD join | NetworkSearchTests | Done: 21 tests (typed addresses, the search's addresses, SNMP question, reporting once, stopping; DNS-SD join and endpoints from OtherBrandsTests). The socket scanner is PrintMac's |
| P7 | Printer list with CUPS destinations | PrinterListTests, QueuePrinterTests (CUPS parts) | |
| P8 | Presets, file names, scan recovery, page edits (eSCL came with P4a) | ScanPresetTests, ScanRecoveryTests, ImagingTests | Done: 52 tests (file-name templates and sets, the preset list and its JSON, the plan for a scanner, summaries; blank pages, skew, crop, rotation; scan recovery and run folders). Mail and sync-folder routes, batch separators and glass photos stay with "Later" |
| P9 | Offline diagnosis | OfflineFixerTests (diagnosis parts) | |
| P10 | App: main window, Add a printer, scan review, offline fixer, menu bar, settings, demo mode | DemoTests | First slice done (2026-10-26): the printer list from Bonjour and the state file, the printer pane (status, alerts, supplies, details, This is my printer), the menu bar item with alerts as notifications, the Local Network banner, demo mode, `--report`. PrintCore: `PrinterMonitor`, `DiscoveredPrinters`, `StateStore`, `SupplyText`, `Demo`, menu lines (15 tests, 287 in all); PrintMac: URLSession and UDP SNMP transports, Bonjour, Local Network signal (7 tests). Checked on `ignia-mac` with the owner's M234dw. Next: Add a printer, the window-closed polling, P7 |
| P11 | App Store: record, privacy label "Data Not Collected", review notes (demo mode, why `network.server`, the subnet search), screenshots | | Started 2026-10-26, beside P10: the App Store Connect record (macOS, "Inkvolt Print"), the Xcode project, the icon, release.sh with cloud signing and the preflight; build 1.0 (1) uploaded and VALID (TestFlight). Review waits for the v1 scope. Still to do: privacy label, review notes, screenshots, description, privacy policy URL |

## Mac differences

- SNMP errors are Swift errors: `SnmpFormatError`, `SnmpTimeoutError`, `SnmpErrorStatus` (the .NET exceptions).
- IPP attribute values are an enum (`IppAttributeValue`: text, integer, boolean, bytes), not `object`.
- Device XML is read with `XMLParser` into a small tree (`XmlElement`, by local name); a document with a DTD is refused
  before parsing. CDM's JSON goes through a small reader of its own (`Json`: numbers keep their text, nesting capped at 64)
  rather than JSONSerialization, whose booleans and numbers differ between Darwin and other platforms.
- HTTP goes through PrintCore's own `HttpTransport` (request and response values; `DeviceNetworkError` for no answer),
  so PrintCore never opens a socket: PrintMac's URLSession transport and the fixture transport sit behind it.
  `CertificateCheck` holds the pin rule the TLS transport asks on each handshake; the loopback TLS tests
  (CertificatePinTests' handshakes) move to PrintMac. To check there: URLSession treats `Host` and `Authorization` as
  reserved headers, which the Epson eSCL quirk and the EWS password need.
- The IPP probe asks the DNS-SD hint and the plain endpoint at the same time, so which is asked first isn't fixed.
- A printer added by address keeps the Windows app's id (MD5 of the host as a .NET Guid; PrintCore has its own MD5 and
  SHA-256, since CryptoKit is Apple's).
- Quiet hours are minutes after midnight on a given time zone (the tracker takes one; tests pass UTC-4 as the .NET tests'
  offset). Polling backs off on battery and on a constrained network (macOS's Low Data Mode) rather than Windows' metered one.
- Network search addresses are dotted IPv4 strings; the scanner protocol is async (`NetworkScanner`), and the sweep runs
  64 addresses at a time in a task group, the SNMP question beside it and awaited when the search stops.
- Presets keep the Windows app's JSON field names and stored numbers (`StoredChoice`), so the apps read each other's
  presets; unknown fields survive a save. Paths and subfolders use "/", and the built-in Receipt preset's subfolder is
  `Scans/Receipts/{date:yyyy}`. File names stay Windows-safe (they may sync to a PC). Date and number formats are .NET's
  custom ones (`DotNetFormat`), so a template means the same on both. Page rotation runs on one thread for now.
- A run folder's lock is `flock` (the system drops it when the process dies), not a delete-on-close file; platforms
  without `flock` (the Windows PC's test runs) get an in-process lock. Recovery lists use Swift's JSON keys.
- CPU-heavy page work runs through `offPool` (a Dispatch queue): on Swift's cooperative pool it would stall network
  tasks and their timeouts, as the macOS CI's IPP timing tests showed.
- `PrinterSession` is an actor; its clock is a `now` closure, and a dropped connection simply goes (no Dispose).
- `SnmpPrinterClient` is an actor; a caller's cancellation doesn't stop waiting for a shared read (each read times out on
  its own, 1 s per request).
- The Windows app's connection loop (`PrinterViewModel.RunAsync`, `RefreshAsync`, `SetOffline`, `SetElsewhere`, the address
  move) is PrintCore's `PrinterMonitor` (an actor; events to the app), so it's tested on the fixtures. The app's printer
  model only shows what it says. For now it runs while the app runs, window or not; the Windows app's suspend-and-poll while
  hidden (`AlertPolling`) comes later.
- Discovery is Bonjour only (no Windows association endpoints): `dns_sd`'s browse, resolve and IPv4 lookup in PrintMac
  (`BonjourDiscovery`; Local Network denied is `kDNSServiceErr_PolicyDenied`), joined into printers by PrintCore's
  `DiscoveredPrinters` (the Windows discovery's `Merge`, services part). A printer needs an IPv4 address to be listed.
- Local Network access has no API: `LocalNetworkSignal` is told by the transports and Bonjour (denied: URLSession's -1009
  whose network path says `localNetworkDenied`, `EHOSTUNREACH` on UDP, `PolicyDenied`; allowed: any answer). Denied shows a
  banner with a link to System Settings; once allowed, discovery and the offline printers start again at once.
- The state file is `state.json` in the container's Application Support/InkvoltPrint, with Swift's JSON keys
  (`StateStore`: remembered printers, the selection, pins, accepted UUIDs, forgotten printers, alerts shown). Demo mode's
  state is in memory.
- URLSession sends `Authorization` as given (PrintMacTests checks it against a loopback server). `Host` isn't checked yet
  (the Epson eSCL quirk, with scanning).
- Demo mode reads the fixtures from the app bundle (`Contents/Resources/Demo`, copied by build.sh), not embedded resources.

Decided 2026-10-26, starting the app: Inkvolt Print's bundle ID is `com.bermudezsystems.InkvoltPrint`, on the Inkvolt
mobile apps' team (AE6TTXW92K); development builds are ad-hoc signed; App Store builds are signed by Xcode with the
team's cloud-managed certificates through the App Store Connect API key (no certificate in the Mac's keychain), as the
mobile apps are. The app is a hand-made Xcode project (no XcodeGen). Store setup and TestFlight run beside the v1
features; the app goes to review once the v1 scope is in. Print and PDF stay two apps (PDF can't be on the App Store:
AGPL MuPDF and Sparkle). The repo is cloned at `~/Repos/inkvolt` on `ignia-mac`.

## Open decisions

- Inkvolt PDF's bundle ID: proposed `com.bermudezsystems.InkvoltPdf`.
- An Apple Development identity on the Mac, so development builds keep their Local Network permission between builds
  (ad-hoc builds may be asked again).
