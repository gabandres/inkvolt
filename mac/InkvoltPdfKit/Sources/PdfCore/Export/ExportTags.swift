import Foundation

/// What an export takes from a PDF's tags and catalog: its language and the alternate text of its figures (the Windows
/// app's `ExportTags`). Best effort: a file that can't be read here has neither, and the export goes on.
struct ExportTags: Sendable {
    var language: String?
    var figures: [(page: Int, box: RectD?, alt: String)]

    static let none = ExportTags(language: nil, figures: [])

    static func read(_ data: [UInt8]?, _ password: String?) -> ExportTags {
        guard let data, let doc = try? PdfEdit.openToRead(data, password) else { return .none }
        let lang = doc.catalog.text("Lang")?.trimmedWS
        return ExportTags(language: lang, figures: (try? AutoTag.figureAlts(doc)) ?? [])
    }

    /// The page with its figures' text on its pictures: the tag whose box covers a picture, then tags without a box (they
    /// say only which page) in drawing order when as many pictures are left.
    func onPictures(_ page: ExportPage, _ number: Int) -> ExportPage {
        if page.images.isEmpty || figures.isEmpty { return page }
        let here = figures.filter { $0.page == number }
        if here.isEmpty { return page }
        var images = page.images
        var taken = [Bool](repeating: false, count: images.count)
        for figure in here {
            guard let b = figure.box else { continue }
            for i in images.indices {
                let overlap = b.intersect(images[i].box)
                let smaller = min(b.width * b.height, images[i].box.width * images[i].box.height)
                if taken[i] || overlap.isEmpty || overlap.width * overlap.height <= 0.5 * smaller { continue }
                images[i].alt = figure.alt
                taken[i] = true
                break
            }
        }
        let boxless = here.filter { $0.box == nil }.map(\.alt)
        let left = images.indices.filter { !taken[$0] }
        if !boxless.isEmpty && boxless.count == left.count {
            for (k, i) in left.enumerated() { images[i].alt = boxless[k] }
        }
        var page = page
        page.images = images
        return page
    }
}
