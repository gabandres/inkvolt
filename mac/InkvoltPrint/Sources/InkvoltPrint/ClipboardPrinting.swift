import AppKit
import CoreText
import ImageIO
import PDFKit
import PrintCore
import UniformTypeIdentifiers

/// Print the Clipboard (roadmap 4.13; the Windows app's `ClipboardPrinting` and `PrintViewModel.PrintClipboardAsync`): what's on
/// macOS's clipboard goes where it prints with the usual options (`ClipboardPrint.choose`): text laid out on pages as PrintCore
/// lays it out and printed as a PDF through the print panel, a picture (saved as a PNG) or pictures copied in Finder to Print
/// Photos, one PDF copied in Finder as Print a PDF prints it, several files to Batch Print. The files made go in a folder of
/// their own in the app's temporary folder, cleared of anything a day old each time.
@MainActor
enum ClipboardPrinting {
    nonisolated static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Inkvolt Print clipboard", isDirectory: true) }

    /// What `pasteboard` holds, and its picture's file data (PNG or TIFF) when the picture can be what prints: no files, and no
    /// text or text that's only its name. The picture's size is read from its header; it isn't decoded here.
    static func read(_ pasteboard: NSPasteboard = .general) -> (content: ClipboardContent, picture: Data?) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.prefix(ClipboardPrint.maxFiles + 1).map(\.path)
        let text = files.isEmpty ? pasteboard.string(forType: .string) : nil
        let wantsPicture = files.isEmpty && (text.map { $0.allSatisfy(\.isWhitespace) || ClipboardPrint.prefersPicture($0) } ?? true)
        var picture: Data?
        var size: PixelSize?
        if wantsPicture, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            picture = data
            size = PixelSize(w, h)
        }
        return (ClipboardContent(text: text, picture: size, files: files), picture)
    }

    /// The menu's Print the Clipboard on `printer`.
    static func print(on printer: PrinterModel, app: AppModel, pasteboard: NSPasteboard = .general) {
        let (content, picture) = read(pasteboard)
        let plan = ClipboardPrint.choose(content)
        let name = ClipboardPrint.name(Date(), String(localized: "Clipboard"))
        switch plan.what {
        case .pdf:
            Printing.printPdf(URL(fileURLWithPath: plan.files[0]), on: printer, app: app)
        case .batch:
            let model = BatchPrintWindow.show(app)
            let urls = plan.files.map { URL(fileURLWithPath: $0) }
            Task { await model.add(urls) }
        case .pictures:
            printPhotos(plan.files.map { URL(fileURLWithPath: $0) }, app: app)
        case .picture:
            guard let picture, let url = try? savePicture(picture, name: name) else { return Printing.alert(failed) }
            printPhotos([url], app: app)
        case .text:
            let metric = Locale.current.measurementSystem == .metric
            let made: (url: URL?, pages: Int, cut: Bool)
            do {
                made = try textPdf(content.text ?? "", name: name, metric: metric)
            } catch {
                return Printing.alert(failed)
            }
            guard let url = made.url, let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else {
                return Printing.alert(String(localized: "There's nothing to print on the clipboard. Copy some text, a picture, or a PDF in Finder, then try again."))
            }
            if made.cut { Printing.alert(String(localized: "The copied text is longer than \(ClipboardPrint.maxPages) pages: only the first \(ClipboardPrint.maxPages) print.")) }
            Printing.print(document, name: name, on: printer, app: app, actualSize: true)
        case .notPrintable:
            Printing.alert(String(localized: "The files on the clipboard aren't PDFs or pictures. Open them in their own app to print them."))
        case .tooBig:
            Printing.alert(String(localized: "What's on the clipboard is too big to print from here. Save it as a file and print that."))
        case .nothing:
            Printing.alert(String(localized: "There's nothing to print on the clipboard. Copy some text, a picture, or a PDF in Finder, then try again."))
        }
    }

    private static var failed: String {
        String(localized: "What's on the clipboard couldn't be made ready to print. Copy it again and try once more.")
    }

    /// Print Photos opened with `urls` in it (the request set anew, so the same files asked for twice open twice).
    static func printPhotos(_ urls: [URL], app: AppModel) {
        app.paneRequest = nil
        Task { @MainActor in
            await Task.yield()
            app.paneRequest = .printPhotos(urls)
        }
    }

    /// The picture as an opaque PNG named `name` (colors as shown: some apps put an alpha channel that's all zero), when it
    /// is no larger than `ClipboardPrint.maxPicturePixels`.
    nonisolated static func savePicture(_ data: Data, name: String) throws -> URL {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.width * image.height <= ClipboardPrint.maxPicturePixels,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let opaque = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let url = try unique(name, "png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, opaque, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// The text on Letter (or A4 where the region is metric) as a PDF named `name`, its lines drawn in Menlo at the size whose
    /// advance is the layout's column (vector text, so it stays sharp at any printer's resolution). Returns its file (nil when
    /// nothing printable was left), its pages, and whether some was left out past `ClipboardPrint.maxPages`.
    nonisolated static func textPdf(_ text: String, name: String, metric: Bool) throws -> (url: URL?, pages: Int, cut: Bool) {
        let layout = metric ? ClipboardPrint.layout(8.27, 11.69) : ClipboardPrint.layout(8.5, 11)
        var cut = false
        let pages = ClipboardPrint.pages(text, layout.columns, layout.lines, cut: &cut)
        if pages.isEmpty { return (nil, 0, cut) }
        let url = try unique(name, "pdf")
        let partial = url.appendingPathExtension("partial")
        var box = CGRect(x: 0, y: 0, width: layout.paperWidthInches * 72, height: layout.paperHeightInches * 72)
        guard let pdf = CGContext(partial as CFURL, mediaBox: &box, [kCGPDFContextTitle: name] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let font = monospaced(points: layout.fontPoints)
        let ascent = CTFontGetAscent(font)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
        for page in pages {
            pdf.beginPDFPage(nil)
            for (i, line) in page.enumerated() where !line.isEmpty {
                // The line's top at the margin plus its place, as Windows draws it; Core Graphics counts up from the bottom.
                let top = (layout.marginInches + Double(i) * layout.lineInches) * 72
                pdf.textPosition = CGPoint(x: layout.marginInches * 72, y: box.height - top - ascent)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), pdf)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return (url, pages.count, cut)
    }

    /// Menlo at the size whose advance is `points` × `ClipboardPrint.charWidth` (Windows' Consolas advance), so a line of the
    /// layout's columns fits between the margins.
    nonisolated static func monospaced(points: Double) -> CTFont {
        let probe = CTFontCreateWithName("Menlo" as CFString, 100, nil)
        var glyph = CGGlyph(0)
        var character = UniChar(UInt8(ascii: "M"))
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(probe, &character, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(probe, .horizontal, &glyph, &advance, 1)
        }
        let perPoint = advance.width > 0 ? advance.width / 100 : 0.6
        return CTFontCreateWithName("Menlo" as CFString, points * ClipboardPrint.charWidth / perPoint, nil)
    }

    /// A file name in `folder` not taken yet, after clearing files a day old.
    nonisolated private static func unique(_ name: String, _ ext: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-86_400)
        for file in ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).prefix(1000) {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < old {
                try? fm.removeItem(at: file)
            }
        }
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
