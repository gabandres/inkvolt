import Foundation
import Testing
@testable import PdfCore

/// `Annotations.move` and `Annotations.setColor`: sticky notes and text marks (highlight, underline, strike-out,
/// squiggly) moved and recolored in place, keeping their id, text, replies and appearance. A Mac addition: the Windows
/// app moves and restyles only drawings (`UpdateGeometry`, `UpdateStyle`), so these tests have no .NET counterpart.
struct CommentMoveTests {
    /// The pixel at a page point (page space, 1 px per point).
    private static func pixel(_ pdf: [UInt8], _ x: Double, _ y: Double) throws -> (r: Int, g: Int, b: Int) {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let image = try engine.render(0, scale: 1)
        let i = (Int(y) * image.width + Int(x)) * 3
        return (Int(image.pixels[i]), Int(image.pixels[i + 1]), Int(image.pixels[i + 2]))
    }

    private static func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 240 && p.g > 240 && p.b > 240 }

    @Test func NotesMoveWithTheirAppearance() throws {
        var pdf = TestPdf.make(1)
        pdf = try Annotations.addNote(pdf, nil, 0, 400, 300, "Look here", author: "Ana", id: "note-1")
        pdf = try Annotations.addReply(pdf, nil, "note-1", "Seen", author: "Bo", id: "reply-1")
        #expect(!Self.isWhite(try Self.pixel(pdf, 410, 310)))
        let moved = try Annotations.move(pdf, nil, "note-1", dx: 60, dy: 120)
        let all = try Annotations.read(moved, nil)
        let note = try #require(all.first { $0.id == "note-1" })
        #expect(abs(note.rect.x - 460) < 0.01 && abs(note.rect.y - 420) < 0.01 && abs(note.rect.width - 20) < 0.01)
        #expect(note.contents == "Look here" && note.author == "Ana")
        let reply = try #require(all.first { $0.id == "reply-1" })
        #expect(reply.replyTo == "note-1" && abs(reply.rect.x - 460) < 0.01 && abs(reply.rect.y - 420) < 0.01) // the reply came along
        let there = try Self.pixel(moved, 470, 426)
        #expect(there.r > 200 && there.g > 180 && there.b < 120) // the yellow bubble came along
        #expect(Self.isWhite(try Self.pixel(moved, 410, 310)))
    }

    @Test func TextMarksMoveWithTheirQuads() throws {
        var pdf = TestPdf.make(1)
        pdf = try Annotations.addTextMarkup(pdf, nil, 0, .highlight, [RectD(380, 200, 120, 14), RectD(380, 216, 80, 14)], .yellow,
                                            note: nil, author: "Ana", id: "mark-1")
        let moved = try Annotations.move(pdf, nil, "mark-1", dx: -20, dy: 150)
        let mark = try #require(try Annotations.read(moved, nil).first { $0.id == "mark-1" })
        #expect(mark.quadRects.count == 2)
        #expect(abs(mark.quadRects[0].x - 360) < 0.01 && abs(mark.quadRects[0].y - 350) < 0.01)
        #expect(abs(mark.quadRects[1].y - 366) < 0.01 && abs(mark.quadRects[1].width - 80) < 0.01)
        let there = try Self.pixel(moved, 420, 357)
        #expect(there.b < 120 && there.r > 200) // yellow, multiplied onto white
        #expect(Self.isWhite(try Self.pixel(moved, 440, 207)))
    }

    @Test func RecoloringRedrawsNotesAndTextMarks() throws {
        var pdf = TestPdf.make(1)
        pdf = try Annotations.addTextMarkup(pdf, nil, 0, .highlight, [RectD(380, 200, 120, 14)], .yellow, note: nil, author: "Ana", id: "mark-1")
        pdf = try Annotations.addTextMarkup(pdf, nil, 0, .underline, [RectD(380, 400, 120, 14)], .red, note: nil, author: "Ana", id: "line-1")
        pdf = try Annotations.addNote(pdf, nil, 0, 400, 300, "Look here", author: "Ana", id: "note-1")
        let blue = AnnotColor(0.1, 0.4, 0.9), green = AnnotColor(0.15, 0.65, 0.2)
        pdf = try Annotations.setColor(pdf, nil, "mark-1", blue)
        pdf = try Annotations.setColor(pdf, nil, "line-1", green)
        pdf = try Annotations.setColor(pdf, nil, "note-1", green)
        let all = try Annotations.read(pdf, nil)
        #expect(all.first { $0.id == "mark-1" }?.color == blue)
        #expect(all.first { $0.id == "line-1" }?.color == green)
        #expect(all.first { $0.id == "note-1" }?.color == green)
        #expect(all.first { $0.id == "mark-1" }?.quadRects.count == 1)
        let mark = try Self.pixel(pdf, 440, 207)
        #expect(mark.b > 200 && mark.r < 80) // blue now
        let note = try Self.pixel(pdf, 410, 306)
        #expect(note.g > 120 && note.r < 100 && note.b < 100) // green bubble
        // A second recolor and a move after it keep the new look.
        let again = try Annotations.move(try Annotations.setColor(pdf, nil, "mark-1", .yellow), nil, "mark-1", dx: 0, dy: 40)
        let moved = try Self.pixel(again, 440, 247)
        #expect(moved.r > 200 && moved.b < 120)
    }

    @Test func OnlyNotesAndTextMarksMoveThisWay() throws {
        var pdf = TestPdf.make(1)
        pdf = try Annotations.addShape(pdf, nil, 0, .rectangle, RectD(100, 100, 50, 40), .pen(.red), author: "Ana", id: "box-1")
        #expect(throws: PdfEditError.self) { try Annotations.move(pdf, nil, "box-1", dx: 10, dy: 10) }
        #expect(throws: PdfEditError.self) { try Annotations.setColor(pdf, nil, "box-1", .yellow) }
        #expect(throws: PdfEditError.self) { try Annotations.move(pdf, nil, "missing", dx: 10, dy: 10) }
        // Nothing to do: the same bytes back.
        let noted = try Annotations.addNote(pdf, nil, 0, 300, 300, "x", author: "Ana", id: "note-1")
        #expect(try Annotations.move(noted, nil, "note-1", dx: 0, dy: 0) == noted)
    }

    @Test func MovesFollowThePageAsShownOnRotatedPages() throws {
        var pdf = try PageEditor.rotate(TestPdf.make(1), nil, [0], 90)
        pdf = try Annotations.addNote(pdf, nil, 0, 300, 200, "Sideways", author: "Ana", id: "note-1")
        pdf = try Annotations.addTextMarkup(pdf, nil, 0, .strikeOut, [RectD(100, 400, 150, 14)], .red, note: nil, author: "Ana", id: "mark-1")
        let moved = try Annotations.move(try Annotations.move(pdf, nil, "note-1", dx: 40, dy: 25), nil, "mark-1", dx: 30, dy: -50)
        let all = try Annotations.read(moved, nil)
        let note = try #require(all.first { $0.id == "note-1" })
        let mark = try #require(all.first { $0.id == "mark-1" })
        #expect(abs(note.rect.x - 340) < 0.01 && abs(note.rect.y - 225) < 0.01)
        #expect(abs(mark.quadRects[0].x - 130) < 0.01 && abs(mark.quadRects[0].y - 350) < 0.01 && abs(mark.quadRects[0].width - 150) < 0.01)
    }
}
