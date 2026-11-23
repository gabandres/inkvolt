import Foundation
import PrintCore

/// Recognize Text's optional last step (off by default, the Windows app's `ScanPage`): a scanned page's content becomes
/// its cleaned image (`CleanedPageImage`: straightened, despeckled, the paper whitened), drawn over the whole displayed
/// page, and the page is turned upright with its /Rotate. Its comments, links and form fields stay as they were (they turn
/// with the page). Only for pages that are a scan: a page with text is never recognized, so never replaced. A page whose
/// scan was black and white (every image it draws at 1 bit) stays black and white: the cleaned page at 1 bit, as lossless
/// JBIG2, CCITT G4 or Flate (PrintCore's `PdfWriter.oneBitData`, roadmap 4.8), not ten times the size in grey.
public enum ScanPage {
    /// - Throws: `PdfEditError` for a page that isn't there or a PDF that can't be edited; `OwnerPasswordRequired`.
    public static func writeBack(_ data: [UInt8], _ password: String?, _ pages: [Int: CleanedPageImage]) throws -> [UInt8] {
        if pages.isEmpty { return data }
        return try PageEditor.edit(data, password) { doc in
            let count = try doc.pageCount()
            for (index, img) in pages.sorted(by: { $0.key < $1.key }) {
                guard index >= 0 && index < count else { throw PdfEditError(loc("There is no page {0}.", CoreLanguage.number(index + 1))) }
                try replace(doc, doc.page(index), img)
            }
        }
    }

    private static func replace(_ doc: MuDoc, _ page: PObj, _ img: CleanedPageImage) throws {
        let image: PObj
        if img.channels == 1, isOneBit(page), let bits = oneBit(img) {
            let (coding, data) = try PdfWriter.oneBitData(bits, jbig2: true)
            image = doc.addStream(data, dict: doc.dict([
                ("Type", doc.name("XObject")), ("Subtype", doc.name("Image")), ("Width", doc.int(img.width)), ("Height", doc.int(img.height)),
                ("ColorSpace", doc.name("DeviceGray")), ("BitsPerComponent", doc.int(1)),
            ]), deflate: false)
            OneBitImages.setCoding(image, coding, bits.width, bits.height)
        } else {
            // The pixels are already deflated as the stream holds them.
            image = doc.addStream(img.deflated, dict: doc.dict([
                ("Type", doc.name("XObject")), ("Subtype", doc.name("Image")), ("Width", doc.int(img.width)), ("Height", doc.int(img.height)),
                ("ColorSpace", doc.name(img.channels == 3 ? "DeviceRGB" : "DeviceGray")), ("BitsPerComponent", doc.int(8)),
                ("Filter", doc.name("FlateDecode")),
            ]), deflate: false)
        }

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

    /// The page draws images, every one of them at 1 bit (a black-and-white scan).
    static func isOneBit(_ page: PObj) -> Bool {
        var (any, all) = (false, true)
        let complete = ContentImages.scan(page) { image, _ in
            any = true
            all = all && (image.int("BitsPerComponent") == 1 || OneBitImages.isStencil(image))
        }
        return complete && any && all
    }

    /// The cleaned grey page at 1 bit: the cleanup has whitened the paper, so the level that best parts ink from paper.
    private static func oneBit(_ img: CleanedPageImage) -> BitImage? {
        guard img.width >= 1, img.height >= 1, img.width <= BitImage.maxPixels / img.height else { return nil }
        let n = img.width * img.height
        guard let gray = Inflate.zlib(img.deflated[...], limit: n), gray.count >= n else { return nil }
        return try? BitImage.fromGray(gray, img.width, img.height, threshold: Bilevel.threshold(gray))
    }
}
