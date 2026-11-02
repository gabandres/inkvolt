import Foundation

/// Recognize Text's optional last step (off by default, the Windows app's `ScanPage`): a scanned page's content becomes
/// its cleaned image (`CleanedPageImage`: straightened, despeckled, the paper whitened), drawn over the whole displayed
/// page, and the page is turned upright with its /Rotate. Its comments, links and form fields stay as they were (they turn
/// with the page). Only for pages that are a scan: a page with text is never recognized, so never replaced.
public enum ScanPage {
    /// - Throws: `PdfEditError` for a page that isn't there or a PDF that can't be edited; `OwnerPasswordRequired`.
    public static func writeBack(_ data: [UInt8], _ password: String?, _ pages: [Int: CleanedPageImage]) throws -> [UInt8] {
        if pages.isEmpty { return data }
        return try PageEditor.edit(data, password) { doc in
            let count = try doc.pageCount()
            for (index, img) in pages.sorted(by: { $0.key < $1.key }) {
                guard index >= 0 && index < count else { throw PdfEditError("There is no page \(index + 1).") }
                replace(doc, doc.page(index), img)
            }
        }
    }

    private static func replace(_ doc: MuDoc, _ page: PObj, _ img: CleanedPageImage) {
        // The pixels are already deflated as the stream holds them.
        let image = doc.addStream(img.deflated, dict: doc.dict([
            ("Type", doc.name("XObject")), ("Subtype", doc.name("Image")), ("Width", doc.int(img.width)), ("Height", doc.int(img.height)),
            ("ColorSpace", doc.name(img.channels == 3 ? "DeviceRGB" : "DeviceGray")), ("BitsPerComponent", doc.int(8)),
            ("Filter", doc.name("FlateDecode")),
        ]), deflate: false)

        // The image is upright as displayed; map its unit square onto the (rotated) crop box.
        let frame = PageBoxes.frame(page)
        let (dw, dh) = PageBoxes.displaySize(page)
        let o = frame.toPdf(0, dh), u = frame.toPdf(dw, dh), v = frame.toPdf(0, 0)
        let m = [u.x - o.x, u.y - o.y, v.x - o.x, v.y - o.y, o.x, o.y].map(PdfNum.f).joined(separator: " ")
        page.set("Contents", doc.addStream(Array("q \(m) cm /PdScan Do Q\n".utf8), deflate: false))
        page.set("Resources", doc.dict([("XObject", doc.dict([("PdScan", image)]))]))
        page.remove("Thumb") // the old scan's thumbnail
        if img.quarterTurns % 4 != 0 { page.set("Rotate", doc.int(((PageBoxes.rotate(page) + 90 * img.quarterTurns) % 360 + 360) % 360)) }
    }
}
