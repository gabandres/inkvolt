import Foundation
import Testing
@testable import PrintCore

/// A saved batch (roadmap 2.4, Pro): its paths checked by words alone, its JSON read as a person or a script writes it, a folder
/// line becoming its files. Ported from BatchPrintTests.cs's BatchPrintListTests with the same names. Adapted to the Mac's paths:
/// a device is under /dev or /.vol, another computer's files are reached through the automounter (/net/<host>/…,
/// /Network/Servers/<host>/…) rather than \\server\share, a colon is refused anywhere (a web address or smb://), a
/// backslash is read as a separator so a list written on Windows reads here; a Windows tool's byte order marks still read.
/// A_recursive_folder_doesnt_follow_a_junction_out_of_it_or_round_in_a_loop makes symbolic links, the Mac's junctions.
struct BatchPrintListTests {
    static let folder = "/Lists"

    static func check(_ raw: String?) -> BatchListPath { BatchPrintList.checkPath(raw, folder) }

    @Test(arguments: ["/dev/disk0", "/dev/null", "/DEV/rdisk1", "/.vol/16777220/2", "/tmp/../dev/null", "http://example.com/a.pdf",
                      "file:///a.pdf", "smb://server/share/a.pdf", "a.pdf:hidden", "~/a.pdf", "../secret.pdf", "sub/../../secret.pdf",
                      "../Lists2/a.pdf", "sub\\..\\..\\secret.pdf", "a?.pdf", "a*.pdf", "a\u{7}.pdf", "a<b.pdf", "", "   ", "/net/", nil] as [String?])
    func A_path_a_list_may_not_use_is_refused_without_touching_anything(_ raw: String?) {
        let checked = Self.check(raw)
        #expect(checked.full == nil)
        #expect(checked.why != nil)
    }

    @Test(arguments: [("a.pdf", "/Lists/a.pdf"), ("sub/b.jpg", "/Lists/sub/b.jpg"), ("sub\\b.jpg", "/Lists/sub/b.jpg"),
                      ("sub/../c.pdf", "/Lists/c.pdf"), ("./d.pdf", "/Lists/d.pdf"), ("/Users/me/Docs/a.pdf", "/Users/me/Docs/a.pdf"),
                      ("/Users/me//Docs/./a.pdf", "/Users/me/Docs/a.pdf"), ("/Volumes/Archive/a.pdf", "/Volumes/Archive/a.pdf")])
    func A_relative_path_is_from_the_lists_folder_and_a_full_one_stays(_ c: (raw: String, full: String)) {
        let checked = Self.check(c.raw)
        #expect(checked.full == c.full)
        #expect(checked.server == nil)
    }

    @Test(arguments: [("/net/server/share/a.pdf", "server"), ("/Network/Servers/files01/Users/a.pdf", "files01")])
    func Another_computers_path_is_named(_ c: (raw: String, name: String)) {
        let checked = Self.check(c.raw)
        #expect(checked.full != nil)
        #expect(checked.server == c.name)
    }

    static func writeList(_ f: BatchFolder, _ json: String, _ name: String = "list.inkvoltlist") -> String { f.file(name, json) }

    @Test func A_list_needs_a_yes_to_reach_another_computer_and_says_which() throws {
        let f = BatchFolder()
        let list = Self.writeList(f, #"{ "version": 1, "files": [ { "path": "/net/files01/share/a.pdf" }, { "path": "b.pdf" } ] }"#)
        do {
            _ = try BatchPrintList.load(list, allowNetwork: false)
            Issue.record("loaded without a yes")
        } catch let e as BatchListError {
            #expect(e.servers == ["files01"])
        }
        #expect(try BatchPrintList.load(list, allowNetwork: true).count == 2)
    }

    @Test func A_saved_list_reads_back_the_same_and_has_no_password() throws {
        let f = BatchFolder()
        let path = (f.root as NSString).appendingPathComponent("saved" + BatchPrintList.fileExtension)
        let entries = [
            BatchListEntry((f.root as NSString).appendingPathComponent("a.pdf"), BatchPrintSettings(copies: 3, range: "1-2", twoSided: true, paper: "iso_a4_210x297mm")),
            BatchListEntry((f.root as NSString).appendingPathComponent("b.png"), BatchPrintSettings()),
        ]
        try BatchPrintList.save(path, entries)
        #expect(try BatchPrintList.load(path, allowNetwork: false) == entries)
        #expect(!FileManager.default.fileExists(atPath: path + ".tmp"))
        #expect(try !String(contentsOfFile: path, encoding: .utf8).lowercased().contains("password"))
    }

    @Test func A_hand_written_list_takes_defaults_comments_and_a_trailing_comma() throws {
        let f = BatchFolder()
        let list = Self.writeList(f, """
            // monthly statements
            { "Version": 1, "defaults": { "copies": 2, "twoSided": true, "paper": "iso_a4_210x297mm" },
              "files": [ { "path": "a.pdf" }, { "path": "b.pdf", "copies": 1, "twoSided": false, "paper": "na_letter_8.5x11in", "range": "2" }, ] }
            """)
        let entries = try BatchPrintList.load(list, allowNetwork: false)
        #expect(entries[0].settings == BatchPrintSettings(copies: 2, range: nil, twoSided: true, paper: "iso_a4_210x297mm"))
        #expect(entries[1].settings == BatchPrintSettings(copies: 1, range: "2", twoSided: false, paper: "na_letter_8.5x11in"))
    }

    @Test(arguments: [
        (#"{ "version": 1, "files": [ { "path": "a.pdf", "copies": 9999 } ] }"#, "copies"),
        (#"{ "version": 1, "files": [ { "path": "a.pdf", "copies": 0 } ] }"#, "copies"),
        (#"{ "version": 1, "defaults": { "copies": 500 }, "files": [ { "path": "a.pdf" } ] }"#, "copies"),
        (#"{ "version": 2, "files": [] }"#, "newer"),
        (#"{ "files": [] }"#, "version"),
        (#"{ "version": 1 }"#, "no files"),
        (#"{ "version": 1, "files": [ { "copies": 2 } ] }"#, "Line 1"),
        (#"{ "version": 1, "files": [ { "path": "../../x.pdf" } ] }"#, "leaves"),
        (#"{ "version": 1, "files": [ { "path": 5 } ] }"#, "damaged"),
        ("not json", "damaged"),
        ("[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]", "damaged"),
        ("null", "empty"),
    ])
    func A_bad_list_is_refused_and_says_why(_ c: (json: String, word: String)) {
        let f = BatchFolder()
        let said = Self.message { _ = try BatchPrintList.load(Self.writeList(f, c.json), allowNetwork: false) }
        #expect(said.contains(c.word), "\(said)")
    }

    static func message(_ body: () throws -> Void) -> String {
        do {
            try body()
            return ""
        } catch {
            return (error as? BatchListError)?.message ?? "\(error)"
        }
    }

    @Test func A_list_too_long_or_too_large_is_refused() {
        let f = BatchFolder()
        let lines = Array(repeating: #"{"path":"a.pdf"}"#, count: BatchPrintLimits.maxFiles + 1).joined(separator: ",")
        #expect(Self.message { _ = try BatchPrintList.load(Self.writeList(f, #"{"version":1,"files":[\#(lines)]}"#), allowNetwork: false) }.contains("at most"))
        let huge = Self.writeList(f, String(repeating: " ", count: (4 << 20) + 1), "huge.inkvoltlist")
        #expect(Self.message { _ = try BatchPrintList.load(huge, allowNetwork: false) }.contains("too large"))
        #expect(Self.message { _ = try BatchPrintList.load((f.root as NSString).appendingPathComponent("none"), allowNetwork: false) }.contains("no list file"))
    }

    @Test func A_folder_line_becomes_its_files_with_the_lines_settings_and_a_missing_file_stays_to_read_as_gone() throws {
        let f = BatchFolder()
        f.file("in/b 10.pdf")
        f.file("in/b 2.pdf")
        let settings = BatchPrintSettings(copies: 2)
        let expanded = try BatchPrintList.expand([BatchListEntry((f.root as NSString).appendingPathComponent("in"), settings),
                                                  BatchListEntry((f.root as NSString).appendingPathComponent("gone.pdf"), settings)])
        #expect(expanded.map { ($0.path as NSString).lastPathComponent } == ["b 2.pdf", "b 10.pdf", "gone.pdf"])
        #expect(expanded.allSatisfy { $0.settings == settings })
    }

    @Test func A_line_naming_something_else_refuses_the_list() {
        let f = BatchFolder()
        #expect(Self.message { _ = try BatchPrintList.expand([BatchListEntry(f.file("secrets.txt"), BatchPrintSettings())]) }.contains("neither"))
    }

    @Test func A_link_in_a_list_or_a_folder_isnt_followed() throws {
        let f = BatchFolder()
        let target = f.file("real.pdf")
        let folder = (f.root as NSString).appendingPathComponent("in")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let link = (folder as NSString).appendingPathComponent("link.pdf")
        do {
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        } catch {
            return // this Windows PC doesn't let this user make links
        }
        #expect(BatchPrintFiles.listFolder(folder, recursive: false).isEmpty)
        var said = ""
        do {
            _ = try BatchHeldFile.open(link)
        } catch {
            said = (error as? BatchFileError)?.message ?? "\(error)"
        }
        #expect(said.contains("link"))
    }

    @Test func A_list_a_windows_tool_wrote_with_a_byte_order_mark_reads() throws {
        let f = BatchFolder()
        let json = #"{ "version": 1, "files": [{ "path": "a.pdf", "copies": 2 }] }"#
        let path = (f.root as NSString).appendingPathComponent("list.inkvoltlist")
        let encodings: [[UInt8]] = [
            [0xEF, 0xBB, 0xBF] + Array(json.utf8),
            [0xFF, 0xFE] + json.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] },
            [0xFE, 0xFF] + json.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] },
        ]
        for bytes in encodings {
            try Data(bytes).write(to: URL(fileURLWithPath: path))
            let entries = try BatchPrintList.load(path, allowNetwork: false)
            #expect(entries.count == 1)
            #expect(entries.first?.settings.copies == 2)
        }
    }

    @Test func A_list_of_broken_text_is_refused_in_words() throws {
        let f = BatchFolder()
        let path = (f.root as NSString).appendingPathComponent("bytes.inkvoltlist")
        try Data(Array(#"{ "version": 1, "files": [{ "path": "a"#.utf8) + [0xFF, 0xFE] + Array(#".pdf" }] }"#.utf8)).write(to: URL(fileURLWithPath: path))
        #expect(throws: BatchListError.self) { _ = try BatchPrintList.load(path, allowNetwork: false) }
    }

    @Test func A_recursive_folder_doesnt_follow_a_junction_out_of_it_or_round_in_a_loop() throws {
        let f = BatchFolder()
        let own = f.file("in/sub/own.pdf")
        f.file("secret/payroll.pdf")
        let folder = (f.root as NSString).appendingPathComponent("in")
        do {
            try FileManager.default.createSymbolicLink(atPath: (folder as NSString).appendingPathComponent("out"),
                                                       withDestinationPath: (f.root as NSString).appendingPathComponent("secret"))
            try FileManager.default.createSymbolicLink(atPath: ((folder as NSString).appendingPathComponent("sub") as NSString).appendingPathComponent("loop"),
                                                       withDestinationPath: folder)
        } catch {
            return // this Windows PC doesn't let this user make links
        }
        let found = BatchPrintFiles.listFolder(folder, recursive: true)
        #expect(found.count == 1)
        #expect(found.first.map { ($0 as NSString).lastPathComponent } == (own as NSString).lastPathComponent)
    }
}
