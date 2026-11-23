import PrintCore

/// Roadmap 4.5 in the printer's Details (Windows' "Windows' new printer driver" rows, `DriverReadiness`): what a network
/// printer answers (IPP, eSCL, AirPrint, Mopria), whether it needs a maker's driver, and a warning for a scanner only its
/// maker's driver reaches. macOS sets up a printer that answers IPP driverless itself, so there is no Set up with Windows'
/// driver here (PLAN, "Mac differences").
@MainActor
enum PrinterReadiness {
    /// The Details rows: none before a network printer connects, nor for a queue printer (its queue prints already).
    static func rows(_ p: PrinterModel) -> [(label: String, value: String)] {
        guard let r = p.view.readiness else { return [] }
        var rows: [(label: String, value: String)] = [(String(localized: "Printer answers"), answers(r))]
        switch r.print {
        case .ready: rows.append((String(localized: "Driver"), String(localized: "None needed: macOS prints to it driverless")))
        case .notReady: rows.append((String(localized: "Driver"), String(localized: "Its maker's: it doesn't answer IPP, so macOS can't print to it driverless")))
        case .notKnown: break
        }
        return rows
    }

    /// "IPP (AirPrint, Mopria certified), eSCL (Mopria certified)".
    static func answers(_ r: DriverReadiness.Readiness) -> String {
        var parts: [String] = []
        if r.answersIpp {
            let marks = (r.airPrint ? ["AirPrint"] : []) + (r.mopria ? [String(localized: "Mopria certified")] : [])
            parts.append(marks.isEmpty ? "IPP" : "IPP (\(marks.joined(separator: ", ")))")
        }
        if r.answersEscl { parts.append(r.mopriaScan ? "eSCL (\(String(localized: "Mopria certified")))" : "eSCL") }
        return parts.isEmpty ? String(localized: "Neither IPP nor eSCL") : parts.joined(separator: ", ")
    }

    /// A scanner reached only through its maker's ImageCaptureCore driver (no eSCL): it may stop after a macOS update.
    static func scanWarning(_ p: PrinterModel) -> String? {
        let driverOnly = p.view.readiness?.scan == .driverOnly
            || (p.systemScanner?.makerDriver == true && !p.view.interfaces.contains("eSCL"))
        guard driverOnly else { return nil }
        return String(localized: "This scanner works only through its maker's driver, not AirScan: after a macOS update it may stop scanning until its maker updates the driver.")
    }
}
