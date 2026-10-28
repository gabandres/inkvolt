import Foundation
import Testing
@testable import PdfCore

/// `Annotations.addReply` (the Windows app's `Annotations.AddReply`, tested there through CommentFilesTests): replies bound
/// to their comment by /IRT, nested replies, and deleting a comment taking its replies with it.
struct AnnotationReplyTests {
    @Test func RepliesBindToTheirCommentAndGoWithIt() throws {
        var pdf = TestPdf.make(1)
        pdf = try Annotations.addNote(pdf, nil, 0, 100, 100, "Question?", author: "Ana", id: "note-1")
        pdf = try Annotations.addReply(pdf, nil, "note-1", "Agreed ✓ — señal", author: "Bo", id: "reply-1")
        pdf = try Annotations.addReply(pdf, nil, "reply-1", "Nested reply", author: "Ana Lucía", id: "reply-2")
        let all = try Annotations.read(pdf, nil)
        #expect(all.count == 3)
        let reply = try #require(all.first { $0.id == "reply-1" })
        #expect(reply.replyTo == "note-1" && reply.contents == "Agreed ✓ — señal" && reply.author == "Bo" && reply.kind == .text)
        #expect(all.first { $0.id == "reply-2" }?.replyTo == "reply-1")
        // At the comment's top-left corner, on its page.
        #expect(abs(reply.rect.x - 100) < 0.01 && abs(reply.rect.y - 100) < 0.01)
        #expect(throws: PdfEditError.self) { try Annotations.addReply(pdf, nil, "missing", "x", author: "A") }
        let gone = try Annotations.delete(pdf, nil, "note-1")
        #expect(try Annotations.read(gone, nil).isEmpty)
    }
}
