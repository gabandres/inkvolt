import Foundation
import Testing
@testable import PrintCore

/// Numbers from outside (a printer's or scanner's reply, a recovered scan's file) that are NaN, infinite or too big for an
/// Int, where the Mac turned them into an Int: Swift's `Int(x)` traps on those, .NET's cast doesn't, so these have no
/// Windows twin. Each must neither stop the app nor change what an ordinary number does (`mac/tools/check-int.sh` keeps new
/// conversions of a rounded value to the checked form).
struct HostileNumberTests {
    private static let lost = PhotoBox(centerX: .nan, centerY: .infinity, width: 1e300, height: -.infinity, angle: 0)

    @Test func aPhotoBoxThatIsntANumberIsCutWithinTheScan() {
        let r = GlassPhotoCrop.bounds(Self.lost, width: 100, height: 80)
        #expect(r.x >= 0 && r.width >= 1 && r.x + r.width <= 100)
        #expect(r.y >= 0 && r.height >= 1 && r.y + r.height <= 80)
        let ordinary = GlassPhotoCrop.bounds(PhotoBox(centerX: 0.5, centerY: 0.4, width: 0.2, height: 0.1, angle: 0), width: 100, height: 80)
        #expect(ordinary.x == 38 && ordinary.width == 24) // 40...60, 2 pixels around
    }

    @Test func aPhotoBoxThatIsntANumberIsStraightenedToSomePixels() {
        let region = [UInt8](repeating: 200, count: 10 * 10)
        for box in [Self.lost, PhotoBox(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5, angle: .nan)] {
            let cut = GlassPhotoCrop.straighten(region, regionWidth: 10, regionHeight: 10, stride: 10, channels: 1, box: box, scanWidth: 10,
                                                regionX: 0, regionY: 0)
            #expect(cut.width >= 1 && cut.width <= 10 && cut.height >= 1 && cut.height <= 10)
        }
    }

    @Test func photoFinderLooksForNothingAtAResolutionThatIsntANumber() {
        let img = GrayImage(width: 64, height: 64, pixels: [UInt8](repeating: 250, count: 64 * 64))
        for ppi in [Double.nan, .infinity, 1e300] { #expect(PhotoFinder.find(img, pixelsPerInch: ppi).isEmpty, "\(ppi)") }
    }

    @Test func aPageTurnedByAnAngleThatIsntANumberComesBackBlank() {
        let page = [UInt8](repeating: 0, count: 8 * 6)
        let turned = PageRotate.rotate(page, width: 8, height: 6, stride: 8, channels: 1, degrees: .nan)
        #expect(turned == [UInt8](repeating: 255, count: 8 * 6))
    }

    @Test func cdmSupplyLevelsThatArentNumbersAreLeftOut() {
        let json = #"{"suppliesList":["#
            + #"{"supplyType":"toner","supplyColorCode":"K","percentLifeDisplay":"1e300"},"#
            + #"{"supplyType":"toner","supplyColorCode":"C","percentLifeDisplay":"NaN"},"#
            + #"{"supplyType":"toner","supplyColorCode":"M","percentLifeDisplay":"-inf"},"#
            + #"{"supplyType":"toner","supplyColorCode":"Y","percentLifeDisplay":1e300,"approximatePagesRemainingDisplay":"57.5"}]}"#
        let s = CdmParsers.parseSupplies(json)
        #expect(s.count == 4)
        #expect(s.allSatisfy { $0.percentRemaining == nil })
    }
}
