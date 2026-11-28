import Foundation

/// The steps "Get the driver" takes, each run by a click (the Windows app's `IDriverGetter`, its link half): the app's
/// `DriverFlow`, demo mode's made-up find.
public protocol DriverGetter: Sendable {
    func looksUp(_ device: NeedsDriverPrinter) -> Bool
    func find(_ device: NeedsDriverPrinter) async -> DriverLookup
    /// The maker's own link to open in the browser; nil when it isn't on the maker's hosts.
    func linkFor(_ offer: DriverOffer, _ device: NeedsDriverPrinter) -> URL?
}

/// "Get the driver" on the Mac (the Windows app's `DriverFlow` in its `DriverMode.OpenLink`, a Store copy's, which is every
/// Mac copy: the Mac App Store app never downloads or runs an installer, App Review Guideline 2.4.5): the maker's own
/// download for the model and this Mac (`DriverCatalog`), found on the maker's site, and its link (or its licence's page)
/// opened in the browser, where the person downloads and installs it. The app then watches for the device becoming usable
/// (`DeviceState`): "Look again" asks once more.
public struct DriverFlow: DriverGetter {
    let catalog: any DriverCatalog
    let arch: MacArch
    let macOS: Int

    public init(catalog: any DriverCatalog, arch: MacArch, macOS: Int) {
        self.catalog = catalog
        self.arch = arch
        self.macOS = macOS
    }

    public func looksUp(_ device: NeedsDriverPrinter) -> Bool {
        !device.isMadeUp && catalog.looksUp(device.maker) && MakerSource.for(device.maker) != nil
    }

    public func find(_ device: NeedsDriverPrinter) async -> DriverLookup {
        guard looksUp(device) else { return .none(.makerNotLookedUp) }
        return await catalog.find(.for(device, arch: arch, macOS: macOS))
    }

    /// What opens: the maker's page with the licence the download is under, when the maker asks for one to be accepted (the
    /// person accepts it there and downloads from it), else the file itself; nil when it isn't on the maker's hosts.
    public func linkFor(_ offer: DriverOffer, _ device: NeedsDriverPrinter) -> URL? {
        guard let source = MakerSource.for(device.maker) else { return nil }
        if let licence = offer.licence { return MakerWeb.isAllowed(licence, source.pageHosts) ? licence : nil }
        return MakerWeb.isAllowed(offer.download, source.downloadHosts) ? offer.download : nil
    }

    /// Whether macOS has the device now; a read that throws is "not yet", a cancellation still ends it.
    public static func isThereNow(_ isThere: @Sendable () async throws -> Bool) async -> Bool {
        do {
            return try await isThere()
        } catch {
            return false
        }
    }
}

/// The button a step of "What to do" has: the maker's page, as the page's main (accent) button or a plain one.
public enum StepButton: Sendable { case none, main, plain }

/// One numbered step of a device's "What to do".
public struct DriverStep: Sendable, Equatable {
    public let number: Int
    public let text: String
    public let button: StepButton
}

/// "What to do" on the page of a device that needs its driver, numbered in order (the Windows app's `DriverSteps`): the
/// maker's driver (its page's button the page's main one only where Get the driver doesn't apply: there, Get the driver and
/// then Download it from the maker are), plugging it in (only while it isn't), and running the installer (watched for after
/// Get the driver's link).
public enum DriverSteps {
    /// - Parameters:
    ///   - present: the device is plugged in now (it was in the last read of the Mac's USB devices).
    ///   - getDriver: Get the driver applies to the device (its maker is looked up).
    public static func `for`(_ p: NeedsDriverPrinter, present: Bool, getDriver: Bool) -> [DriverStep] {
        var steps: [(String, StepButton)] = [(NeedsDriverText.stepGetDriver(p), getDriver ? .plain : .main)]
        if !present { steps.append((NeedsDriverText.stepPlugIn(p), .none)) }
        steps.append((install(p, getDriver), .none))
        return steps.enumerated().map { DriverStep(number: $0.offset + 1, text: $0.element.0, button: $0.element.1) }
    }

    private static func install(_ p: NeedsDriverPrinter, _ getDriver: Bool) -> String {
        guard getDriver else { return NeedsDriverText.stepInstall(p) }
        return p.isScanner
            ? loc("Run {0}'s installer. Inkvolt Print watches for the scanner and says when it's ready. If it doesn't, unplug the scanner and plug it back in, or press {1}.", p.maker ?? "", DriverText.lookAgainButton)
            : loc("Run {0}'s installer. Inkvolt Print watches for the printer and says when it's ready. If it doesn't, unplug the printer and plug it back in, or press {1}.", p.maker ?? "", DriverText.lookAgainButton)
    }
}

/// Every word "Get the driver" shows (the Windows app's `DriverText`, its link half), and the report's and the log's in
/// English. Never an address but the maker's site's name, never a serial.
public enum DriverText {
    private static func maker(_ d: NeedsDriverPrinter) -> String { d.maker ?? "" }

    public static var button: String { loc("Get the driver") }

    /// What Get the driver does: it only finds the maker's link.
    public static func note(_ d: NeedsDriverPrinter) -> String {
        d.isScanner
            ? loc("Inkvolt Print looks for {0}'s own driver for this scanner and this Mac on {0}'s website and gives you {0}'s download link. It doesn't download or install drivers itself.", maker(d))
            : loc("Inkvolt Print looks for {0}'s own driver for this printer and this Mac on {0}'s website and gives you {0}'s download link. It doesn't download or install drivers itself.", maker(d))
    }

    public static func looking(_ d: NeedsDriverPrinter) -> String { loc("Looking on {0}'s website…", maker(d)) }

    public static func foundTitle(_ d: NeedsDriverPrinter) -> String { loc("Found on {0}'s website", maker(d)) }

    /// What the page shows of a download it will only link to: title, version, size as the page says, and its host.
    public static func offerFacts(_ o: DriverOffer) -> String {
        [loc("Driver: {0}", o.title), loc("Version: {0}", o.version ?? loc("not given")), loc("Size: {0}", o.sizeText ?? loc("not given")),
         loc("From: {0}", o.download.host ?? "")].joined(separator: "\n")
    }

    /// An offer with a licence: the maker's page opens, not the file.
    public static func licenceLinkNote(_ d: NeedsDriverPrinter) -> String { loc("{0}'s page with its licence opens: accept it there to download the driver.", maker(d)) }
    public static func readLicence(_ d: NeedsDriverPrinter) -> String { loc("Read {0}'s licence", maker(d)) }

    public static func openLinkButton(_ d: NeedsDriverPrinter) -> String { loc("Download it from {0}", maker(d)) }

    public static func openLinkNote(_ d: NeedsDriverPrinter) -> String {
        d.isScanner ? loc("Your browser downloads {0}'s installer. Run it and follow its steps: Inkvolt Print watches for the scanner and says when it's ready.", maker(d))
            : loc("Your browser downloads {0}'s installer. Run it and follow its steps: Inkvolt Print watches for the printer and says when it's ready.", maker(d))
    }

    public static var lookAgainButton: String { loc("Look again") }
    public static var waiting: String { loc("Waiting for the driver: run the installer you downloaded.") }
    public static var lookingAgain: String { loc("Looking again…") }

    public static func foundIt(_ d: NeedsDriverPrinter) -> String {
        d.isScanner ? loc("Found it: {0} is ready to scan. It's selected in the Scan tab.", d.name)
            : loc("Found it: the driver is installed. The printer shows in the list in a moment.")
    }

    public static func notYet(_ d: NeedsDriverPrinter) -> String {
        loc("macOS doesn't have it yet. Once the installer has finished, unplug the {0}, plug it back in and press Look again.", d.name)
    }

    /// Why nothing is offered; nil when the button isn't shown for this maker at all.
    public static func unavailable(_ d: NeedsDriverPrinter, _ l: DriverLookup) -> String? {
        switch l.why {
        case .notFound: loc("{0}'s website has no driver for the {1} for this version of macOS. {0}'s page below may say more.", maker(d), d.name)
        case .noArm64: loc("{0} has no driver for the {1} that runs on this Mac's Apple silicon, only for Macs with Intel processors.", maker(d), d.name)
        case .unreachable: loc("{0}'s website didn't answer. Check the internet connection and try again.", maker(d))
        default: nil
        }
    }

    /// A link off the maker's hosts: never opened.
    public static func otherSite(_ d: NeedsDriverPrinter) -> String { loc("The download led to a site that isn't {0}'s, so nothing was downloaded.", maker(d)) }

    public static var demo: String { loc("Demo: a made-up driver. Nothing is downloaded or installed.") }

    // MARK: The report and the log (English)

    public static func englishNoOffer(_ d: NeedsDriverPrinter, _ l: DriverLookup) -> String {
        switch l.why {
        case .makerNotLookedUp: "Inkvolt Print doesn't look up \(d.maker ?? "this maker")'s drivers"
        case .notFound: "\(d.maker ?? "")'s site has no driver for the \(d.name) for this macOS"
        case .noArm64: "\(d.maker ?? "") has no Apple silicon driver for the \(d.name)"
        default: "\(d.maker ?? "")'s site didn't answer (\(l.problem.map { "\($0)" } ?? "unreachable"))"
        }
    }

    public static func englishOffer(_ o: DriverOffer) -> String {
        "\(o.title) | version \(o.version ?? "?") | \(o.sizeText ?? "size not given") | from \(o.download.host ?? "")\(o.licence.map { " | licence on \($0.host ?? "")" } ?? "")"
    }
}
