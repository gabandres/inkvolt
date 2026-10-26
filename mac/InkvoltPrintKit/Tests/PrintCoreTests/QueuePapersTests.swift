import Foundation
import Testing
@testable import PrintCore

/// Print Photos' paper choices from a macOS queue's media list (libcups), and the resolution each photo prints at. Mac only:
/// the Windows app reads the driver's `PrintCapabilities` instead (tested through its view model, not here).
struct QueuePapersTests {
    private static func media(_ name: String, _ w: Double, _ h: Double, margin: Double) -> QueueMedia {
        QueueMedia(name: name, width: w, height: h, left: margin, top: margin, right: margin, bottom: margin)
    }

    /// As an inkjet's queue lists them: letter, letter borderless, 4 × 6 borderless only, A4, legal.
    private static let inkjet = [
        media("na_letter_8.5x11in", 8.5, 11, margin: 0.12),
        media("na_letter_8.5x11in.borderless", 8.5, 11, margin: 0),
        media("na_index-4x6_4x6in.borderless", 4, 6, margin: 0),
        media("na_index-4x6_4x6in", 4, 6, margin: 0.12),
        media("iso_a4_210x297mm", 210 / 25.4, 297 / 25.4, margin: 0.12),
        media("na_legal_8.5x14in", 8.5, 14, margin: 0.12),
    ]

    @Test func eachSizeIsOneChoiceWithItsBorderlessVariant() throws {
        let choices = QueuePapers.photoChoices(Self.inkjet)

        #expect(choices.map(\.label) == ["Letter (8.5 × 11 in)", "4 × 6 in photo", "A4 (21 × 29.7 cm)", "Legal (8.5 × 14 in)"])
        let letter = choices[0]
        #expect(letter.media == "na_letter_8.5x11in")
        #expect(letter.sheet == SheetPaper(8.5, 11, 0.12, 0.12, 0.12, 0.12))
        #expect(letter.borderless?.name == "na_letter_8.5x11in.borderless")
        #expect(letter.sheet(borderless: true) == SheetPaper(8.5, 11, 0, 0, 0, 0))
        #expect(letter.sheet(borderless: false) == letter.sheet)
        // Listed borderless first: the bordered one still becomes the main choice.
        let photo = choices[1]
        #expect(photo.media == "na_index-4x6_4x6in")
        #expect(photo.sheet.left == 0.12)
        #expect(photo.borderless != nil)
        // No borderless variant: asking for it changes nothing.
        #expect(choices[3].borderless == nil)
        #expect(choices[3].sheet(borderless: true) == choices[3].sheet)
    }

    @Test func theRegionsUsualPaperComesFirst() {
        let choices = QueuePapers.photoChoices(Self.inkjet)
        #expect(QueuePapers.preferred(choices, metric: true)?.label == "A4 (21 × 29.7 cm)")
        #expect(QueuePapers.preferred(choices, metric: false)?.label == "Letter (8.5 × 11 in)")
        #expect(QueuePapers.preferred(Array(choices.suffix(1)), metric: false)?.label == "Legal (8.5 × 14 in)")
        #expect(QueuePapers.preferred([], metric: false) == nil)
    }

    @Test func sizesWithinAHairAreTheSamePaperAndEmptyOnesAreLeftOut() {
        let choices = QueuePapers.photoChoices([Self.media("a", 8.5, 11, margin: 0.2), Self.media("b", 11.02, 8.49, margin: 0),
                                                Self.media("c", 0, 0, margin: 0)])
        #expect(choices.count == 1)
        #expect(choices[0].borderless?.name == "b")
    }

    @Test func eachPhotoSaysTheLowestResolutionItPrintsAt() {
        let paper = SheetPaper(8.5, 11, 0.25, 0.25, 0.25, 0.25)
        // A 1200 × 800 picture as 4 × 6 prints: 200 dpi. A 600 × 400 one: 100 dpi, soft.
        let photos = [PhotoInput(1200, 800, 2, .none), PhotoInput(600, 400, 1, .none)]
        let sheets = PhotoLayout.sheets(photos, PhotoLayoutOptions(kind: .printSize, size: PhotoSizes.in4x6), paper)
        let dpi = PhotoLayout.printDpi(sheets, photos)

        #expect(dpi.count == 2)
        #expect(abs((dpi[0] ?? 0) - 200) < 1)
        #expect(abs((dpi[1] ?? 0) - 100) < 1)
        #expect((dpi[1] ?? 0) < PhotoLayout.lowDpi)
        // Zoomed in to twice the size, the same picture prints at half the resolution.
        let zoomed = [PhotoInput(1200, 800, 1, PhotoCrop(2, 0, 0))]
        let z = PhotoLayout.printDpi(PhotoLayout.sheets(zoomed, PhotoLayoutOptions(kind: .printSize, size: PhotoSizes.in4x6), paper), zoomed)
        #expect(abs((z[0] ?? 0) - 100) < 1)
        #expect(PhotoLayout.printDpi([], photos) == [nil, nil])
    }
}
