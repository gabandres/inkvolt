import Foundation
import Testing
@testable import PrintCore

// Photo layouts, EXIF orientation and the paper texts. Ported from PhotoLayoutTests.cs (its three classes, as three suites
// here): all 37 tests, none left out and none adapted; the .NET code uses no WPF types, so its `Placement` is ported as is.

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 5e-7 }

private func near(_ expected: Placement, _ actual: Placement) -> Bool {
    near(expected.x, actual.x) && near(expected.y, actual.y) && near(expected.width, actual.width) && near(expected.height, actual.height)
}

struct PhotoLayoutTests {
    private static let letter = SheetPaper(8.5, 11, 0.25, 0.25, 0.25, 0.25)
    private static let letterBorderless = SheetPaper(8.5, 11, 0, 0, 0, 0)
    private static let a4 = SheetPaper(8.27, 11.69, 0.25, 0.25, 0.25, 0.25)
    private static let photo4x6 = SheetPaper(4, 6, 0.12, 0.12, 0.12, 0.12)
    private static let photo4x6Borderless = SheetPaper(4, 6, 0, 0, 0, 0)

    private static func landscape(copies: Int = 1, crop: PhotoCrop? = nil) -> PhotoInput { PhotoInput(6000, 4000, copies, crop ?? PhotoCrop.none) }
    private static func portrait(copies: Int = 1, crop: PhotoCrop? = nil) -> PhotoInput { PhotoInput(3000, 4000, copies, crop ?? PhotoCrop.none) }

    private static func size(_ size: PhotoSize, fit: PhotoFit = .fill, onePerSheet: Bool = false) -> PhotoLayoutOptions {
        PhotoLayoutOptions(kind: .printSize, size: size, fit: fit, onePhotoPerSheet: onePerSheet)
    }

    // ---- Fit / fill inside a cell ----

    @Test func fillCoversTheCellAndCropsTheLongSideEvenly() {
        let cell = Placement(1, 1, 4, 4)
        let image = PhotoLayout.place(cell, 6, 4, .fill, PhotoCrop.none, turned: false)
        #expect(near(Placement(0, 1, 6, 4), image)) // 6 × 4 scaled to height 4: 1 in cut off each side
    }

    @Test func fitShowsTheWholePhotoCentred() {
        let cell = Placement(0, 0, 4, 4)
        let image = PhotoLayout.place(cell, 6, 4, .fit, PhotoCrop.none, turned: false)
        #expect(near(Placement(0, 2 / 3.0, 4, 8 / 3.0), image))
    }

    @Test func turnedPhotoIsLaidOutOnItsSide() {
        // A 6 × 4 landscape photo in a 4 × 6 portrait cell, turned: fills it exactly.
        let image = PhotoLayout.place(Placement(0, 0, 4, 6), 6, 4, .fill, PhotoCrop.none, turned: true)
        #expect(near(Placement(0, 0, 4, 6), image))
    }

    @Test func panMovesTheCropToAnEdge() {
        let cell = Placement(0, 0, 4, 4)
        let right = PhotoLayout.place(cell, 6, 4, .fill, PhotoCrop(1, 1, 0), turned: false)
        #expect(near(right.x, -2)) // the photo's right edge on the cell's right edge
        let left = PhotoLayout.place(cell, 6, 4, .fill, PhotoCrop(1, -1, 0), turned: false)
        #expect(near(left.x, 0))
    }

    @Test func panIsKeptInThePhotosOwnFrameWhenItIsTurned() {
        // Portrait photo 4 × 6 in a landscape 6 × 3 cell: turned, so the photo's own top (panY = -1) is the cell's right.
        let cell = Placement(0, 0, 6, 3)
        let top = PhotoLayout.place(cell, 4, 6, .fill, PhotoCrop(1, 0, -1), turned: true)
        // Turned it's 6 × 4 scaled to width 6: 6 × 4, 1 in overflow vertically... the photo's x axis is the cell's y axis.
        #expect(near(top.width, 6))
        #expect(near(top.height, 4))
        #expect(near(top.y, -0.5)) // panY moves along the cell's x axis, which has no overflow: centred
        let side = PhotoLayout.place(cell, 4, 6, .fill, PhotoCrop(1, 1, 0), turned: true)
        #expect(near(side.y, -1)) // photo's right (panX = 1) is the cell's bottom
    }

    @Test func zoomEnlargesAroundTheCentre() {
        let cell = Placement(0, 0, 4, 4)
        let image = PhotoLayout.place(cell, 4, 4, .fill, PhotoCrop(2, 0, 0), turned: false)
        #expect(near(Placement(-2, -2, 8, 8), image))
    }

    @Test func draggingPansByTheDistanceMovedAndStopsAtTheEdges() {
        let cell = Placement(0, 0, 4, 4)
        let crop = PhotoCrop.none
        // 6 × 4 filled: 2 in overflow. Dragging the photo 1 in to the right shows its left edge.
        let moved = PhotoLayout.drag(cell, 6, 4, .fill, crop, turned: false, dx: 1, dy: 0)
        #expect(near(moved.panX, -1))
        #expect(near(PhotoLayout.place(cell, 6, 4, .fill, moved, turned: false).x, 0))
        let further = PhotoLayout.drag(cell, 6, 4, .fill, moved, turned: false, dx: 5, dy: 0)
        #expect(near(further.panX, -1))
        // No overflow vertically: dragging up and down changes nothing.
        #expect(near(PhotoLayout.drag(cell, 6, 4, .fill, crop, turned: false, dx: 0, dy: 3).panY, 0))
    }

    @Test func draggingATurnedPhotoPansItInItsOwnFrame() {
        // Portrait 4 × 6 photo turned into a 6 × 3 cell: 1 in overflow along the cell's height, which is the photo's x axis.
        let cell = Placement(0, 0, 6, 3)
        let moved = PhotoLayout.drag(cell, 4, 6, .fill, PhotoCrop.none, turned: true, dx: 0, dy: 0.5)
        #expect(near(moved.panX, -1)) // dragged down: the cell's top shows, the photo's left side
        #expect(near(PhotoLayout.place(cell, 4, 6, .fill, moved, turned: true).y, 0))
    }

    // ---- Print sizes on a sheet ----

    @Test func fourBySixOnLetterIsTwoPerSheet() {
        let grid = PhotoLayout.grid(Self.size(PhotoSizes.in4x6), Self.letter, preferLandscape: true)
        #expect(grid.cells.count == 2)
        #expect(grid.cells.allSatisfy { near($0.width, 6) && near($0.height, 4) })
        #expect(!grid.shrunk)
        // Inside the printable area, not overlapping, centred.
        #expect(grid.cells.allSatisfy { c in
            c.x >= 0.25 - 1e-9 && c.y >= 0.25 - 1e-9 && c.x + c.width <= 8.25 + 1e-9 && c.y + c.height <= 10.75 + 1e-9
        })
        #expect(grid.cells[0].y + grid.cells[0].height <= grid.cells[1].y)
        #expect(near(grid.cells[0].x, 1.25))
    }

    @Test func fourBySixOnLetterWithPortraitPhotosIsTwoSideBySide() {
        let grid = PhotoLayout.grid(Self.size(PhotoSizes.in4x6), Self.letter, preferLandscape: false)
        #expect(grid.cells.count == 2)
        #expect(grid.cells.allSatisfy { near($0.width, 4) && near($0.height, 6) })
        #expect(near(grid.cells[0].y, grid.cells[1].y))
    }

    @Test(arguments: [
        (5, 7, 2), // two landscape 7 × 5 stacked
        (8, 10, 1),
        (2.5, 3.5, 9), // wallets: 3 × 3 portrait
    ] as [(Double, Double, Int)])
    func cellsPerLetterSheet(_ w: Double, _ h: Double, _ expected: Int) {
        let grid = PhotoLayout.grid(Self.size(PhotoSize("test", w, h)), Self.letter, preferLandscape: false)
        #expect(grid.cells.count == expected)
    }

    @Test func tenByFifteenCmOnA4IsTwoPerSheet() {
        let grid = PhotoLayout.grid(Self.size(PhotoSizes.cm10x15), Self.a4, preferLandscape: false)
        #expect(grid.cells.count == 2)
        #expect(near(grid.cells[0].width, 150 / 25.4)) // turned landscape to fit two
    }

    @Test func cellsAreSpacedForCuttingWhenThereIsRoom() {
        let grid = PhotoLayout.grid(Self.size(PhotoSizes.wallet), Self.letter, preferLandscape: false)
        let gap = grid.cells[1].x - (grid.cells[0].x + grid.cells[0].width)
        #expect(near(gap, PhotoLayout.cutGap))
        // Rows: 3 × 3.5 = 10.5 of 10.5 in: no room, so no gap.
        #expect(near(grid.cells[3].y, grid.cells[0].y + 3.5))
    }

    @Test func aSizeLargerThanThePrintableAreaShrinksToIt() throws {
        let grid = PhotoLayout.grid(Self.size(PhotoSizes.in4x6), Self.photo4x6, preferLandscape: false)
        #expect(grid.shrunk)
        try #require(grid.cells.count == 1)
        let cell = grid.cells[0]
        #expect(near(cell.width, 4 - 0.24)) // the width is what limits it
        #expect(near(cell.height, (4 - 0.24) * 6 / 4))
    }

    @Test func fourBySixBorderlessOnFourBySixPaperIsTheWholeSheet() throws {
        let grid = PhotoLayout.grid(Self.size(PhotoSizes.in4x6), Self.photo4x6Borderless, preferLandscape: true)
        #expect(!grid.shrunk)
        try #require(grid.cells.count == 1)
        #expect(near(Placement(0, 0, 4, 6), grid.cells[0]))
    }

    @Test func photosAreTurnedToTheirCellsOrientation() throws {
        let sheets = PhotoLayout.sheets([Self.portrait(), Self.landscape()], Self.size(PhotoSizes.in4x6), Self.letter)
        try #require(sheets.count == 1)
        // One portrait, one landscape photo: tie, so portrait cells; the landscape photo is turned.
        #expect(!sheets[0].cells[0].turned)
        #expect(sheets[0].cells[1].turned)
    }

    @Test func squarePhotosAreNeverTurned() {
        let sheets = PhotoLayout.sheets([PhotoInput(1000, 1000, 1, PhotoCrop.none)], Self.size(PhotoSizes.in4x6), Self.letter)
        #expect(!sheets[0].cells[0].turned)
    }

    @Test func copiesFillCellsInOrderAndFlowOntoMoreSheets() {
        let sheets = PhotoLayout.sheets([Self.landscape(copies: 3), Self.landscape(copies: 2)], Self.size(PhotoSizes.in4x6), Self.letter)
        #expect(sheets.count == 3)
        #expect(sheets.flatMap(\.cells).map(\.photo) == [0, 0, 0, 1, 1])
    }

    @Test func onePhotoPerSheetRepeatsItInEveryCell() {
        let sheets = PhotoLayout.sheets([Self.portrait(copies: 2), Self.portrait()], Self.size(PhotoSizes.wallet, onePerSheet: true), Self.letter)
        #expect(sheets.count == 3)
        #expect(sheets[0].cells.allSatisfy { $0.photo == 0 })
        #expect(sheets[1].cells.count == 9)
        #expect(sheets[2].cells.allSatisfy { $0.photo == 1 })
    }

    @Test func noPhotosNoSheets() {
        #expect(PhotoLayout.sheets([], Self.size(PhotoSizes.in4x6), Self.letter).isEmpty)
    }

    @Test func zeroCopiesPrintNothing() {
        #expect(PhotoLayout.sheets([Self.landscape(copies: 0)], Self.size(PhotoSizes.in4x6), Self.letter).isEmpty)
    }

    // ---- Full page ----

    @Test func fullPageTurnsALandscapePhotoOnPortraitPaper() throws {
        let sheets = PhotoLayout.sheets([Self.landscape(copies: 2)], PhotoLayoutOptions(kind: .fullPage, fit: .fit), Self.letter)
        #expect(sheets.count == 2)
        try #require(sheets[0].cells.count == 1)
        let cell = sheets[0].cells[0]
        #expect(cell.turned)
        #expect(near(Placement(0.25, 0.25, 8, 10.5), cell.cell))
        // 6000 × 4000 turned is 4000 × 6000 wide: fits 8 wide (12 tall > 10.5, so height bound): 7 × 10.5.
        #expect(near(Placement(0.25 + 0.5, 0.25, 7, 10.5), cell.image))
    }

    @Test func fullPageFillBorderlessCoversThePaper() {
        let sheets = PhotoLayout.sheets([Self.portrait()], PhotoLayoutOptions(kind: .fullPage, fit: .fill), Self.letterBorderless)
        let cell = sheets[0].cells[0]
        #expect(cell.image.width >= 8.5 - 1e-9 && cell.image.height >= 11 - 1e-9)
        #expect(near(Placement(0, 0, 8.5, 11), cell.cell))
    }

    // ---- Contact sheet ----

    @Test(arguments: [(6, 2, 3), (12, 3, 4), (20, 4, 5), (30, 5, 6), (48, 6, 8)] as [(Int, Int, Int)])
    func contactGridOnPortraitPaper(_ n: Int, _ cols: Int, _ rows: Int) {
        #expect(PhotoLayout.contactGrid(n, 8, 10.5) == (cols, rows))
    }

    @Test func contactGridOnLandscapePaperHasMoreColumns() {
        #expect(PhotoLayout.contactGrid(12, 10.5, 8) == (4, 3))
    }

    @Test func contactSheetShowsEachPhotoOnceWholeWithItsName() throws {
        let photos = (0..<14).map { $0 % 2 == 0 ? Self.landscape(copies: 3) : Self.portrait() }
        let sheets = PhotoLayout.sheets(photos, PhotoLayoutOptions(kind: .contactSheet, perSheet: 12, fit: .fill), Self.letter)
        #expect(sheets.count == 2)
        #expect(sheets[0].cells.count == 12)
        #expect(sheets[1].cells.count == 2)
        for c in sheets.flatMap(\.cells) {
            #expect(!c.turned)
            let caption = try #require(c.caption)
            // Whole photo inside its cell, above its caption.
            #expect(c.image.x >= c.cell.x - 1e-9 && c.image.x + c.image.width <= c.cell.x + c.cell.width + 1e-9)
            #expect(c.image.y + c.image.height <= caption.y + 1e-9)
            #expect(caption.y + caption.height <= c.cell.y + c.cell.height + 1e-9)
        }
    }

    // ---- Print resolution ----

    @Test func dpiIsPixelsAcrossThePrintedWidth() {
        #expect(near(PhotoLayout.dpi(6000, 4000, Placement(0, 0, 6, 4), turned: false), 1000))
        // Turned: the photo's 6000 px run along the box's height.
        #expect(near(PhotoLayout.dpi(6000, 4000, Placement(0, 0, 2, 3), turned: true), 2000))
        #expect(PhotoLayout.dpi(6000, 4000, Placement(0, 0, 0, 0), turned: false) == 0)
    }

    @Test(arguments: [
        (6000, 6, 300, 1800), // 1000 dpi photo: decode at 300 dpi
        (1200, 6, 300, 1200), // already below: as is
        (6000, 0, 300, 6000),
    ] as [(Int, Double, Int, Int)])
    func decodeWidthCapsThePrintResolution(_ pixels: Int, _ inches: Double, _ maxDpi: Int, _ expected: Int) {
        #expect(PhotoLayout.decodeWidth(pixels, inches, maxDpi) == expected)
    }
}

struct ExifOrientationTests {
    @Test(arguments: [
        (1, 0, false), (2, 0, true), (3, 2, false), (4, 2, true), (5, 3, true), (6, 1, false), (7, 1, true), (8, 3, false),
        (0, 0, false), // missing or bad: as stored
        (9, 0, false),
    ] as [(Int, Int, Bool)])
    func turnsAndMirror(_ orientation: Int, _ turns: Int, _ mirror: Bool) {
        #expect(ExifOrientation.transform(orientation) == (turns, mirror))
    }

    @Test(arguments: [
        (1, 0, 4000, 3000),
        (6, 0, 3000, 4000),
        (6, 1, 4000, 3000), // EXIF turn plus a user turn
        (1, 3, 3000, 4000),
        (1, -1, 3000, 4000), // a turn left is three right
    ] as [(Int, Int, Int, Int)])
    func orientedSize(_ orientation: Int, _ userTurns: Int, _ w: Int, _ h: Int) {
        #expect(ExifOrientation.oriented(4000, 3000, orientation, userTurns) == (w, h))
    }
}

struct PhotoPaperTextTests {
    @Test(arguments: [
        ("NorthAmericaLetter", 8.5, 11, "Letter (8.5 × 11 in)"),
        ("ISOA4", 8.27, 11.69, "A4 (21 × 29.7 cm)"),
        ("NorthAmerica4x6", 4, 6, "4 × 6 in photo"),
        (nil, 5, 7, "5 × 7 in photo"),
        ("Custom", 3.94, 5.91, "10 × 15 cm photo"),
        ("Custom", 5.12, 7.09, "13 × 18 cm photo"),
        ("NorthAmericaLegal", 8.5, 14, "Legal (8.5 × 14 in)"),
        ("Odd", 3.3, 9.1, "3.3 × 9.1 in"),
        ("JapanHagakiPostcard", 3.94, 5.83, "Hagaki postcard (10 × 14.8 cm)"),
    ] as [(String?, Double, Double, String)])
    func paperLabels(_ name: String?, _ w: Double, _ h: Double, _ expected: String) {
        #expect(PhotoPaperText.paper(name, w, h) == expected)
    }

    @Test func paperLabelIgnoresOrientation() {
        #expect(PhotoPaperText.paper(nil, 11, 8.5) == "Letter (8.5 × 11 in)")
    }

    @Test(arguments: [
        ("Plain", "Plain paper"),
        ("Photographic", "Photo paper"),
        ("PhotographicGlossy", "Photo paper, glossy"),
        ("PhotographicHighGloss", "Photo paper, high gloss"),
        ("PhotographicSemiGloss", "Photo paper, semi-gloss"),
        ("PhotographicMatte", "Photo paper, matte"),
        ("PhotographicSatin", "Photo paper, satin"),
        ("AutoSelect", "Let the printer choose"),
        ("CardStockCoated", "Card stock coated"),
        ("Envelope", "Envelope"),
    ] as [(String, String)])
    func mediaTypeLabels(_ name: String, _ expected: String) {
        #expect(PhotoPaperText.mediaType(name) == expected)
    }

    @Test(arguments: [("Photographic", true), ("PhotographicGlossy", true), ("Plain", false)] as [(String, Bool)])
    func photoMedia(_ name: String, _ photo: Bool) {
        #expect(PhotoPaperText.isPhotoMedia(name) == photo)
    }

    @Test(arguments: [
        ("Draft", "Draft"), ("Normal", "Normal"), ("High", "High"), ("Photographic", "Photo (best)"), ("Automatic", "Automatic"),
    ] as [(String, String)])
    func qualityLabels(_ name: String, _ expected: String) {
        #expect(PhotoPaperText.quality(name) == expected)
    }

    @Test(arguments: [("Color", "Color"), ("Grayscale", "Shades of grey"), ("Monochrome", "Black and white")] as [(String, String)])
    func colorLabels(_ name: String, _ expected: String) {
        #expect(PhotoPaperText.color(name) == expected)
    }

    @Test func standardSizesAreListedShortSideFirst() {
        #expect(PhotoSizes.all.count == 6)
        #expect(PhotoSizes.all.allSatisfy { $0.width <= $0.height })
        #expect(PhotoSizes.all.contains { $0.name == "Wallet (2.5 × 3.5 in)" })
    }
}
