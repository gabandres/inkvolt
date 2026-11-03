import Foundation
import Testing
@testable import PdfCore

/// `NightColors`: dark pages' pixel map. The Windows `PageViewer.NightColors` is private to the viewer and has no tests,
/// so these are a Mac addition checking its rule: lightness flipped, hue kept, the range softened to 26...226.
struct NightColorsTests {
    private static func mapped(_ r: UInt8, _ g: UInt8, _ b: UInt8) throws -> [UInt8] {
        var px = [r, g, b]
        try NightColors.apply(&px)
        return px
    }

    @Test func WhitePaperBecomesDarkGreyAndBlackTextLightGrey() throws {
        #expect(try Self.mapped(255, 255, 255) == [26, 26, 26])
        #expect(try Self.mapped(0, 0, 0) == [226, 226, 226])
        #expect(NightColors.paper == 26)
    }

    @Test func HueIsKept() throws {
        // Pure red stays red, pure blue stays blue: only the lightness flips.
        #expect(try Self.mapped(255, 0, 0) == [226, 26, 26])
        #expect(try Self.mapped(0, 0, 255) == [26, 26, 226])
        let dark = try Self.mapped(128, 0, 0) // dark red becomes a lighter red
        #expect(dark[0] > dark[1] && dark[1] == dark[2] && dark[0] > 125)
    }

    @Test func MidGreyStaysNearTheMiddle() throws {
        let grey = try Self.mapped(128, 128, 128)
        #expect(grey == [125, 125, 125])
    }

    @Test func EveryPixelOfALargePictureIsMapped() throws {
        var px = [UInt8](repeating: 255, count: 3 * 200_000)
        try NightColors.apply(&px)
        #expect(px.allSatisfy { $0 == 26 })
    }

    @Test func StopsWhenCancelled() throws {
        var px = [UInt8](repeating: 255, count: 3 * 70_000)
        let token = CancelToken()
        token.cancel()
        #expect(throws: CancellationError.self) { try NightColors.apply(&px, cancel: token) }
    }
}
