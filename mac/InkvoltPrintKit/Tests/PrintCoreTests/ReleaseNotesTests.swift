import Foundation
import Testing
@testable import PrintCore

/// What's New's notes. Ported from HelpTests.cs, its ReleaseNotes tests (the Diagnostics ones port with Report a Problem).
/// Adapted: .NET's `Version` is `NoteVersion`, and `Since` takes it as `current`.
struct ReleaseNotesTests {
    private static let notes = """
        # What's new in Inkvolt Print

        ## Next
        - Not released yet, never shown.

        ## 1.1.0
        - Settings in one place.
        - Report a problem copies the details
          a report needs.

        ## 1.0.3
        - Printers set up in Windows show up too.

        ## 1.0.2
        - Older printers over SNMP.
        """

    @Test func Parse_reads_versions_newest_first_with_their_items_and_skips_unreleased() {
        let notes = ReleaseNotes.parse(Self.notes)

        #expect(notes.map(\.version.description) == ["1.1.0", "1.0.3", "1.0.2"])
        #expect(notes[0].items == ["Settings in one place.", "Report a problem copies the details a report needs."])
    }

    @Test(arguments: [
        ("1.0.2", "1.1.0", false, "1.1.0,1.0.3"), // updated over two versions: both
        ("1.0.3", "1.1.0", false, "1.1.0"),
        ("1.1.0", "1.1.0", false, ""), // already seen
        ("1.2.0", "1.1.0", false, ""), // went back a version
        (nil, "1.1.0", true, ""), // a new install: nothing new to it
        (nil, "1.1.0", false, "1.1.0"), // updated from a version that didn't keep track: this one's notes
        ("garbage", "1.1.0", false, "1.1.0"),
        ("1.0.3.0", "1.1.0.0", false, "1.1.0"), // package versions have a fourth number
        ("1.0.3", "1.0.4", false, ""), // no notes written for it
    ] as [(String?, String, Bool, String)])
    func Since_shows_each_update_once(_ lastSeen: String?, _ current: String, _ newInstall: Bool, _ expected: String) throws {
        let now = try #require(ReleaseNotes.normalize(current))
        let shown = ReleaseNotes.since(ReleaseNotes.parse(Self.notes), lastSeen: lastSeen, current: now, newInstall: newInstall)

        #expect(shown.map(\.version.description).joined(separator: ",") == expected)
    }

    @Test func Format_lists_each_version_with_its_items() {
        let text = ReleaseNotes.format(Array(ReleaseNotes.parse(Self.notes).prefix(2)))

        #expect(text == "Version 1.1.0\n• Settings in one place.\n• Report a problem copies the details a report needs.\n\nVersion 1.0.3\n• Printers set up in Windows show up too.")
    }
}
