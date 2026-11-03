import AppKit

/// Inkvolt PDF for Mac (a separate, notarized download), found by its bundle ID through Launch Services: as on Windows, a
/// scan preset can end by opening the saved PDF in it, Settings' "Open scans in Inkvolt PDF" opens every PDF saved, and
/// the save bar offers Open in Inkvolt PDF after a save. Opening hands Inkvolt PDF the file through NSWorkspace, which the
/// sandbox allows; nothing else is shared between the apps.
enum InkvoltPdfApp {
    static let bundleId = "com.bermudezsystems.InkvoltPdf"

    static var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }

    /// Settings' "Open scans in Inkvolt PDF" (Windows' `OpenScansInInkvoltPdf`), off by default.
    static let openScansKey = "openScansInInkvoltPdf"
    static var openScans: Bool { UserDefaults.standard.bool(forKey: openScansKey) }

    /// Opens the PDFs among `urls` in Inkvolt PDF (a batch's files each in a tab); false when it isn't installed. JPEG scans
    /// are only saved, as on Windows.
    @MainActor
    static func open(_ urls: [URL]) -> Bool {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return true }
        guard let app = url else { return false }
        NSWorkspace.shared.open(pdfs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return true
    }
}
