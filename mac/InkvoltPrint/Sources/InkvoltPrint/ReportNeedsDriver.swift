import Foundation
import PrintCore
import PrintMac

extension Report {
    /// `--needs-driver [get]`: the USB printers and scanners that need their driver as the sidebar lists them (demo mode's
    /// made-up "Demo USB laser (no driver)" and "Epson Demo Scanner (no driver)"), each page's What to do and, with `get`, Get
    /// the driver run on each that it applies to: what it found and the link it would open (nothing is opened while the report
    /// runs, nor in demo mode). Outside demo mode it first says how many USB devices IOKit lists and of which classes, never their
    /// names (they may be anyone's). `--driver-lookup <maker> <model> printer|scanner`: one real lookup on the maker's site for
    /// this Mac (a few requests), as Get the driver would make it, through the app's own transport (the system's trust, the
    /// sandbox's network client), to check the catalogs from this Mac.
    static func needsDriverCheck(_ model: AppModel, _ args: [String]) async -> [String] {
        var lines: [String] = []
        if !model.isDemo {
            let devices = IOKitUsbDevices().devices()
            lines.append("usb: IOKit lists \(devices.count) devices, \(devices.filter(\.isPrinterClass).count) of the printer class, "
                         + "\(devices.filter(\.isStillImageClass).count) of the still-image class, \(devices.filter(UsbScanners.isScanner).count) scanners by the rules")
        }
        for _ in 0..<20 where model.needingDriver.isEmpty && model.isDemo { try? await Task.sleep(for: .milliseconds(250)) }
        lines.append("needs-driver: " + NeedsDriverText.reportLine(model.needingDriver))
        let get = args.firstIndex(of: "--needs-driver").map { $0 + 1 < args.count && args[$0 + 1] == "get" } ?? false
        for d in model.needingDriver {
            let page = model.driverPage(d)
            lines.append("  \(NeedsDriverText.line(d))")
            lines.append("    \(NeedsDriverText.headline(d))")
            for step in page.steps {
                let button = step.button == .none ? "" : " [\(NeedsDriverText.makerButton(d))\(step.button == .main ? ", main" : "")]"
                lines.append("    \(step.number). \(step.text)\(button)")
            }
            lines.append("    maker's page: \(DriverHelp.page(for: d).absoluteString)")
            lines.append("    Get the driver: \(page.canGetDriver ? DriverText.note(d) : "not offered (\(d.isMadeUp ? "made up: only demo mode's scanner has a made-up find" : DriverText.englishNoOffer(d, .none(.makerNotLookedUp))))")")
            guard get, page.canGetDriver else { continue }
            await page.getDriver()
            if let offer = page.offered {
                lines.append("    found: \(DriverText.englishOffer(offer))")
                lines.append("    opens: \(model.drivers.linkFor(offer, d)?.absoluteString ?? "nothing (off the maker's hosts)")")
                page.openLink()
                lines.append("    then: \(page.result ?? "")")
            } else {
                lines.append("    found nothing: \(page.result ?? "")")
            }
        }
        if let scanner = model.needingDriver.first(where: \.isScanner) {
            lines.append("scan tab line: \(NeedsDriverText.scanTabLine(scanner))")
        }
        if let i = args.firstIndex(of: "--driver-lookup"), i + 3 < args.count {
            let kind: NeedsDriverKind = args[i + 3] == "scanner" ? .scanner : .printer
            let device = NeedsDriverPrinter(id: "usb-needs-driver:lookup", name: args[i + 2], maker: args[i + 1], kind: kind)
            let flow = DriverFlow(catalog: MakerCatalogs.all(MakerWeb(URLSessionTransport(check: .system))), arch: AppModel.arch,
                                  macOS: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            let started = ContinuousClock.now
            let found = await flow.find(device)
            let took = (ContinuousClock.now - started).components.seconds
            if let offer = found.offer {
                lines.append("driver-lookup \(device.maker ?? "") \(device.name) (\(AppModel.arch), macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)), \(took) s: \(DriverText.englishOffer(offer))")
                lines.append("  opens: \(flow.linkFor(offer, device)?.absoluteString ?? "nothing")")
                lines.append("  page: \(offer.page.absoluteString)")
            } else {
                lines.append("driver-lookup \(device.maker ?? "") \(device.name), \(took) s: \(DriverText.englishNoOffer(device, found))\(found.page.map { "; page \($0.absoluteString)" } ?? "")")
            }
        }
        return lines
    }
}
