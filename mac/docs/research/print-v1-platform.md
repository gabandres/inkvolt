# Inkvolt Print for macOS v1: platform research

Researched 2026-10-26 for a sandboxed, Mac App Store, native SwiftUI app on macOS 15 and later. Sources are primary
(Apple docs and tech notes, Apple DTS forum posts, Apple's and OpenPrinting's CUPS source, Sparkle, GNU, Artifex, vendor
pages and App Store listings). **UNVERIFIED** marks anything no primary source confirmed. Test those on a Mac before you
rely on them.

Apple doc pages render with JavaScript. They were read through their JSON form
(`https://developer.apple.com/tutorials/data/documentation/<path>.json`). The links below are the normal page URLs.

## TL;DR: decisions for v1

**Works in the sandbox (no extra entitlement beyond the list below):**

- Status, supplies and alerts straight from the device: IPP Get-Printer-Attributes, HP LEDM/CDM over HTTP(S), SNMP.
- Bonjour browsing for all six service types.
- Subnet probe: TCP 631/9100/515, plus one SNMP GetNext to the subnet broadcast address. Use BSD sockets for the
  broadcast, because Network framework doesn't support UDP broadcast.
- eSCL scanning over HTTP.
- ImageCaptureCore for USB scanners.
- Menu bar item (`MenuBarExtra`).
- Opt-in launch at login (`SMAppService.mainApp`).
- macOS needs **no** multicast entitlement.

**Local Network privacy gates almost all of it.** The probe, SNMP, Bonjour, IPP, LEDM and eSCL all need the
Local Network privilege. Design for three states:

- **Undetermined:** the first operation may be denied before the user answers the alert. Use waiting or retrying APIs.
- **Denied:** `NWPath.UnsatisfiedReason.localNetworkDenied`, or `kDNSServiceErr_PolicyDenied` on Bonjour.
- **Allowed.**

There is no API to ask for the privilege or to read its state.

**Degraded: the offline fixer.** A sandboxed app can read the local CUPS queues and their state, and cancel the
user's own jobs. It **cannot** do any of these on its own:

- resume a paused queue
- accept jobs again
- cancel other users' jobs
- add or delete a queue

macOS cupsd requires the operator or admin authorization right for those operations and refuses peer credentials for
them. The only other way in is Authorization Services, which the sandbox forbids. So the v1 fixer diagnoses the
problem, cancels the user's own stuck jobs, then hands off to Printers & Scanners with exact instructions. A one-click
Resume or Re-add would need a separate, non-App Store build.

**Cut from the App Store app:** Sparkle and any updater other than the App Store (2.4.5(vii)), privileged helpers and
root escalation (2.4.5(iv)(v)), and auto-launch without consent (2.4.5(iii)).

**Entitlements (Inkvolt Print, App Store):**

| Entitlement | Why |
|---|---|
| `com.apple.security.app-sandbox` | Required for the Mac App Store |
| `com.apple.security.network.client` | Outgoing TCP (IPP, LEDM/CDM, eSCL, the 631/9100/515 probe) and sending UDP (SNMP) |
| `com.apple.security.network.server` | **Receiving** UDP: SNMP replies. Apple: "Apps using UDP usually require both entitlements." |
| `com.apple.security.print` | Printing (test page). Probably also what opens the cupsd socket (UNVERIFIED, see Q2) |
| `com.apple.security.device.usb` | ImageCaptureCore with USB scanners (macOS 14+) |
| `com.apple.security.files.user-selected.read-write` | Saving scans where the user picks |

Not needed: `com.apple.developer.networking.multicast`, which is iOS, iPadOS and visionOS only.

**Info.plist keys:**

- `NSLocalNetworkUsageDescription`: say plainly that the app finds and checks printers and scanners on this network.
- `NSBonjourServices`: `_ipp._tcp`, `_ipps._tcp`, `_uscan._tcp`, `_uscans._tcp`, `_pdl-datastream._tcp`,
  `_printer._tcp`. On macOS, a non-empty list reportedly limits Bonjour to exactly those types (secondhand Apple
  engineering reply, see Q1).
- `NSAppTransportSecurity` > `NSAllowsLocalNetworking` = YES. Since macOS 14, ATS blocks URLSession loads from IP
  addresses unless this key is set.
- `LSApplicationCategoryType` = `public.app-category.utilities`.
- Add `PrivacyInfo.xcprivacy` declaring no tracking and no collected data. On macOS only the data-collection part
  applies; required-reason APIs are an iOS, iPadOS, tvOS, visionOS and watchOS rule.

**App Store privacy label "Data Not Collected" is achievable.** Data processed only on the device isn't "collected".
Keep Report a problem user-initiated, for example a mail draft the user sends.

**IPv6-only networks (2.5.5):** App Review tests on one. The IPv4 subnet probe finds nothing there, so the app must
still work through Bonjour and typed addresses, and say "no IPv4 network" instead of failing.

## Probe results on a Mac (2026-10-26)

InkvoltProbe's automatic run (`--auto`, `mac/Probe/README.md`) on the owner's MacBook Air M1: macOS 27.0.1, Xcode 27.1,
ad-hoc signed, sandboxed with the six entitlements above. Printer: an HP LaserJet MFP M234dw on the same LAN, and a CUPS
queue for it made with `lpadmin -m everywhere` (by an admin user). Local Network not answered yet (the alert open, then
not granted) unless said otherwise. These replace the matching UNVERIFIED items below.

| Item | Result |
|---|---|
| 1. cupsd from the sandbox | **Works with `com.apple.security.print`**: `cupsGetDests2`, NSPrinter and Get-Printer-Attributes over cupsd's socket all answer. **Without it**, nothing: no destinations, `Bad file descriptor` (0x502). `marker-*` were missing for the idle IPP Everywhere queue. A POST to `localhost:631` failed with EPERM (to retest once Local Network is allowed). |
| 2. Protected operations | **Resume-Printer and CUPS-Accept-Jobs succeeded** from the sandbox, for an admin user (in `_lpadmin`, gid 98; `_lpoperator` is gid 100). This contradicts the research's reading of macOS's cupsd policy. Untested: a standard (non-admin) user. The offline fixer may resume and re-enable queues for admins after all. |
| 4. ImageCaptureCore | **Finds the network scanner** (the M234dw, `ICTransportTypeTCPIP`) **even without Local Network permission**: browsing runs in a system service. |
| 5. NSBonjourServices | **Restricts browsing on macOS too**: the six listed types browse ("ready"); unlisted types fail at once with `-65555 NoAuth`. Without Local Network permission, the listed types find nothing. |
| 6. SNMP broadcast | **A subnet broadcast goes out and the printer's reply arrives even without Local Network permission** (BSD socket, `SO_BROADCAST`). **Without `com.apple.security.network.server`** the reply can't be received: `recvfrom` fails with EPERM. Unicast SNMP is blocked as Local Network denied (BSD socket: `EHOSTUNREACH`; Network framework: waiting, `localNetworkDenied`). |
| 7. First run | While the alert is open, every unicast connection fails at once (`localNetworkDenied`, 756 of 759 in 0.2 s), so the app must wait for the answer and retry. Recovery after Allow: still to test. |
| 9. ATS | Not tested yet: blocked as Local Network denied (`NSURLErrorDomain -1009`). |
| 10. SMAppService | `mainApp.status` is `notFound` for the ad-hoc signed probe in /Applications; retest with a Developer ID or App Store signature. |

**With Local Network allowed** (the owner clicked Allow; the next launch, same binary):

| Item | Result |
|---|---|
| Unicast SNMP | Works over a BSD socket and over Network framework (reply 134 bytes). |
| TCP sweep | 759 connections, 96 at a time, 1.5 s timeout: 12.7 s for a /24; the printer's 515, 631 and 9100 open. |
| 5. Bonjour | Each listed type finds the printer; unlisted types still `NoAuth`. |
| 9. ATS | With `NSAllowsLocalNetworking`, `http://<IPv4>/` and `/eSCL/ScannerCapabilities` answer 200, and `https://<IPv4>/` with a trust handler accepting the self-signed certificate. |
| localhost:631 | Still EPERM: the sandbox doesn't let the app reach cupsd over TCP. Use libcups (its socket) for local queues. |
| CUPS | `cupsGetDests2` also lists the printer's Bonjour (temporary) destination once Local Network is allowed, without state until it's used. |
| 4. ImageCaptureCore | The network scanner was added and removed again about every second for 15 s while Bonjour browsing ran in the same app: the app must debounce ICC's device list. |
| 10. SMAppService | `notFound` only means not registered yet: **`register()` works from the sandbox** (status `enabled`), even ad-hoc signed. |
| 3. Settings links | **Both open Printers & Scanners** on macOS 27 (`x-apple.systempreferences:com.apple.Print-Scan-Settings.extension` and the older `com.apple.preference.printfax`). Opening a given printer's queue window: untested. |

Still to do: recovery without relaunching after Allow (7), item 8, and the protected operations as a standard user.

## Q1. Sandbox entitlements and limits (macOS 15+)

### Printing

- `com.apple.security.print`: "whether your app may print a document". macOS 10.7+. Xcode: App Sandbox > Hardware >
  Printing. https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.print
- Apple doesn't document what the entitlement opens beyond "print". See Q2 for CUPS socket access.

### Scanners through ImageCaptureCore

- ImageCaptureCore can "discover connected cameras and scanners" and "perform overview scans and scans on a connected
  scanner". https://developer.apple.com/documentation/imagecapturecore
- "In macOS 14 and later, use the `com.apple.security.device.usb` entitlement key to allow your sandboxed app to
  interact with USB devices." (same page;
  https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb)
- ICC has no scanner-specific entitlement. The authorization calls (`requestControlAuthorization`,
  `controlAuthorizationStatus`) are iOS, iPadOS, Mac Catalyst and visionOS only, not native macOS.
  https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser/requestcontrolauthorization(completion:)
- The camera, Photos and `NSCameraUsageDescription` keys are for camera import and tethering, not scanners.
  https://developer.apple.com/documentation/imagecapturecore
- Network scanners: `ICDeviceLocationTypeMask.bonjour` ("a network device that publishes a Bonjour service") and
  `.shared` exist.
  - `browsedDeviceTypeMask` must OR a **device type** with **location types**.
    https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser/browseddevicetypemask ,
    https://developer.apple.com/documentation/imagecapturecore/icdevicelocationtypemask
  - An unanswered forum thread (macOS 15.1.1) reports USB scanners not detected with `browsedDeviceTypeMask = .scanner`
    alone. The missing location bits are a likely cause. UNVERIFIED. https://developer.apple.com/forums/thread/771629
- UNVERIFIED: whether ICC's Bonjour scanner browsing, which runs out of process, counts against the app's Local Network
  privilege. TN3179 exempts only the high-level services it lists (AirPlay, printing via UIKit, DeviceDiscoveryUI,
  AccessorySetupKit), and ICC isn't among them.

### Outgoing TCP to LAN addresses

- `com.apple.security.network.client`: "connect to a server process running on another machine, or on the same
  machine". For TCP, the client and server entitlements "restrict only the initiation of a network connection, not the
  flow of data". https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client
- Outgoing TCP to a local-network address also needs the Local Network privilege.
  https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- ATS (URLSession only): "In ... macOS 14, ATS no longer allows connections to IP addresses by default." Setting
  `NSAllowsLocalNetworking` enables "unqualified domains, `.local` domains, and IP addresses".
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking
- Self-signed printer HTTPS (ipps, LEDM over HTTPS) needs your own trust evaluation in the URLSession delegate.

### UDP SNMP, unicast and subnet broadcast

- Allowed. For UDP, "the network entitlements restrict both initiation and data flow ... an app with only the client
  entitlement enabled can send, but not receive, data. Apps using UDP usually require both entitlements." So SNMP needs
  `network.client` and `network.server`.
  https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server
- Multicast entitlement: "The multicast entitlement isn't required on macOS." (TN3179). The entitlement page lists only
  iOS, iPadOS and visionOS. https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast
- Local Network privilege rules from TN3179:
  - **Needs the privilege:** sending a UDP unicast, multicast or broadcast; connecting a UDP socket; receiving an incoming
    UDP multicast or broadcast.
  - **Doesn't need it:** receiving an incoming UDP unicast, so SNMP replies are fine.
  - All multicast addresses and 255.255.255.255 count as local network addresses. A subnet-directed broadcast address
    is an address on the local network.
- API choice: Network framework "does not support UDP broadcast ... use BSD Sockets" (set `SO_BROADCAST`).
  https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api
- Don't hard-code `en0`. Run discovery on every broadcast-capable interface (`getifaddrs`, `SIOCGIFFUNCTIONALTYPE`).
  (TN3179 "Identify the Wi-Fi interface correctly")

### Bonjour browsing with NWBrowser

- "All Bonjour operations require local network access": registering, browsing and resolving. This covers dnssd,
  Network framework and Multipeer. (TN3179)
- `NSBonjourServices` is available on macOS 11+. Its example value is `_ipp._tcp`.
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices
- TN3179 says to add the service types if you register or browse for specific services. It doesn't say macOS enforces
  the key.
- Secondhand Apple engineering reply, relayed by a developer in an Apple forum thread where Quinn asked for the bug:
  "On a Mac, specifying a service in NSBonjourServices, allows only that service to be accessed on the local network.
  No NSBonjourServices means allow all services (with user consent)." UNVERIFIED as official behavior.
  https://developer.apple.com/forums/thread/683798
  - **Decision:** list all six types. Never browse `_services._dns-sd._udp` unless it's listed too.
- Browsing all service types or arbitrary types needs the multicast entitlement on iOS only (TN3179).
- Detecting denial: the browser goes to `.waiting(.dns(kDNSServiceErr_PolicyDenied))` (-65570). (TN3179 "Check for
  local network access")

### Local Network privacy on macOS 15

- Introduced in macOS 15 (WWDC 2024 session 10123). Users set it in System Settings > Privacy & Security >
  Local Network. MDM can't configure it. (TN3179)
- **What triggers the alert:** the first local-network operation, meaning any of these:
  - an outgoing TCP connection
  - sending UDP unicast, multicast or broadcast, or connecting a UDP socket
  - receiving multicast or broadcast
  - resolving `.local` names
  - any Bonjour operation
- **What doesn't:**
  - listening for and accepting TCP
  - receiving unicast UDP
  - a DNS server or proxy on the LAN
  - traffic from WKWebView, SFSafariViewController or Safari
- **Exempt programs:** launchd daemons, root, and Terminal/SSH tools (not launchd agents). This is why a probe run from
  Terminal works while the app fails. (TN3179)
- **During the first prompt:** the system "may deny the operation immediately, before the user has responded". Use
  Network framework, or URLSession with `waitsForConnectivity`, or retry. (TN3179)
  - **Decision:** trigger the alert on purpose before the first search by connecting a UDP socket to a link-local
    address (TN3179's sample). Start the probe only once access works.
- **No query API (FB8711182).** Detect denial this way:
  - NWConnection goes to `.waiting` with `currentPath?.unsatisfiedReason == .localNetworkDenied`. It retries on its
    own once the user allows access.
    https://developer.apple.com/documentation/network/nwpath/unsatisfiedreason-swift.enum/localnetworkdenied
  - Bonjour: PolicyDenied (-65570).
  - UNVERIFIED: what BSD `sendto`/`connect` return when denied (probably `EHOSTUNREACH`; TN3179 doesn't say).
- **Quirks (TN3179 unless noted):**
  - The privilege is per user account.
  - Several installed copies of the app confuse System Settings (FB15568200).
  - No alert appears for very short-lived processes (FB16131937).
  - Identity is tied to the code signature and the executable's UUID. Sign with an Apple identity and keep UUIDs unique.
  - macOS 15.0 was buggy; retest on 15.1+.
  - Reset: macOS 27.2+ has −/+ buttons. Earlier versions have no reset (FB14944392): use a VM snapshot or a fresh user
    account.
  - Admins can exempt networks with `AllowedEthernetLocalNetworkAddresses` and `AllowedWiFiLocalNetworkAddresses`
    (macOS 15.5+, needs a restart).
- **Field reports (Apple DTS, Quinn):**
  - The privilege sometimes changes behavior after a restart, failing while System Settings shows Allowed. Quinn calls
    it an OS problem. https://developer.apple.com/forums/thread/783732
  - macOS 15.4–15.5 had a PolicyDenied bug for Bonjour and `.local` names from simulator apps, fixed in 15.6
    (r. 148870123). https://developer.apple.com/forums/thread/780655
- `NSLocalNetworkUsageDescription`: "Any app that uses the local network, directly or indirectly, should include this
  description." https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription

## Q2. What a sandboxed app can do with CUPS

### Reaching cupsd at all

- macOS cupsd listens on `localhost:631` and on a domain socket at `$localstatedir/run/cupsd` (/private/var/run/cupsd)
  ("Darwin and macOS do their own thing").
  https://github.com/apple-oss-distributions/cups/blob/cups-522.4/cups/config-scripts/cups-network.m4 ,
  https://github.com/apple-oss-distributions/cups/blob/cups-522.4/cups/conf/cupsd.conf.in
- Quinn (Apple DTS, 2017): since 10.12.4 "the sandbox prevents localhost:631 access for security reasons
  (r. 8992907)". `cupsServer` returns the domain-socket path, "which works fine from within the sandbox".
  https://developer.apple.com/forums/thread/76093
  - **Decision:** never connect to `localhost:631`. Use libcups defaults or `cupsServer()`.
- UNVERIFIED: whether the socket needs `com.apple.security.print`. Third-party analysis says the sandbox profile denies
  the cupsd socket without it. Ship it either way, since a test page needs it.
- libcups is public macOS SDK API (`_CUPS_API_*` maps to `API_AVAILABLE(macos(...))`, with additions as late as
  macOS 26). That satisfies 2.5.1 "public APIs".
  https://github.com/apple-oss-distributions/cups/blob/cups-522.4/cups/cups/versioning.h

### Operations and the authorization they need (macOS default policy)

Apple builds CUPS with `--with-adminkey=system.print.admin --with-operkey=system.print.operator`.
https://github.com/apple-oss-distributions/cups/blob/cups-522.4/Makefile

On Darwin this makes:

- the operator requirement `@AUTHKEY(system.print.operator) @admin @lpadmin`
  (https://github.com/apple-oss-distributions/cups/blob/cups-522.4/cups/config-scripts/cups-common.m4 , around lines 367-389)
- the system group `admin` with `SystemGroupAuthKey system.print.admin`
  (https://github.com/apple-oss-distributions/cups/blob/cups-522.4/cups/config-scripts/cups-defaults.m4 , around line 242)

Default policy from `cupsd.conf.in` (link above):

| Operation | Policy | Sandboxed app |
|---|---|---|
| List queues, state, state reasons, `marker-*` (Get-Printers, Get-Printer-Attributes) | `<Limit All>`, no auth | Yes: `cupsGetDests2`, `cupsDoRequest`, or Core Printing `PMServerCreatePrinterList` + `PMPrinterGetState` |
| List jobs (Get-Jobs) | `<Limit All>`. `JobPrivateValues default` hides other users' job details | Yes. Other users' jobs show without names |
| Cancel own job (Cancel-Job), Cancel-My-Jobs | `@OWNER` (+ operator) | Yes. Peer credentials are allowed when `@OWNER` is listed |
| Purge-Jobs | Listed with `@OWNER @SYSTEM` in Apple's template | UNVERIFIED for a non-admin; use Cancel-My-Jobs |
| Cancel-Jobs (all users), Resume-Printer, Enable-Printer, CUPS-Accept-Jobs, Pause-Printer, CUPS-Reject-Jobs | `AuthType Default`, `Require user @AUTHKEY(system.print.operator) @admin @lpadmin` | **No** (see below) |
| CUPS-Add-Modify-Printer, CUPS-Delete-Printer, CUPS-Set-Default, CUPS-Get-Devices | `AuthType Default`, `Require user @SYSTEM` | **No** |

Why the protected operations fail from the sandbox:

- The scheduler refuses `PeerCred` for any resource that requires `@AUTHKEY(...)` or `@SYSTEM` (unless `@OWNER` is also
  listed): "PeerCred authentication not allowed for resource per AUTHKEY policy."
  https://github.com/apple-oss-distributions/cups/blob/cups-522.4/cups/scheduler/auth.c (around lines 396-437)
- The other routes are an `AuthRef`, which libcups builds with `AuthorizationCreate`/`AuthorizationCopyRights`
  (https://github.com/apple-oss-distributions/cups/blob/cups-522.4/cups/cups/auth.c around line 1005), or Basic auth
  (`DefaultAuthType Basic`).
- App Sandbox forbids "Use of Authorization Services API".
  https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- Basic auth with an admin's name and password would pass the `@admin` check in code
  (`cupsdIsAuthorized`, scheduler/auth.c around line 1770). UNVERIFIED on a real Mac. **Not recommended:** the app
  would have to collect admin passwords, and App Review may object (5.1.1 permission and data minimization).
- Root escalation is banned (2.4.5(v)).

Other APIs:

- `NSPrinter` "does not modify printer attributes or control a printing job".
  https://developer.apple.com/documentation/appkit/nsprinter
- Core Printing gives queue state (`PMPrinterGetState`), the device URI (`PMPrinterCopyDeviceURI`) and the host
  (`PMPrinterCopyHostName`), but no supplies.
  https://developer.apple.com/documentation/applicationservices/core_printing
- Supplies come from IPP `marker-levels`, `marker-names`, `marker-colors`, `marker-types`, `marker-low-levels`,
  `marker-high-levels`, `marker-message`, `marker-change-time`, and from `printer-state-reasons`.
  https://github.com/OpenPrinting/cups/blob/master/doc/help/spec-ipp.html
  - UNVERIFIED: how fresh cupsd's copy is while the queue is idle. Ask the device directly over IPP/SNMP/LEDM, using the
    queue's device URI, and treat cupsd's values as a fallback.

### Conclusion: how far the App Store fixer goes

**Can do:**

- Detect a queue that is stopped or paused, rejecting jobs, or stuck on a job.
- Read `printer-state-reasons`, for example `offline-report`, `paused`, `media-empty`, `toner-low`.
- Compare the queue's device URI with what Bonjour and the probe see now. A `socket://`, `lpd://` or `ipp://` queue
  pointing at an IP the printer no longer holds is the usual "offline".
- Ping the device on 631, 9100 and 515.
- Cancel the user's own stuck jobs.

**Can't do:** resume, accept, cancel other users' jobs, add, delete or re-point a queue.

**Hand-off:**

- Open Printers & Scanners with `x-apple.systempreferences:com.apple.Print-Scan-Settings.extension`. UNVERIFIED: Apple
  doesn't document it; the ID comes from admin community lists. Fall back to opening System Settings plus
  step-by-step text.
- Tell the user exactly what to click: Resume in the queue window, or remove and re-add the printer (Inkvolt shows the
  correct address).
- A one-click fixer would need a Developer ID build with an authorization prompt, outside the App Store.

## Q3. App Store Review Guidelines (last updated October 16, 2026)

Source for all items: https://developer.apple.com/app-store/review/guidelines/

**2.4.5, Mac App Store requirements:**

- (i) must be sandboxed
- (ii) Xcode packaging, no third-party installers, no code in shared locations
- (iii) "may not auto-launch or have other code run automatically at startup or login without consent nor spawn
  processes that continue to run without consent after a user has quit the app"
- (iv) no downloading standalone apps, kexts or extra code
- (v) "may not request escalation to root privileges or use setuid attributes"
- (vi) no license screens or keys
- (vii) "must use the Mac App Store to distribute updates; other update mechanisms are not allowed"
- (viii) currently shipping OS, no deprecated or optionally installed technologies

**2.5 software requirements:**

- 2.5.1: public APIs only; use frameworks for their intended purpose.
- 2.5.2: self-contained bundle, no reading or writing outside the container.
- 2.5.4: background services only for their intended purposes.
- 2.5.5: "fully functional on IPv6-only networks".
- 2.5.14: explicit consent and a visible indication when recording user activity. Not applicable unless scan history
  counts; scans are user-initiated.
- 2.5.16: notifications must relate to the app.
- 2.5.19: no hidden or undocumented features.
- 2.4.2: power efficiency, no unrelated background work. This matters for menu bar polling: poll gently and back off
  on battery (our design choice).

**2.3.1(a):** describe features specifically in Review Notes. Our plan, not Apple's: explain why the app has the
`network.server` entitlement (SNMP replies only, nothing listens) and what the network search sends.

**4.2 minimum functionality and 4.3 spam:** a printer and scanner utility isn't a listed saturated category. Fine.

**5.1.1 data collection:**

- (i) privacy policy link in App Store Connect and in the app
- (ii) consent for any collection; purpose strings must "clearly and completely describe" the use
- (iii) data minimization
- (iv) respect denied permissions and offer alternatives: a typed address when Local Network is denied
- (v) no login unless account features are significant

The guidelines say nothing specific about local network use.

**Privacy label:** "Data that is processed only on device is not 'collected'". User-initiated, optional reports that
meet all the Optional Disclosure criteria needn't be disclosed.
https://developer.apple.com/app-store/app-privacy-details/

**Privacy manifest:**

- The data-collection section applies on all platforms.
- Required-reason APIs are an iOS, iPadOS, tvOS, visionOS and watchOS rule.
- https://developer.apple.com/documentation/bundleresources/privacy-manifest-files ,
  https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api

**Launch at login and the menu bar:**

- `SMAppService.mainApp` (macOS 13+): "configure the main app to launch at login". `register()` can return
  `kSMErrorLaunchDeniedByUser`. Use `status` and `openSystemSettingsLoginItems()`.
  https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp ,
  https://developer.apple.com/documentation/servicemanagement/smappservice/register()
- **Decision:** make it an opt-in toggle, off by default (2.4.5(iii)).
- UNVERIFIED: Apple's SMAppService page doesn't state sandbox support in words. It's widely used by App Store apps;
  confirm on device.
- `MenuBarExtra` (SwiftUI, macOS 13+) is "a persistent control in the system menu bar".
  https://developer.apple.com/documentation/swiftui/menubarextra
- Quitting the app must remove the menu bar item and stop all polling (2.4.5(iii)).

## Q4. Inkvolt PDF: AGPL, Sparkle 2, Developer ID, MuPDF commercial license

**Sparkle's license**

- MIT/Expat. Bundled parts:
  - bsdiff/bspatch: BSD 2-clause style
  - sais-lite: MIT style
  - Ed25519 (Orson Peters): zlib style
  - SUSignatureVerifier: BSD 2-clause style
  - https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE
- GNU lists Expat, zlib and 2-clause BSD as GPL-compatible
  (https://www.gnu.org/licenses/license-list.html#Expat , #ZLib , #FreeBSD). AGPLv3 is GPLv3 plus §13, and the two may
  be combined. https://www.gnu.org/licenses/gpl-faq.html#AGPLGPL
- **No conflict.** Ship Sparkle's notices.

**EdDSA signing**

- `generate_keys` stores the private key in the login Keychain (`-x` exports, `-f` imports). Put the public key in
  `SUPublicEDKey`.
- `generate_appcast` signs automatically. `sign_update` gives `sparkle:edSignature` and the length.
- `SURequireSignedFeed` also signs the feed.
- https://sparkle-project.org/documentation/ , https://sparkle-project.org/documentation/publishing/

**Apple signing alongside Sparkle**

- Sparkle recommends Developer ID plus notarization.
- Never rotate the Apple certificate and the EdDSA key in the same update.
- With `SUVerifyUpdateBeforeExtraction`, the EdDSA key can change only through a Developer ID–signed DMG.
- https://sparkle-project.org/documentation/ , https://sparkle-project.org/documentation/eddsa-migration/

**Sandboxed vs unsandboxed**

- Unsandboxed, which is our case: nothing extra.
- Sandboxed setup needs all of these:
  - `SUEnableInstallerLauncherService=YES`
  - `com.apple.security.temporary-exception.mach-lookup.global-name` for `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki`
  - either `network.client` or `SUEnableDownloaderService`
  - https://sparkle-project.org/documentation/sandboxing/
- Latest release: 2.10.1 (2026-10-25). https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1

**Developer ID, notarization and the AGPL**

- Notarization "is not App Review". It's an automated check.
  https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Users can run modified builds that aren't notarized via Open Anyway. https://support.apple.com/en-us/102445
- GPLv3 §6 Installation Information applies only to "User Products" (hardware). A separately distributed Mac app has
  no key-disclosure duty. https://www.gnu.org/licenses/gpl-3.0.txt , https://www.gnu.org/licenses/gpl-faq.html#GiveUpKeys
- AGPL §13 targets programs "expressly designed to accept user requests and send responses over a network". A
  desktop app likely isn't one. https://www.gnu.org/licenses/gpl-faq.html#AGPLv3InteractingRemotely
- Contrast: the FSF holds the App Store's terms in conflict with the GPL (2010, iOS, GNU Go). This is one more reason
  the PDF app stays off the App Store. https://www.fsf.org/news/2010-05-app-store-compliance

**Artifex MuPDF licensing**

- Dual license: AGPLv3 or commercial. AGPL users must disclose modifications and keep the producer metadata. "If you
  can't meet the requirements of the GNU AGPLv3 ... a commercial license is required."
- Commercial models: OEM Distribution and Subscription, per copy with a quarterly minimum and annual reporting. Each is
  tailored to the customer, and no prices are published.
  https://artifex.com/licensing , https://artifex.com/products/mupdf
- **Quote:** use the form at https://artifex.com/contact and choose MuPDF. The pages show no sales email.

## Q5. Competitor matrix (Mac)

| App | Status / supplies | Alerts | Scan presets | Network discovery | Troubleshooting | Brands | Price | Channel | Account | Data collection | Last update | Rating |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| macOS Printers & Scanners + Image Capture | Supply Levels in Printer Info | Dock badge; offline alert | None saved (per-scan settings) | Yes (Add Printer) | Help article only | Any | Free | Built in | No | n/a | With macOS | n/a |
| HP app (was HP Smart) | Ink levels | Low ink/paper, reorder | Shortcuts, scan options | Guided setup | Phone, chat, help | HP | Free | Mac App Store | "Required for full functionality" | **Tracking:** purchases, identifiers. **Linked:** many types incl. location, contact, payment | 26.4.0, Oct 13 2026 | Too few ratings |
| Epson Printer Utility | Status Monitor ink levels | Low-ink reminder documented for Windows only | n/a | n/a | Nozzle check, head clean | Epson | Free | Direct (with driver) | No | UNVERIFIED | UNVERIFIED | n/a |
| Epson ScanSmart | n/a | n/a | Auto-enhance, OCR, Office export | n/a | n/a | Epson | Free (Accounting Ed. paid) | Direct | No | UNVERIFIED | v3.7.9 Mac dmg, 2023-08-30 | n/a |
| Epson Smart Panel | Supplies | n/a | n/a | Wi-Fi setup | Support | Epson | Free | **iOS only, no Mac** | n/a | Linked: contact, identifiers | 5.4.2 (iOS) | n/a |
| Canon IJ Printer Utility2 | Ink levels | Low/empty icon | n/a | Needs Local Network on macOS 15+ | Maintenance | Canon | Free | Direct (with driver) | No | UNVERIFIED | UNVERIFIED | n/a |
| Canon IJ Printer Assistant Tool | n/a | n/a | n/a | n/a | n/a | n/a | n/a | **No Mac build found** (manuals are Windows) | n/a | n/a | n/a | n/a |
| Canon IJ Scan Utility Lite | n/a | n/a | Auto/Document/Photo/Custom; scanner-button actions | Bonjour + Refresh | Help pages | Canon | Free | Direct | No | UNVERIFIED | UNVERIFIED | n/a |
| Canon PRINT | Consumables | n/a | n/a | Setup | n/a | Canon | Free | **iOS/iPadOS/visionOS only** | n/a | **Tracking:** identifiers, usage | 4.0.0 (iOS) | n/a |
| Brother iPrint&Scan | Status colors, ink icons | No pop-ups described | **Workflows** (saved scan settings) | Machine list | n/a | Brother | Free | Mac App Store (macOS 12+) | Not mentioned | Not linked: usage, diagnostics. No tracking | 15.2.1, Aug 3 (2026 inferred) | Too few ratings |

Sources:

- **Apple:**
  - https://support.apple.com/guide/mac-help/mchl71a320e5/mac
  - https://support.apple.com/guide/mac-help/manage-printers-print-jobs-center-mac-mchl33bd189d/mac
  - https://support.apple.com/guide/mac-help/scan-images-documents-a-scanner-mac-mh28032/mac
  - https://support.apple.com/guide/mac-help/solve-printing-problems-on-mac-mh14002/mac
- **HP:** https://apps.apple.com/us/app/hp-print-and-support/id1474276998?mt=12
- **Epson:**
  - https://files.support.epson.com/docid/cpd6/cpd60263/source/printers/source/ink_functions/tasks/checking_status_mac_tanks.html
  - https://files.support.epson.com/htmldocs/nx130_/nx130_ug/Ink.7.2.html
  - https://epson.com/scansmart-document-scanning-software
  - https://epson.com/Support/Scanners/ES-Series/Epson-WorkForce-ES-60W/s/SPT_B11B253201
  - https://apps.apple.com/us/app/epson-smart-panel/id1477796092?platform=mac
- **Canon:**
  - https://ij.manual.canon/ij/webmanual/PrinterDriver/M/TS5000%20series/1.0/EN/PPG/dg-c_ink.html
  - https://ij.manual.canon/ij/webmanual/ScanUtilityLite/M/3.0/EN/SUL/sul-105.html
  - https://apps.apple.com/us/app/canon-print/id664425773?platform=mac
- **Brother:**
  - https://apps.apple.com/us/app/brother-iprint-scan/id1193539993?mt=12
  - https://support.brother.com/g/s/id/htmldoc/ads/cv_ads1800w/use/html/GUID-A944FEC6-A72C-4C6E-BA36-75ED11A627C1_1.html

**Gaps Inkvolt Print can win on:**

- **Multi-brand in one app.** Every vendor tool covers its own brand only. Apple's covers every brand but buries
  supplies in Printer Info and alerts only through a Dock badge.
- **Privacy.** HP and Canon PRINT labels declare tracking, and HP wants an account. "Data Not Collected" and no
  account stand out.
- **Alerts and a menu bar item.** No Mac tool offers configurable low-supply or offline alerts.
- **On the Mac App Store.** Epson and Canon ship driver-bundled direct downloads, and their mobile apps have no Mac
  version.
- **Saved scan presets for any eSCL scanner.** Brother Workflows and Canon Custom work only with their own scanners,
  and Image Capture has no saved presets.
- **An offline fixer with real diagnosis.** That means state reasons, a stale device address, reachability and stuck
  jobs, plus a guided hand-off. Apple offers only a help article.

## Open questions and UNVERIFIED items to test on the Mac

1. **cupsd socket from the sandbox:** do `cupsGetDests2` and Get-Printer-Attributes over the domain socket work with
   `com.apple.security.print`, and fail without it? Are `marker-*` filled in for idle AirPrint and IPP Everywhere queues?
2. **Protected operations:** confirm that Resume-Printer and CUPS-Accept-Jobs from the sandbox return 401/403. Check
   whether Purge-Jobs is allowed for the user's own jobs. Check the macOS name of the `lpadmin` group (`_lpadmin`?).
   Check whether Basic auth with admin credentials is accepted over the socket (test only, not for shipping).
3. **Printers & Scanners deep link:** does `x-apple.systempreferences:com.apple.Print-Scan-Settings.extension` work on
   macOS 15, 26 and 27? Can the app open a specific printer's queue window?
4. **ImageCaptureCore in the sandbox:** with only `device.usb` and `network.client`, do USB and Bonjour scanners
   appear with `.scanner | .local | .bonjour`? Does ICC's network browsing count against the Local Network privilege,
   or prompt?
5. **NSBonjourServices on macOS:** does the six-type list restrict browsing as the secondhand reply says? Does it
   affect ICC?
6. **SNMP broadcast:** does `sendto` to the subnet-directed broadcast address work with `SO_BROADCAST` in the sandbox?
   Which errno appears when Local Network is denied? Do replies arrive with `network.server`, and fail without it?
7. **First run:** does the TN3179 UDP-connect trick reliably raise the alert before the probe? Does the probe recover
   once the user allows access without restarting the search?
8. **Restart glitch** (forum 783732): make the UI tell "denied" apart from "Allowed but failing" and suggest toggling
   the setting.
9. **ATS:** with `NSAllowsLocalNetworking`, do URLSession calls to bare IPv4 addresses (LEDM, eSCL) work on
   macOS 15+? Does self-signed HTTPS work with a custom trust handler?
10. **SMAppService.mainApp in the sandbox:** does it register? What does `status` show after the user disables it in
    Login Items?
11. **App Review:** will reviewers accept the `network.server` entitlement and the subnet probe given clear Review
    Notes? Not stated in the guidelines.
12. **Competitors:** check the UNVERIFIED cells in Q5: Epson and Canon data collection and dates, HP's diagnose tool,
    Brother notifications and account. App Store years were inferred for current-year dates.
13. **Sparkle and AGPL:** read the AGPLv3 §13 text itself (gnu.org rate-limited the fetch). Check whether Sparkle
    checks the Apple signature on every update. Treat whether Sparkle's update check could trigger §13 as a legal
    reading, not a sourced fact.
