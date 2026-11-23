import Foundation

/// Whether a printer prints with no maker's driver (Windows' `PrintReadiness`, without its Set up with Windows' driver).
public enum PrintReadiness: Equatable, Sendable {
    /// It answers IPP with a raster format (PWG raster, Apple raster or PCLm): macOS prints to it driverless (AirPrint,
    /// IPP Everywhere).
    case ready
    /// It was asked and doesn't answer IPP: only its maker's driver prints to it.
    case notReady
    /// Not known: the printer can't be asked (a USB or shared queue) or hasn't answered yet.
    case notKnown
}

/// Whether its scanner scans with no maker's driver.
public enum ScanReadiness: Equatable, Sendable {
    /// No scanner here.
    case none
    /// It scans over eSCL (AirScan, Mopria Scan): macOS and Inkvolt Print reach it with no driver.
    case ready
    /// It's reached only through its maker's ImageCaptureCore driver.
    case driverOnly
}

/// Ready for a printer with no driver (roadmap 4.5, Windows' `DriverReadiness`): on Windows, Windows Ready Print and protected
/// print mode leave only Windows' IPP class driver; on the Mac, CUPS sets up a printer that answers IPP driverless already,
/// so this says, from what the printer answered, whether it needs a maker's driver at all and whether its scanner does.
public enum DriverReadiness {
    /// Where one printer stands without a maker's driver (roadmap 4.5). Nested: PrintCore's `Readiness` is the Suite's
    /// (`PrinterHealth`).
    public struct Readiness: Equatable, Sendable {
        public var answersIpp: Bool
        public var answersEscl: Bool
        public var mopria: Bool
        public var mopriaScan: Bool
        /// It takes Apple raster (`image/urf`), which AirPrint printers do.
        public var airPrint: Bool
        public var print: PrintReadiness
        public var scan: ScanReadiness
    }

    /// Where the printer stands. `ipp`: its Get-Printer-Attributes answer, or nil when it doesn't answer IPP; `asked`: it was
    /// reached over the network, so no IPP answer means it has none (USB and shared queues can't be asked). It answers IPP
    /// without a driver when it takes a raster format (PWG raster, Apple raster or PCLm). `makerScanner`: its scanner is
    /// reached through a maker's ImageCaptureCore module (`isMakerModule`).
    public static func assess(_ ipp: IppResponse?, asked: Bool, answersEscl: Bool, makerScanner: Bool) -> Readiness {
        let formats = Set((ipp?.strs("document-format-supported") ?? []).prefix(256).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let answersIpp = !formats.isDisjoint(with: rasterFormats)
        let print: PrintReadiness = answersIpp ? .ready : asked ? .notReady : .notKnown
        let scan: ScanReadiness = answersEscl ? .ready : makerScanner ? .driverOnly : .none
        return Readiness(answersIpp: answersIpp, answersEscl: answersEscl, mopria: certified(ipp, "mopria-certified"),
                         mopriaScan: certified(ipp, "mopria-certified-scan"), airPrint: formats.contains("image/urf"),
                         print: print, scan: scan)
    }

    /// What a driverless queue sends: PWG raster (IPP Everywhere), Apple raster (AirPrint), PCLm (Mopria).
    static let rasterFormats: Set<String> = ["image/pwg-raster", "image/urf", "application/pclm"]

    /// A version such as "2.2": present, and short (a hostile answer's long text isn't one).
    private static func certified(_ ipp: IppResponse?, _ name: String) -> Bool {
        ipp?.strs(name).contains { (1...16).contains($0.count) } == true
    }

    /// An ImageCaptureCore device module that is a maker's driver: anything outside the system's own folder (Apple's AirScan
    /// and its other modules are under `/System/Library`; makers' install under `/Library/Image Capture/Devices`).
    public static func isMakerModule(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return !path.hasPrefix("/System/")
    }
}
