import AppKit

/// Inkvolt PDF for Mac (a separate, notarized download), found by its bundle ID through Launch Services: scan presets can
/// end by opening the saved PDF in it, as on Windows. Opening hands Inkvolt PDF the file through NSWorkspace, which the
/// sandbox allows; nothing else is shared between the apps.
enum InkvoltPdfApp {
    static let bundleId = "com.bermudezsystems.InkvoltPdf"

    static var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }
}
