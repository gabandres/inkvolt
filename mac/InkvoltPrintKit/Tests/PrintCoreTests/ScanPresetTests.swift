import Foundation
import Testing
@testable import PrintCore

/// Scan presets: file-name templates, file sets, the preset list, the plan for a scanner, and the summaries. Ported from
/// ScanPresetTests.cs (SyncFolderTests stay with the Windows app until sync-folder routes come). Paths and subfolders use
/// "/" on the Mac.
struct FileNameTemplateTests {
    private static let ctx = NameContext(now: Date(timeIntervalSince1970: 1_792_832_707), // 2026-10-24 09:05:07 UTC
                                         preset: "Receipt", printer: "Demo printer", number: 7, pages: 3,
                                         timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))

    @Test(arguments: [
        ("{preset} {date}", "Receipt 2026-10-24"),
        ("{date:yyyyMMdd}-{time}", "20261024-0905"),
        ("{time:HH.mm.ss}", "09.05.07"),
        ("Scan {n}", "Scan 7"),
        ("Scan {n:000}", "Scan 007"),
        ("{printer} ({pages} pages)", "Demo printer (3 pages)"),
        ("{PRESET} {Date}", "Receipt 2026-10-24"), // token names aren't case-sensitive
        ("{{literal}} {preset}", "{literal} Receipt"),
        ("plain", "plain"),
    ] as [(String, String)])
    func expands(_ template: String, _ expected: String) {
        #expect(FileNameTemplate.fileName(template, Self.ctx) == expected)
    }

    @Test(arguments: [
        ("{date:yyyy/MM/dd}", "2026-10-24"), // a separator in a date format can't become a folder
        ("a<b>c:d\"e|f?g*h", "a-b-c-d-e-f-g-h"),
        ("  name.  ", "name"), // Windows drops trailing dots and spaces itself: never rely on it
        ("", "Scan"), ("   ", "Scan"), ("...", "Scan"),
        ("CON", "CON_"), ("lpt1", "lpt1_"), ("nul.backup", "nul_.backup"), ("COM¹", "COM¹_"), ("lpt³.txt", "lpt³_.txt"),
        ("conin$", "conin$_"), ("CONOUT$.log", "CONOUT$_.log"),
        ("COM10", "COM10"), // not a device
        ("tab\there", "tab-here"),
    ] as [(String, String)])
    func sanitizes(_ template: String, _ expected: String) {
        #expect(FileNameTemplate.fileName(template, Self.ctx) == expected)
    }

    @Test func valuesWithSlashesStayInOneName() {
        var ctx = Self.ctx
        ctx.printer = "HP\\LaserJet/M234"
        #expect(FileNameTemplate.fileName("{printer}", ctx) == "HP-LaserJet-M234")
    }

    @Test func longNamesAreCut() {
        #expect(FileNameTemplate.fileName(String(repeating: "x", count: 400), Self.ctx).count == FileNameTemplate.maxNameLength)
    }

    @Test(arguments: [
        ("{preset} {date}", nil),
        ("{n:000} {date:yyyy-MM}", nil),
        ("{pagez}", "Unknown token {pagez}. Use {date}, {time}, {preset}, {printer}, {n} or {pages}."),
        ("{date", "A { has no closing }. Type {{ for a brace."),
        ("a } b", "A } has no opening {. Type }} for a brace."),
        ("{preset:x}", "{preset} takes no format."),
        ("{}", "Unknown token {}. Use {date}, {time}, {preset}, {printer}, {n} or {pages}."),
    ] as [(String, String?)])
    func validates(_ template: String, _ problem: String?) {
        #expect(FileNameTemplate.problem(template) == problem)
    }

    @Test func unknownTokensStayAsTyped() {
        #expect(FileNameTemplate.fileName("{pagez} {preset}", Self.ctx) == "{pagez} Receipt")
    }

    @Test(arguments: [
        ("", ""), ("Scans", "Scans"), ("Receipts\\{date:yyyy}", "Receipts/2026"), ("Receipts/{date:yyyy}/{date:MM}", "Receipts/2026/10"),
        ("..\\..\\Windows", "Windows"), // never climbs out of the chosen folder
        ("C:\\Temp", "C-/Temp"), ("\\\\server\\share", "server/share"), ("a\\\\\\b\\", "a/b"),
        ("{date:yyyy/MM}", "2026-10"), // separators inside a token stay in its one folder name
        ("{printer}", "Demo printer"),
    ] as [(String, String)])
    func subfolders(_ template: String, _ expected: String) {
        #expect(FileNameTemplate.subfolder(template, Self.ctx) == expected)
    }

    @Test func neverOverwrites() throws {
        let existing: Set<String> = ["/s/scan.pdf", "/s/scan-2.pdf"]
        let exists = { (p: String) in existing.contains(p.lowercased()) } // the Mac's disks ignore case, as Windows'
        #expect(try FileNameTemplate.uniquePath("/s", "Scan", ".pdf", exists: exists) == "/s/Scan-3.pdf")
        #expect(try FileNameTemplate.uniquePath("/s", "Other", ".pdf", exists: exists) == "/s/Other.pdf")
        #expect(try FileNameTemplate.uniquePath("/s", "scan", ".pdf", exists: exists) == "/s/scan-3.pdf")
    }

    @Test func imageSetsAreNumberedAndNeverOverwrite() throws {
        #expect(try FileNameTemplate.uniquePaths("/s", "Photo", ".jpg", count: 1) { _ in false } == ["/s/Photo.jpg"])
        #expect(try FileNameTemplate.uniquePaths("/s", "Photo", ".jpg", count: 2) { _ in false } == ["/s/Photo (1).jpg", "/s/Photo (2).jpg"])
        // One of the set exists: the whole set moves to the next free name, so pages stay together.
        #expect(try FileNameTemplate.uniquePaths("/s", "Photo", ".jpg", count: 2) { $0.lowercased() == "/s/photo (2).jpg" }
            == ["/s/Photo-2 (1).jpg", "/s/Photo-2 (2).jpg"])
    }
}

struct FileSetTests {
    /// A folder where `late` files appear only when something tries to move onto them.
    private final class FakeFolder {
        var files = Set<String>()
        private var late: Set<String>

        init(_ late: String...) { self.late = Set(late.map { $0.lowercased() }) }

        func exists(_ p: String) -> Bool { files.contains(p.lowercased()) }

        func tryMove(_ from: String, _ to: String) -> Bool {
            if late.remove(to.lowercased()) != nil { files.insert(to.lowercased()) } // another program saved there just now
            if files.contains(to.lowercased()) || files.remove(from.lowercased()) == nil { return false }
            files.insert(to.lowercased())
            return true
        }
    }

    @Test func aNameTakenMidwayMovesTheWholeSetOn() throws {
        let fs = FakeFolder("/s/Photo (2).jpg")
        fs.files.formUnion(["/s/t1", "/s/t2", "/s/t3"])
        let placed = try FileNameTemplate.placeSet(["/s/t1", "/s/t2", "/s/t3"], "/s", "Photo", ".jpg", exists: fs.exists, tryMove: fs.tryMove)
        #expect(placed == ["/s/Photo-2 (1).jpg", "/s/Photo-2 (2).jpg", "/s/Photo-2 (3).jpg"])
        // Nothing of ours left under the first name or as a temporary file; the other program's file untouched.
        #expect(fs.files == Set((["/s/Photo (2).jpg"] + placed).map { $0.lowercased() }))
    }

    @Test func aSingleFileTakesTheNextName() throws {
        let fs = FakeFolder("/s/Scan.pdf")
        fs.files.insert("/s/tmp")
        #expect(try FileNameTemplate.placeSet(["/s/tmp"], "/s", "Scan", ".pdf", exists: fs.exists, tryMove: fs.tryMove) == ["/s/Scan-2.pdf"])
    }
}

struct ScanPresetListTests {
    @Test func startsWithTheBuiltIns() {
        let list = ScanPresets.normalize(nil)
        #expect(list.map(\.name) == ["Document to PDF", "Photo", "Receipt"])
        #expect(list.allSatisfy { FileNameTemplate.problem($0.fileName) == nil })
        #expect(list.allSatisfy { FileNameTemplate.problem($0.subfolder) == nil })
        #expect(Set(list.map(\.id)).count == list.count)
        let photo = list[1]
        #expect(photo.fileType == .jpeg)
        #expect(photo.color)
        #expect(!photo.skipBlank)
    }

    @Test func emptySavedListStaysEmpty() {
        // The user deleted every preset: don't bring the starters back behind their back.
        #expect(ScanPresets.normalize(ScanPresetSettings(version: ScanPresets.currentVersion, items: [])).isEmpty)
    }

    @Test func repairsHandEditedOrNewerFiles() {
        var a = ScanPreset()
        a.id = "a"
        a.name = "  "
        a.resolution = 5000
        a.nextNumber = -4
        a.fileName = ""
        a.subfolder = ""
        a.pageSize = "tabloid"
        var second = ScanPreset()
        second.id = "a"
        second.name = "Second"
        second.source = PresetSource(rawValue: 42)
        second.fileType = PresetFileType(rawValue: 9)
        second.after = PresetAfter(rawValue: 7)
        second.folder = PresetFolder(rawValue: 8)
        var third = ScanPreset()
        third.id = ""
        third.name = "Second"
        var custom = ScanPreset()
        custom.id = "c"
        custom.name = "Custom"
        custom.folder = .custom
        let list = ScanPresets.normalize(ScanPresetSettings(version: 99, items: [nil, a, second, third, custom]))
        #expect(list.count == 4)
        #expect(Set(list.map(\.id)).count == list.count)
        #expect(list[0].name == "Scan preset")
        #expect(list[0].resolution == 1200)
        #expect(list[0].nextNumber == 1)
        #expect(list[0].fileName == ScanPresets.defaultFileName)
        #expect(list[0].subfolder == "")
        #expect(list[0].pageSize == nil)
        #expect(list[1].source == .auto)
        #expect(list[1].fileType == .pdf)
        #expect(list[1].after == .none)
        #expect(list[1].folder == .documents)
        #expect(list[2].name == "Second (2)")
        #expect(list[3].folder == .documents) // a custom folder with no path
    }

    @Test(arguments: [("receipt", true), ("a1b2-C3", true), ("x --autoprint out.txt", false), ("a\"b", false), ("tab\there", false), ("", false)]
          as [(String, Bool)])
    func idsAreSafeOnACommandLine(_ id: String, _ valid: Bool) {
        #expect(ScanPresets.isValidId(id) == valid)
        var p = ScanPreset()
        p.id = id
        p.name = "P"
        let list = ScanPresets.normalize(ScanPresetSettings(items: [p]))
        #expect(ScanPresets.isValidId(list[0].id))
        #expect((list[0].id == id) == valid)
    }

    @Test func newIdsAreValid() {
        let list = ScanPresets.builtIns()
        #expect(list.allSatisfy { ScanPresets.isValidId($0.id) })
        #expect(ScanPresets.isValidId(ScanPresets.create(list).id))
        #expect(ScanPresets.isValidId(ScanPresets.duplicate(list, list[0]).id))
    }

    @Test func reservesEachNumberOnce() {
        var list = ScanPresets.builtIns()
        #expect(ScanPresets.reserve(&list, "receipt") == 1)
        #expect(ScanPresets.reserve(&list, "receipt") == 2)
        #expect(list[2].nextNumber == 3)
        #expect(list[0].nextNumber == 1)
        #expect(ScanPresets.reserve(&list, "gone") == nil)
    }

    @Test func editorSaveKeepsCountersThatMovedMeanwhile() {
        let current = ScanPresets.builtIns().map { p -> ScanPreset in
            var p = p
            if p.id == "receipt" { p.nextNumber = 9 }
            return p
        }
        var edited = ScanPresets.builtIns().map { p -> ScanPreset in
            var p = p
            p.name += "!"
            return p
        } // opened when receipt was at 1
        var added = ScanPresets.create(edited)
        added.nextNumber = 1
        edited.append(added)
        let saved = ScanPresets.keepCounters(edited, current)
        #expect(saved[2].nextNumber == 9)
        #expect(saved[2].name == "Receipt!")
        #expect(saved[3].nextNumber == 1)
    }

    @Test func newerFilesKeepWhatThisVersionDoesntKnow() throws {
        let json = #"{"Version":2,"Items":[{"Id":"receipt","Name":"Receipt","Cloud":{"x":1}}],"Sort":"name"}"#
        let stored = try JSONDecoder().decode(ScanPresetSettings.self, from: Data(json.utf8))
        #expect(stored.isNewer)
        let back = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        #expect(back.contains(#""Cloud":{"x":1}"#))
        #expect(back.contains(#""Sort":"name""#))
        #expect(back.contains(#""Version":2"#))
        // Repaired copies keep them too.
        #expect(ScanPresets.normalize(stored)[0].unknown != nil)
    }

    @Test func roundTripsThroughJson() throws {
        let settings = ScanPresetSettings(items: ScanPresets.builtIns())
        let back = try JSONDecoder().decode(ScanPresetSettings.self, from: try JSONEncoder().encode(settings))
        #expect(back.version == ScanPresets.currentVersion)
        #expect(back.items == settings.items)
    }

    @Test func olderFilesWithoutPresetsGetTheBuiltIns() throws {
        let back = try JSONDecoder().decode(ScanPresetSettings.self, from: Data(#"{"Version":0}"#.utf8))
        #expect(ScanPresets.normalize(back).count == 3)
    }

    @Test func createsWithUniqueNames() {
        var list = ScanPresets.builtIns()
        let a = ScanPresets.create(list)
        list.append(a)
        let b = ScanPresets.create(list)
        #expect(a.name == "New preset")
        #expect(b.name == "New preset (2)")
        #expect(a.id != b.id)
    }

    @Test func duplicatesUnderANewNameAndId() {
        var list = ScanPresets.builtIns()
        list[2].nextNumber = 40
        let copy = ScanPresets.duplicate(list, list[2])
        #expect(copy.name == "Receipt copy")
        #expect(list[2].id != copy.id)
        #expect(copy.nextNumber == 1) // its own counter
        var expected = list[2]
        expected.id = copy.id
        expected.name = copy.name
        expected.nextNumber = 1
        #expect(copy == expected)
        list.append(copy)
        #expect(ScanPresets.duplicate(list, list[2]).name == "Receipt copy (2)")
    }

    @Test(arguments: [("Invoices", nil), ("  ", "Give the preset a name."), ("photo", "Another preset is already called \"Photo\"."),
                      (" Photo ", "Another preset is already called \"Photo\".")] as [(String, String?)])
    func checksNames(_ name: String, _ problem: String?) {
        let list = ScanPresets.builtIns()
        #expect(ScanPresets.nameProblem(list, list[0].id, name) == problem)
    }

    @Test func renamingToItsOwnNameIsFine() {
        let list = ScanPresets.builtIns()
        #expect(ScanPresets.nameProblem(list, list[1].id, "PHOTO") == nil)
        #expect(ScanPresets.nameProblem(list, list[1].id, String(repeating: "a", count: 61)) == "Names can be up to 60 characters.")
    }

    @Test func moves() {
        var list = ScanPresets.builtIns()
        #expect(ScanPresets.move(&list, from: 2, to: 0))
        #expect(list.map(\.name) == ["Receipt", "Document to PDF", "Photo"])
        #expect(!ScanPresets.move(&list, from: 0, to: -1))
        #expect(!ScanPresets.move(&list, from: 2, to: 3))
        #expect(!ScanPresets.move(&list, from: 1, to: 1))
    }
}

struct PresetPlanTests {
    private static func input(_ dpi: [Int], maxHeight: Int = 3508) -> InputCaps {
        InputCaps(minWidth: 0, maxWidth: 2550, minHeight: 0, maxHeight: maxHeight, colorModes: ["RGB24", "Grayscale8"], documentFormats: ["image/jpeg"],
                  resolutions: dpi, intents: ["Document", "Photo"])
    }

    private static func caps(glass: Bool = true, feeder: Bool = true, duplex: Bool = true, dpi: [Int]? = nil) -> ScannerCapabilities {
        ScannerCapabilities(version: "2.6", makeAndModel: "Test", uuid: nil, platen: glass ? input(dpi ?? [75, 150, 300, 600]) : nil,
                            adf: feeder ? input(dpi ?? [75, 150, 300], maxHeight: 4200) : nil, adfDuplex: duplex)
    }

    private static let doc = ScanPresets.builtIns()[0]

    private static func doc(_ change: (inout ScanPreset) -> Void) -> ScanPreset {
        var p = doc
        change(&p)
        return p
    }

    @Test func autoUsesTheFeederWhenItHasPages() {
        #expect(PresetPlan.plan(Self.doc, Self.caps(), feederLoaded: true, ocrAvailable: true, metric: false).request.source == .adf)
        #expect(PresetPlan.plan(Self.doc, Self.caps(), feederLoaded: false, ocrAvailable: true, metric: false).request.source == .platen)
        #expect(PresetPlan.plan(Self.doc, Self.caps(), feederLoaded: nil, ocrAvailable: true, metric: false).request.source == .platen)
        #expect(PresetPlan.plan(Self.doc, Self.caps(glass: false), feederLoaded: nil, ocrAvailable: true, metric: false).request.source == .adf)
    }

    @Test func twoSidedWhenTheFeederCan() {
        let p = Self.doc {
            $0.twoSided = true
            $0.source = .feeder
        }
        #expect(PresetPlan.plan(p, Self.caps(), feederLoaded: nil, ocrAvailable: true, metric: false).request.source == .adfDuplex)
        let simplex = PresetPlan.plan(p, Self.caps(duplex: false), feederLoaded: nil, ocrAvailable: true, metric: false)
        #expect(simplex.request.source == .adf)
        #expect(simplex.notes.contains("This scanner's feeder scans one side only."))
    }

    @Test func fallsBackWhenTheSourceIsMissing() {
        let glassOnly = PresetPlan.plan(Self.doc { $0.source = .feeder }, Self.caps(feeder: false), feederLoaded: nil, ocrAvailable: true, metric: false)
        #expect(glassOnly.request.source == .platen)
        #expect(glassOnly.notes.contains("This scanner has no document feeder: scanning from the glass."))
        let feederOnly = PresetPlan.plan(Self.doc { $0.source = .glass }, Self.caps(glass: false), feederLoaded: nil, ocrAvailable: true, metric: false)
        #expect(feederOnly.request.source == .adf)
        #expect(feederOnly.notes.contains("This scanner has no glass: scanning from the document feeder."))
    }

    @Test func picksTheClosestResolutionAndSize() {
        let plan = PresetPlan.plan(Self.doc {
            $0.resolution = 200
            $0.source = .glass
            $0.pageSize = nil
        }, Self.caps(dpi: [100, 300]), feederLoaded: nil, ocrAvailable: true, metric: true)
        #expect(plan.request.resolution == 300)
        #expect(plan.request.width == 2480) // A4 by region
        let legal = PresetPlan.plan(Self.doc {
            $0.source = .glass
            $0.pageSize = "legal"
        }, Self.caps(), feederLoaded: nil, ocrAvailable: true, metric: false)
        #expect(legal.request.width == 2550) // glass is A4-long only: falls back to Letter
        #expect(legal.notes.contains("Legal (8.5 × 14 in) doesn't fit this source: scanning Letter (8.5 × 11 in)."))
        let whole = PresetPlan.plan(Self.doc { $0.pageSize = "full" }, Self.caps(), feederLoaded: nil, ocrAvailable: true, metric: false)
        #expect(whole.request.width == nil)
    }

    @Test func greyWhenColorIsOff() {
        #expect(PresetPlan.plan(Self.doc { $0.color = false }, Self.caps(), feederLoaded: nil, ocrAvailable: true, metric: false).request.color == .grayscale)
        #expect(PresetPlan.plan(Self.doc { $0.color = true }, Self.caps(), feederLoaded: nil, ocrAvailable: true, metric: false).request.color == .color)
    }

    @Test func searchableOnlyWithOcr() {
        let p = Self.doc { $0.fileType = .searchablePdf }
        #expect(PresetPlan.plan(p, Self.caps(), feederLoaded: nil, ocrAvailable: true, metric: false).ocr)
        let none = PresetPlan.plan(p, Self.caps(), feederLoaded: nil, ocrAvailable: false, metric: false)
        #expect(!none.ocr)
        #expect(none.notes.contains("Text recognition isn't available on this Mac: the PDF won't be searchable."))
        #expect(!PresetPlan.plan(Self.doc { $0.fileType = .pdf }, Self.caps(), feederLoaded: nil, ocrAvailable: true, metric: false).ocr)
        #expect(!PresetPlan.plan(Self.doc { $0.fileType = .jpeg }, Self.caps(), feederLoaded: nil, ocrAvailable: true, metric: false).ocr)
    }
}

struct ScanPresetTextTests {
    @Test func summaries() {
        let list = ScanPresets.builtIns()
        #expect(ScanPresetText.summary(list[0]) == "Searchable PDF · feeder or glass · grey, 300 dpi · Documents/Scans")
        #expect(ScanPresetText.summary(list[1]) == "JPEG images · glass · color, 600 dpi · Pictures/Scans · review first")
        var mail = list[2]
        mail.folder = .custom
        mail.folderPath = "/Users/ana/OneDrive/"
        mail.subfolder = ""
        mail.after = .email
        #expect(ScanPresetText.summary(mail) == "Searchable PDF · glass · grey, 300 dpi · OneDrive · then email it")
    }
}
