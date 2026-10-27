import Foundation
import Testing
@testable import PdfCore

/// Ported from Core1NavigationTests.cs, the parts that read a document: its outline, links and their targets. The page
/// edits (delete, extract, merge, insert, duplicate, rotate) and form fields across them come with D3 and D5.
struct Core1NavigationTests {
    private static let nav = Core1TestPdf.navigation()

    /// The outline as "Title@page" entries, children indented.
    private func outline(_ data: [UInt8]) throws -> String {
        let e = try PdfEngine.open(data)
        defer { e.close() }
        var s = ""
        func walk(_ nodes: [OutlineNode], _ indent: String) {
            for n in nodes {
                s += "\(indent)\(n.title)@\(n.pageIndex);"
                walk(n.children, indent + ">")
            }
        }
        walk(try e.outline(), "")
        return s
    }

    private func linkTargets(_ data: [UInt8], _ page: Int) throws -> [Int] {
        let e = try PdfEngine.open(data)
        defer { e.close() }
        return try e.links(page).map(\.pageIndex)
    }

    @Test func originalNavigationResolves() throws {
        #expect(try outline(Self.nav) == "Ch1@0;>Ch1.1@1;>Ch1.2@2;Ch2@3;>Ch2.1@4;")
        #expect(try linkTargets(Self.nav, 0) == [2, 3])
    }

    @Test func linkAndBookmarkTargetsKeepTheirPosition() throws {
        let e = try PdfEngine.open(Self.nav)
        defer { e.close() }
        let links = try e.links(0)
        #expect(abs(try #require(links[0].targetY) - 100) <= 1) // /XYZ 0 692 on a 792pt page
        #expect(links[1].targetY == nil) // /Fit names no position
        let outline = try e.outline()
        #expect(abs(try #require(outline[0].targetY) - 92) <= 1)
        #expect(abs(try #require(outline[1].targetY) - 292) <= 1) // /FitH 500
    }

    @Test func aDocumentWithoutAnOutlineHasNone() throws {
        #expect(try outline(TestPdf.make(2)) == "")
    }
}
