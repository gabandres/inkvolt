import AppKit
import PdfCore
import PrintCore

/// File › Show in Finder and Close All (Windows' File › Show in Folder and Close All).
extension DocumentWindowController {
    /// The document's file selected in a Finder window (Windows: Explorer with the file selected).
    @objc func showInFinder(_ sender: Any?) {
        guard let path = pdf.session?.filePath ?? pdf.fileURL?.path else { return NSSound.beep() }
        let url = URL(fileURLWithPath: path)
        Report.progress("show in Finder: \(url.lastPathComponent)")
        if Report.isRunning { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Every document of this window's tabs, one after the other, each asking first when it has changes (its tab in
    /// front); Cancel stops there and leaves the rest open, as Windows' Close All closes a window's tabs. A document
    /// opened meanwhile stays open.
    @objc func closeAll(_ sender: Any?) {
        guard let window else { return }
        let docs = (window.tabbedWindows ?? [window]).compactMap { ($0.windowController as? DocumentWindowController)?.pdf }
        Task { _ = await Self.closeEach(docs) }
    }

    /// Closes `docs` in order; false when one was kept (Cancel, or its window busy saving).
    @discardableResult
    static func closeEach(_ docs: [PdfDocument]) async -> Bool {
        for doc in docs where NSDocumentController.shared.documents.contains(where: { $0 === doc }) {
            doc.windowControllers.first?.window?.makeKeyAndOrderFront(nil) // its tab in front for its question
            let probe = CloseProbe()
            doc.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            while probe.shouldClose == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard probe.shouldClose == true else { return false }
            doc.close()
        }
        return true
    }
}
