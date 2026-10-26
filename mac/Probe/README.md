# InkvoltProbe

A throwaway, sandboxed Mac app with Inkvolt Print's App Store entitlements and Info.plist keys. Each button answers
one of the open items in [`../docs/research/print-v1-platform.md`](../docs/research/print-v1-platform.md) (the section
numbers match). Step P0 of [`../docs/PLAN.md`](../docs/PLAN.md); delete it once the answers are in the research file.

## Build

On the Mac (macOS 15+, Xcode 16+, an Apple Development certificate in the keychain):

```sh
sh build.sh             # the App Store entitlements
sh build.sh noserver    # without com.apple.security.network.server
sh build.sh noprint     # without com.apple.security.print
```

Each run builds, signs and replaces `/Applications/InkvoltProbe.app`. No provisioning profile is needed: every
entitlement is a `com.apple.security.*` one.

## Run

1. **First run, before allowing anything.** Click Entitlements, networks, then TCP sweep straight away: the Local
   Network alert appears. Note what the sweep reports while the alert is open (item 7), then click Allow and run the
   sweep again without restarting.
2. With a network printer's IPv4 address and a CUPS queue name filled in (List queues shows the names), run every
   button once.
3. Rebuild with `noserver`, run both SNMP buttons; rebuild with `noprint`, run the three CUPS buttons.
4. In System Settings > Privacy & Security > Local Network, turn Inkvolt Probe off, then run the SNMP, TCP and Bonjour
   buttons: how does each report the denial (item 8)?
5. Plug in a USB scanner, if there is one, for ImageCaptureCore.

Copy report puts the log on the clipboard. Addresses show only their last octet, and Bonjour shows counts, not names.
Still, keep reports out of the repo: write what was learned into the research file instead.

Resume and Accept-Jobs really resume the queue if macOS allows it; run it on a paused queue to see the difference.
