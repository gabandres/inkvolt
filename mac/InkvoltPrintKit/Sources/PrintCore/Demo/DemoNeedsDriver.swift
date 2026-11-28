import Foundation

/// Demo mode's made-up USB laser and USB scanner with no driver (the Windows app's `DemoNeedsDriverPc`), so the pages show in
/// demo mode, its screenshots and `--report --demo --needs-driver`; nothing about them is real.
public enum DemoNeedsDriver {
    public static let printer = NeedsDriverPrinter(id: "usb-needs-driver:demo", name: "Demo USB laser (no driver)", maker: "HP", isMadeUp: true)

    public static let scanner = NeedsDriverPrinter(id: "usb-needs-driver:scanner-demo", name: "Epson Demo Scanner (no driver)", maker: "Epson",
                                                   kind: .scanner, usbId: "04B8:0000", isMadeUp: true)

    public static let all = [printer, scanner]
}

/// Demo mode's "Get the driver" (the Windows app's `DemoDriverGetter`): a made-up find for the made-up scanner; nothing is
/// asked of any site, opened or downloaded.
public struct DemoDriverGetter: DriverGetter {
    static let page = URL(string: "https://epson.com/Support/sl/s")!

    /// The made-up find comes under a licence to accept first, as Brother's, Canon's and PFU's do (`--driver-licence`).
    let withLicence: Bool
    let delay: Duration

    public init(withLicence: Bool = false, delay: Duration = .milliseconds(300)) {
        self.withLicence = withLicence
        self.delay = delay
    }

    public func looksUp(_ device: NeedsDriverPrinter) -> Bool { device.isMadeUp && device.isScanner }

    public func find(_ device: NeedsDriverPrinter) async -> DriverLookup {
        try? await Task.sleep(for: delay)
        let title = "Scanner Driver (made up)" // English: a maker's page names its downloads in its own words
        return .found(DriverOffer(title: title, version: "1.0.0", sizeText: "12.0 MB", download: Self.page, page: Self.page,
                                  licence: withLicence ? Self.page : nil))
    }

    public func linkFor(_ offer: DriverOffer, _ device: NeedsDriverPrinter) -> URL? { offer.licence ?? offer.download }
}
