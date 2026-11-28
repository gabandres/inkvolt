import Foundation
import PrintCore

/// XPS, OXPS, EPUB, comic books (CBZ), FictionBook (FB2) and pictures, which Windows opens with MuPDF (its Open dialog's
/// "Supported files", `PdfEngine.TypeFromPath`). MuPDF reads them on the Mac too; here they open as a PDF made of their
/// pages (`convert`), a new document, as Office files and web pages do.
public enum OtherFormats {
    /// Windows' Open filter beside .pdf, in its order.
    public static let extensions = [".xps", ".oxps", ".epub", ".cbz", ".fb2", ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif"]

    public static func handles(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return !ext.isEmpty && extensions.contains("." + ext.lowercased())
    }

    /// The new document's name: the file's, with .pdf ("Book.epub" → "Book.pdf").
    public static func pdfName(_ path: String) -> String {
        (((path as NSString).lastPathComponent as NSString).deletingPathExtension) + ".pdf"
    }

    /// The file's pages as a PDF; `blank`: the pages that couldn't be read, left blank at their size; `partial`: the pages
    /// stopped while they were drawn, with what was drawn of them.
    /// - Throws: `CancellationError`; `PdfEngineError` when MuPDF can't read the file.
    public static func convert(path: String, cancel: CancelToken? = nil, progress: (Int, Int) -> Void = { _, _ in }) throws -> (pdf: [UInt8], blank: [Int], partial: [Int]) {
        try convert(path: path, cancel: cancel, progress: progress, opened: { _ in })
    }

    static func convert(path: String, cancel: CancelToken? = nil, progress: (Int, Int) -> Void = { _, _ in },
                        opened: (PdfEngine) -> Void) throws -> (pdf: [UInt8], blank: [Int], partial: [Int]) {
        guard let engine = try PdfEngine.openPreview(path: path, cancel: cancel) else { throw PdfEngineError(message: loc("This file is password protected.")) }
        defer { engine.close() }
        opened(engine)
        guard engine.pageCount > 0 else { throw PdfEngineError(message: loc("This file has no pages.")) }
        return try engine.writePdf(cancel: cancel, progress: progress)
    }
}
