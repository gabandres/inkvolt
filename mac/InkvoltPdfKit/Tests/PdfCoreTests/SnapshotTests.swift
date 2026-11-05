import Foundation
import Testing
@testable import PdfCore

/// The Snapshot tool's rules (no Windows test to port: the Windows viewer's `CopySnapshot` is the spec): the region a
/// drag marks, the resolution, the 40-megapixel bound and the picture as the view shows the page.
struct SnapshotTests {
    /// A Letter page whose top-left quarter is red, the rest white.
    private static func redCorner() -> [UInt8] {
        Core1TestPdf.build([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            4: Core1TestPdf.stream("1 0 0 rg 0 396 306 396 re f"),
        ])
    }

    @Test func A_drag_marks_the_rectangle_between_its_corners_cut_to_the_page() throws {
        let r = try #require(Snapshot.region(PointD(400, 500), PointD(-20, 900), pageWidth: 612, pageHeight: 792))
        #expect(r == RectD(0, 500, 400, 292))
    }

    @Test(arguments: [
        (PointD(10, 10), PointD(11, 300)),
        (PointD(10, 10), PointD(300, 11.5)),
        (PointD(10, 10), PointD(10, 10)),
        (PointD(700, 10), PointD(900, 300)), // all of it off the page
        (PointD(.nan, 10), PointD(300, 300)),
        (PointD(10, 10), PointD(.infinity, 300)),
    ])
    func A_click_or_a_sliver_copies_nothing(_ start: PointD, _ end: PointD) {
        #expect(Snapshot.region(start, end, pageWidth: 612, pageHeight: 792) == nil)
    }

    @Test func A_page_without_a_size_copies_nothing() {
        #expect(Snapshot.region(PointD(0, 0), PointD(100, 100), pageWidth: 0, pageHeight: 792) == nil)
        #expect(Snapshot.region(PointD(0, 0), PointD(100, 100), pageWidth: .nan, pageHeight: 792) == nil)
    }

    @Test(arguments: [(0.5, 2.0), (1.0, 2.0), (2.0, 2.0), (3.5, 3.5), (Double.nan, 2.0), (-4, 2.0), (Double.infinity, 2.0), (1e9, 2.0)])
    func The_resolution_is_the_views_but_never_under_144_dpi(_ view: Double, _ expected: Double) {
        #expect(Snapshot.scale(for: RectD(0, 0, 200, 100), viewScale: view) == expected)
    }

    @Test func A_large_region_shrinks_until_it_is_under_40_megapixels() {
        let region = RectD(0, 0, 14_400, 14_400) // PDF's largest page
        let scale = Snapshot.scale(for: region, viewScale: 4)
        let pixels = region.width * region.height * scale * scale
        #expect(pixels <= Snapshot.maximumPixels)
        #expect(pixels > Snapshot.maximumPixels * 0.8 * 0.8) // cut a fifth at a time, not more
    }

    @Test func The_picture_is_the_region_at_the_resolution() throws {
        let engine = try PdfEngine.open(Self.redCorner())
        defer { engine.close() }
        let image = try Snapshot.render(engine, page: 0, region: RectD(0, 0, 306, 396), viewScale: 1, rotation: 0)
        #expect(abs(image.width - 612) <= 1)
        #expect(abs(image.height - 792) <= 1)
        let middle = (image.height / 2) * image.stride + (image.width / 2) * 3
        #expect(image.pixels[middle] > 200 && image.pixels[middle + 1] < 60 && image.pixels[middle + 2] < 60, "the red quarter")
    }

    @Test func The_picture_turns_with_the_view() throws {
        let engine = try PdfEngine.open(Self.redCorner())
        defer { engine.close() }
        // The page's top half: red on the left, white on the right; turned clockwise, red on top.
        let image = try Snapshot.render(engine, page: 0, region: RectD(0, 0, 612, 396), viewScale: 1, rotation: 90)
        #expect(image.height > image.width)
        func red(_ x: Int, _ y: Int) -> Bool {
            let i = y * image.stride + x * 3
            return image.pixels[i] > 200 && image.pixels[i + 1] < 60
        }
        #expect(red(image.width / 2, image.height / 4))
        #expect(!red(image.width / 2, image.height * 3 / 4))
        let shown = Snapshot.shownSize(RectD(0, 0, 612, 396), rotation: 90)
        #expect(shown.width == 396 && shown.height == 612)
    }

    @Test func A_closed_document_says_so() throws {
        let engine = try PdfEngine.open(Self.redCorner())
        engine.close()
        #expect(throws: PdfEngineClosed.self) {
            try Snapshot.render(engine, page: 0, region: RectD(0, 0, 100, 100), viewScale: 1, rotation: 0)
        }
    }
}
