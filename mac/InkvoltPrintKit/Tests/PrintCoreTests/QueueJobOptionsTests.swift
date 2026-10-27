import Foundation
import Testing
@testable import PrintCore

/// Print Photos' paper type, quality and color from a CUPS queue's IPP keywords, and the options a photo job is sent with.
/// New for the Mac: the Windows app reads Print Schema names from the driver (its PhotoPrinting, untested); the words are
/// PhotoPaperText's, tested in PhotoLayoutTests.
struct QueueJobOptionsTests {
    private static let inkjet = QueueJobOptions(
        mediaTypes: ["stationery", "photographic-glossy", "photographic-semi-gloss", "photographic-matte", "photographic-high-gloss",
                     "cardstock", "auto", "stationery", "", "com.acme.photographic-glossy"],
        defaultMediaType: "stationery", qualities: [5, 4, 3, 4], defaultQuality: 4,
        colorModes: ["auto", "color", "monochrome", "process-monochrome"], defaultColorMode: "color")

    @Test(arguments: [
        ("stationery", "Plain"), ("auto", "AutoSelect"), ("photographic", "Photographic"),
        ("photographic-glossy", "PhotographicGlossy"), ("photographic-semi-gloss", "PhotographicSemiGloss"),
        ("photographic-high-gloss", "PhotographicHighGloss"), ("stationery-letterhead", "StationeryLetterhead"),
        ("com.hp.stationery-lightweight", "StationeryLightweight"), ("com.hp-stationery-heavyweight", "StationeryHeavyweight"),
        ("com.epson.photographic-glossy", "PhotographicGlossy"),
    ])
    func ippMediaTypesBecomeTheWindowsNames(keyword: String, name: String) {
        #expect(QueueJobChoices.schemaMediaType(keyword) == name)
    }

    @Test func paperTypesAreWordedInTheQueuesOrderEachOnce() {
        let types = QueueJobChoices.mediaTypes(Self.inkjet)
        #expect(types.map(\.value) == ["stationery", "photographic-glossy", "photographic-semi-gloss", "photographic-matte",
                                       "photographic-high-gloss", "cardstock", "auto"])
        #expect(types.map(\.label) == ["Plain paper", "Photo paper, glossy", "Photo paper, semi-gloss", "Photo paper, matte",
                                       "Photo paper, high gloss", "Cardstock", "Let the printer choose"])
    }

    @Test func qualitiesGoFromDraftToHighOnce() {
        let q = QueueJobChoices.qualities(Self.inkjet)
        #expect(q == [JobChoice("3", "Draft"), JobChoice("4", "Normal"), JobChoice("5", "High")])
        #expect(QueueJobChoices.qualities(QueueJobOptions(qualities: [4, 7])) == [JobChoice("4", "Normal")])
    }

    @Test func colorsKeepTheKnownModes() {
        let c = QueueJobChoices.colors(Self.inkjet)
        #expect(c == [JobChoice("auto", "Automatic"), JobChoice("color", "Color"), JobChoice("monochrome", "Shades of grey")])
        let laser = QueueJobOptions(colorModes: ["monochrome", "bi-level"])
        #expect(QueueJobChoices.colors(laser).map(\.label) == ["Shades of grey", "Black and white"])
    }

    @Test func aQueueThatSaysNothingOffersNothing() {
        #expect(QueueJobChoices.mediaTypes(.none).isEmpty)
        #expect(QueueJobChoices.qualities(.none).isEmpty)
        #expect(QueueJobChoices.colors(.none).isEmpty)
        #expect(QueueJobChoices.initial([], kept: "4", queueDefault: "4") == nil)
    }

    @Test func theChoiceKeptWinsThenTheQueuesDefaultThenTheFirst() {
        let q = QueueJobChoices.qualities(Self.inkjet)
        #expect(QueueJobChoices.initial(q, kept: "5", queueDefault: "4") == "5")
        #expect(QueueJobChoices.initial(q, kept: "6", queueDefault: "4") == "4")
        #expect(QueueJobChoices.initial(q, kept: nil, queueDefault: "9") == "3")
    }

    private static let letter = PhotoPaperChoice(
        label: "Letter", sheet: SheetPaper(8.5, 11, 0.25, 0.2, 0.25, 0.3), media: "na_letter_8.5x11in",
        borderless: QueueMedia(name: "na_letter_8.5x11in.borderless", width: 8.5, height: 11, left: 0, top: 0, right: 0, bottom: 0))

    @Test func theJobAsksForTheBorderlessPaperWhenPicked() {
        #expect(QueueJobChoices.media(Self.letter, borderless: true) == Self.letter.borderless)
    }

    @Test func otherwiseItAsksForTheBorderedPaperWithItsMargins() {
        #expect(QueueJobChoices.media(Self.letter, borderless: false)
            == QueueMedia(name: "na_letter_8.5x11in", width: 8.5, height: 11, left: 0.25, top: 0.2, right: 0.25, bottom: 0.3))
        let a4 = PhotoPaperChoice(label: "A4", sheet: SheetPaper(8.27, 11.69, 0.25, 0.25, 0.25, 0.25), media: "iso_a4_210x297mm")
        #expect(QueueJobChoices.media(a4, borderless: true).name == "iso_a4_210x297mm") // it has no borderless size
    }

    @Test func theJobSendsWhatWasPickedAndLeavesTheRestToTheQueue() {
        let options = QueueJobChoices.jobOptions(mediaType: "photographic-glossy", quality: "5", color: "color")
        #expect(options.map(\.name) == ["media-type", "print-quality", "print-color-mode"])
        #expect(options.map(\.value) == ["photographic-glossy", "5", "color"])
        let some = QueueJobChoices.jobOptions(mediaType: nil, quality: "4", color: nil)
        #expect(some.map(\.name) == ["print-quality"])
        #expect(QueueJobChoices.jobOptions(mediaType: nil, quality: nil, color: nil).isEmpty)
    }
}
