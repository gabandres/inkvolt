import Testing
@testable import PrintCore

/// Ported from DriverReadinessTests.cs (roadmap 4.5): whether each printer prints and scans with no maker's driver
/// (`DriverReadiness`). The Windows half is about Windows' queue drivers and protected print mode; on the Mac a printer that
/// answers IPP is set up driverless by macOS itself (AirPrint, IPP Everywhere), so what has meaning here is what the printer
/// answers and the scanner a maker's driver alone reaches. Adapted: On_Windows_IPP_class_driver_it_is_ready is
/// anIppPrinterIsReadyWithNoDriver (and says AirPrint); A_scanner_only_its_Windows_driver_reaches_is_warned_about is
/// aScannerOnlyItsMakersDriverReachesIsWarnedAbout (an ImageCaptureCore scanner on a maker's module); the status read asks
/// for Mopria (4.2's output tray waits for the Mac half of two-sided by hand). Windows only: Driver_kind,
/// No_queue_is_none, On_the_makers_driver_a_printer_that_answers_IPP_can_move, The_new_queue_is_named_beside_the_old_one
/// (Set up with Windows' driver; PLAN, "Mac differences").
struct DriverReadinessTests {
    private static func answer(_ attributes: [String: [String]]) -> IppResponse {
        IppResponse(statusCode: 0, attributes: attributes.mapValues { $0.map(IppAttributeValue.text) })
    }

    /// As an HP LaserJet MFP M234dw answers (no identifiers): PCLm, PWG and Apple raster, Mopria 2.2 and Mopria Scan 1.4.
    private static let m234dw = answer([
        "document-format-supported": ["application/PCLm", "application/octet-stream", "image/pwg-raster", "image/urf"],
        "mopria-certified": ["2.2"],
        "mopria-certified-scan": ["1.4"],
    ])

    /// An older IPP printer that takes only PostScript or PCL: nothing driverless to send it.
    private static let postScriptOnly = answer(["document-format-supported": ["application/postscript", "application/vnd.hp-PCL"]])

    @Test func aPrintersStatusReadAsksForMopria() {
        for name in ["mopria-certified", "mopria-certified-scan", "document-format-supported"] {
            #expect(IppClient.statusAttributes.contains(name))
        }
    }

    @Test func anIppPrinterIsReadyWithNoDriver() {
        let r = DriverReadiness.assess(Self.m234dw, asked: true, answersEscl: true, makerScanner: false)
        #expect(r.print == .ready)
        #expect(r.scan == .ready)
        #expect(r.answersIpp)
        #expect(r.mopria)
        #expect(r.mopriaScan)
        #expect(r.airPrint)
        // PWG raster only: driverless (IPP Everywhere), not AirPrint.
        let pwg = DriverReadiness.assess(Self.answer(["document-format-supported": ["image/pwg-raster"]]), asked: true, answersEscl: false, makerScanner: false)
        #expect(pwg.print == .ready && !pwg.airPrint && !pwg.mopria)
    }

    @Test func aPrinterAskedThatDoesntAnswerIppIsntReadyAndOneNotAskedIsntKnown() {
        #expect(DriverReadiness.assess(nil, asked: true, answersEscl: false, makerScanner: false).print == .notReady)
        #expect(DriverReadiness.assess(Self.postScriptOnly, asked: true, answersEscl: false, makerScanner: false).print == .notReady)
        #expect(DriverReadiness.assess(nil, asked: false, answersEscl: false, makerScanner: false).print == .notKnown)
    }

    @Test func aScannerOnlyItsMakersDriverReachesIsWarnedAbout() {
        #expect(DriverReadiness.assess(nil, asked: false, answersEscl: false, makerScanner: true).scan == .driverOnly)
        #expect(DriverReadiness.assess(nil, asked: false, answersEscl: true, makerScanner: true).scan == .ready)
        #expect(DriverReadiness.assess(nil, asked: false, answersEscl: false, makerScanner: false).scan == .none)
    }

    @Test func aHostileCertificationIsntOne() {
        let long = Self.answer(["mopria-certified": [String(repeating: "9", count: 17)], "mopria-certified-scan": [""]])
        let r = DriverReadiness.assess(long, asked: true, answersEscl: false, makerScanner: false)
        #expect(!r.mopria && !r.mopriaScan && !r.answersIpp)
    }

    /// Mac only: a scanner's ImageCaptureCore module outside the system's folders is its maker's driver; Apple's AirScan and
    /// its own modules aren't.
    @Test func aScannersModuleTellsAMakersDriver() {
        #expect(!DriverReadiness.isMakerModule("/System/Library/Image Capture/Devices/AirScanScanner.app"))
        #expect(DriverReadiness.isMakerModule("/Library/Image Capture/Devices/EPSON Scanner.app"))
        #expect(!DriverReadiness.isMakerModule(nil))
        #expect(!DriverReadiness.isMakerModule(""))
    }
}
