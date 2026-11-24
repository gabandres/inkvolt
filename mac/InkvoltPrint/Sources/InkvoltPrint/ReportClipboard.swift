import AppKit
import Foundation
import PDFKit
import PrintCore

/// `--clipboard` (roadmap 4.13): Print the Clipboard's reading and making, on a pasteboard of the check's own (the user's
/// clipboard is left alone) and without the print panel: text laid out and written as a PDF (its pages, size and text read
/// back), a copied picture with an empty alpha channel saved opaque, a picture with only its address beside it, files
/// copied in Finder.
extension Report {
    static func clipboardCheck() -> [String] {
        let board = NSPasteboard(name: NSPasteboard.Name("com.bermudezsystems.InkvoltPrint.clipboard-check"))
        defer { board.releaseGlobally() }
        var lines = ["clipboard:"]

        board.clearContents()
        let text = (1...130).map { "Line \($0)\tof the copied text, long enough to wrap once it passes the right margin of the page, as text pasted from a mail does." }
            .joined(separator: "\n")
        board.setString(text, forType: .string)
        let read = ClipboardPrinting.read(board)
        lines.append("  text: plan \(ClipboardPrint.choose(read.content).what)")
        if let made = try? ClipboardPrinting.textPdf(text, name: "Clipboard check", metric: false), let url = made.url,
           let pdf = PDFDocument(url: url), let first = pdf.page(at: 0) {
            let box = first.bounds(for: .mediaBox)
            let found = (first.string ?? "").contains("Line 1 ")
            lines.append("  text PDF: \(made.pages) pages (\(pdf.pageCount) read back), \(Int(box.width)) × \(Int(box.height)) pt, cut \(made.cut), first line read back \(found)")
            let widest = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }.map { page -> Double in
                (page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []).map { $0.bounds(for: page).maxX }.max() ?? 0
            }.max() ?? 0
            let margin: Double = Double(box.width) - 54
            let inside: Bool = widest <= margin + 1
            lines.append("  text PDF: widest line ends at \(Int(widest)) pt of \(Int(margin)) (inside the right margin: \(inside))")
        } else {
            lines.append("  text PDF: not made")
        }

        // Text whose bytes can't fit in maxChars: said too big without being read into a String.
        board.clearContents()
        board.setData(Data(repeating: 0x78, count: ClipboardPrint.maxChars * 4 + 1), forType: .string)
        let huge = ClipboardPrinting.read(board)
        lines.append("  huge text: too big \(huge.tooBig), text read \(huge.content.text != nil)")

        board.clearContents()
        guard let png = clearPicture(width: 300, height: 200) else { return lines + ["  picture: not drawn"] }
        board.setData(png, forType: .png)
        let picture = ClipboardPrinting.read(board)
        lines.append("  picture: plan \(ClipboardPrint.choose(picture.content).what), size \(picture.content.picture.map { "\($0.width) × \($0.height)" } ?? "none")")
        if let data = picture.picture, let url = try? ClipboardPrinting.savePicture(data, name: "Clipboard check"),
           let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            lines.append("  picture PNG: \(url.lastPathComponent), \(image.width) × \(image.height), alpha \(image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst ? "none" : "kept")")
        } else {
            lines.append("  picture PNG: not saved")
        }
        board.setString("https://example.com/cat.png", forType: .string)
        lines.append("  picture with its address: plan \(ClipboardPrint.choose(ClipboardPrinting.read(board).content).what)")

        board.clearContents()
        let urls = ["a.pdf", "b.png", "notes.docx"].map { NSURL(fileURLWithPath: NSTemporaryDirectory() + $0) }
        board.writeObjects(urls)
        let files = ClipboardPrint.choose(ClipboardPrinting.read(board).content)
        lines.append("  files: plan \(files.what), \(files.files.map { ($0 as NSString).lastPathComponent })")
        return lines
    }

    /// A PNG whose every pixel has alpha 0 (as some apps copy a picture), its colour mid-blue.
    private static func clearPicture(width: Int, height: Int) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
