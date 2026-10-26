import Foundation
import Testing
@testable import PrintCore

/// Pages on paper: scale and the quarter turn. Ported from PageFitTests.cs; all 4 tests, none left out.
struct PageFitTests {
    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 5e-7 }

    @Test(arguments: [
        (4, 6, PageSizing.actualSize, 1), // 4×6 label on Letter: stays 4×6
        (4, 6, .fitToPaper, 11.0 / 6), // ...or fills the height
        (8.5, 11, .fitToPaper, 1),
        (8.5, 11, .actualSize, 1),
        (8.27, 11.69, .actualSize, 11 / 11.69), // A4 on Letter shrinks either way
        (8.27, 11.69, .fitToPaper, 11 / 11.69),
        (8.4, 10.9, .fitToPaper, 1), // within 3% of the paper: actual size
        (17, 22, .actualSize, 0.5),
    ] as [(Double, Double, PageSizing, Double)])
    func scalesOnLetter(_ w: Double, _ h: Double, _ sizing: PageSizing, _ expected: Double) {
        #expect(Self.near(PageFit.scale(w, h, 8.5, 11, sizing), expected))
    }

    @Test func emptyPageKeepsScale() {
        #expect(PageFit.scale(0, 0, 8.5, 11, .fitToPaper) == 1)
    }

    @Test(arguments: [
        (11, 8.5, 8.5, 11, true), // landscape page, portrait paper
        (8.5, 11, 11, 8.5, true), // portrait page, landscape paper
        (8.5, 11, 8.5, 11, false),
        (4, 4, 8.5, 11, false), // square: as is on portrait paper
    ] as [(Double, Double, Double, Double, Bool)])
    func placeTurnsThePageToThePapersOrientation(_ w: Double, _ h: Double, _ paperW: Double, _ paperH: Double, _ rotated: Bool) {
        let p = PageFit.place(w, h, paperW, paperH, .actualSize)

        #expect(p.rotated == rotated)
        #expect(Self.near(2 * p.at.x + p.at.width, paperW)) // centred
        #expect(Self.near(2 * p.at.y + p.at.height, paperH))
    }

    @Test func placeFitsATurnedPageByItsTurnedSize() {
        // 17 × 11 tabloid on Letter: turned to 11 × 17, then its 17 in height fits the paper's 11.
        let p = PageFit.place(17, 11, 8.5, 11, .fitToPaper)

        #expect(p.rotated)
        #expect(Self.near(p.at.width, 11 * 11 / 17.0))
        #expect(Self.near(p.at.height, 11))
    }
}
