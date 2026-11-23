import AppKit
import Foundation
import PDFKit
import PrintCore
import PrintMac

/// `--photo-projects` (roadmap 4.16): a card with a message, a month calendar in English and in Spanish, a year calendar and a
/// collage of ten photos laid out and drawn by `PhotoSheets` as Print Photos draws them, the PDFs read back (pages, text) and
/// saved in the app's folder (`photo-projects-*.pdf`) for a person to look at; each sheet's preview drawn.
extension Report {
    static func photoProjectsCheck(_ model: AppModel) async -> [String] {
        var lines = ["photo projects:"]
        let photos = (0..<10).compactMap { photo(i: $0) }
        guard photos.count == 10 else { return lines + ["  the photos couldn't be drawn"] }
        let inputs = photos.map { PhotoInput(Double($0.width), Double($0.height), 1, .none) }
        let names = (1...10).map { "Photo \($0).jpg" }
        let letter = SheetPaper(8.5, 11, 0.25, 0.25, 0.25, 0.25), a4 = SheetPaper(8.27, 11.69, 0.12, 0.12, 0.12, 0.12)
        @discardableResult
        func run(_ name: String, _ kind: PhotoLayoutKind, _ count: Int, _ paper: SheetPaper, _ set: (inout PhotoLayoutOptions) -> Void) -> [PhotoSheet] {
            var options = PhotoLayoutOptions(kind: kind)
            options.locale = Locale(identifier: "en")
            options.calendarYear = 2026
            options.calendarMonth = 11
            set(&options)
            let sheets = PhotoLayout.sheets(Array(inputs.prefix(count)), options, paper)
            let previews = sheets.compactMap { PhotoSheets.preview($0, photos: photos, names: names, paper: paper, width: 360) }.count
            guard let data = try? PhotoSheets.pdf(sheets, photos: photos, names: names, paper: paper), let pdf = PDFDocument(data: data) else {
                lines.append("  \(name): no PDF")
                return sheets
            }
            let url = AppModel.dataFolder.appendingPathComponent("photo-projects-\(name).pdf")
            try? data.write(to: url)
            let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: " ").split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
            lines.append("  \(name): \(sheets.count) sheets (\(previews) previews, \(pdf.pageCount) PDF pages), cells \(sheets.map(\.cells.count)), lines \(sheets.map(\.lines.count)), "
                         + "texts \(sheets.map(\.texts.count)), two-sided \(PhotoProjects.needsTwoSided(sheets)); text: \(text)")
            return sheets
        }
        let card = run("card", .card, 3, letter) { $0.cardMessage = "Happy birthday!\nLove, Ana" }
        // Sent two-sided only where the queue prints both sides: what the card would go as on each of the demo's queues.
        for _ in 0..<50 where model.isDemo && !model.printers.contains(where: { $0.queueName != nil }) { try? await Task.sleep(for: .milliseconds(200)) }
        for printer in model.printers {
            guard let queue = printer.queueName else { continue }
            let sides = PhotosModel.cardTwoSided(card, queueTwoSided: await HandDuplexPrinting.queueTwoSided(printer, app: model))
            lines.append("  card on \(queue): " + (sides == true ? "sides=two-sided-long-edge" : "one-sided; " + PhotosModel.cardOneSidedNote))
        }
        run("month-en", .monthCalendar, 2, letter) { _ in }
        run("month-es", .monthCalendar, 1, a4) { $0.locale = Locale(identifier: "es") }
        run("year", .yearCalendar, 1, letter) { $0.calendarYear = 2027 }
        run("collage", .collage, 10, letter) {
            $0.collage = .oneLarge
            $0.collageBorder = 0.5
        }
        return lines
    }

    /// A made-up photo: a gradient, landscape for even `i`, portrait for odd.
    private static func photo(i: Int) -> CGImage? {
        let (w, h) = i % 2 == 0 ? (600, 400) : (400, 600)
        let green = CGFloat(0.4) + CGFloat(i) * 0.05
        let components: [CGFloat] = [0.2, green, 0.8, 1, 0.9, 0.7, 0.3, 1]
        let locations: [CGFloat] = [0, 1]
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorSpace: space, colorComponents: components, locations: locations, count: 2) else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return context.makeImage()
    }
}
