import Foundation
import PrintCore

/// Turning a picture or a paragraph to any angle (roadmap 4.22; the Windows app's `ContentEditor.Rotate`), about the
/// middle of its box. A picture gets the turn in front of its own placement (as a move does); a paragraph's show operators
/// are each drawn again from a text matrix turned the same way (its glyphs, spacing and kerning as they were), and the text
/// position put back where each left it, so the rest of the page draws where it did; its pictures in the flow turn with
/// it. One save, so one undo step.
extension ContentEditor {
    /// Turns a picture `degrees` clockwise (as the page shows) about the middle of its box. The same bytes for no turn.
    public static func rotateImage(_ data: [UInt8], _ password: String?, _ image: PageImage, _ degrees: Double) throws -> [UInt8] {
        guard degrees.isFinite else { throw ContentEditError(loc("That angle can't be used.")) }
        let degrees = turn(degrees)
        if abs(degrees) < 0.01 { return data }
        return try editImage(data, password, image) { _, page, found, op, ctm, ops, content in
            let center = PointD(found.box.centerX, found.box.centerY)
            return [try placing(ops, op, turnMatrix(PageBoxes.frame(page), ctm, center, degrees), content)]
        }
    }

    /// Turns a paragraph `degrees` clockwise (as the page shows) about the middle of its box. Its text isn't rewritten:
    /// each show operator is drawn as it was, from a turned text matrix. The same bytes for no turn.
    /// - Throws: `ContentEditError` when the paragraph can't be edited, or the page changed.
    public static func rotateParagraph(_ data: [UInt8], _ password: String?, _ paragraph: TextParagraph, _ degrees: Double) throws -> [UInt8] {
        if let why = paragraph.blocked { throw ContentEditError(loc("This paragraph can't be edited: {0}.", why)) }
        guard degrees.isFinite else { throw ContentEditError(loc("That angle can't be used.")) }
        let degrees = turn(degrees)
        if abs(degrees) < 0.01 { return data }
        let doc = try PdfEdit.open(data, password, failure: loc("This PDF can't be edited"))
        let page = try pageOf(doc, paragraph.pageIndex)
        let streams = streams(page)
        let ops = ContentLexer.parse(streams.bytes)
        let walked = try walk(doc, page, paragraph.pageIndex, ops, nil)
        let changed = loc("The page changed since this paragraph was picked. Pick it again.")
        var now = try rematch(paragraph, walked).now
        // Spaces drawn on their own on its lines turn with it.
        for s in paragraph.spaces {
            if let found = walked.textRuns.first(where: { $0.id == s.id && same($0.text, s.text) && $0.info != nil }),
               !now.contains(where: { $0.id == found.id }) {
                now.append(found)
            }
        }
        guard let anchor = now.first else { throw ContentEditError(changed) }
        if now.contains(where: { $0.info!.form != anchor.info!.form || $0.info!.columns > 1 }) { throw ContentEditError(changed) }
        let target = try targetOf(doc, page, streams, ops, walked, anchor)
        if Set(now.map { ObjectIdentifier(target.opOf($0, walked)) }).count != now.count { throw ContentEditError(changed) }
        let frame = PageBoxes.frame(page)
        let center = PointD(paragraph.box.centerX, paragraph.box.centerY)
        let turned = try pageTurnInUser(frame, center, degrees)

        var edits: Edits = []
        for run in now {
            let info = run.info!
            let op = target.opOf(run, walked)
            guard let inv = info.ctm.inverted() else {
                throw ContentEditError(loc("This text is drawn squashed flat, so it can't be rewritten."))
            }
            // Drawn at Tm × CTM; turned, at Tm × CTM × turn: the text matrix that gives that under the same CTM.
            let tm = info.tm.times(info.ctm).times(turned).times(inv)
            let text = nextLine(op, run) + tm.write() + " Tm " + showOnly(op, target.bytes) + " " + backAfter(run)
            edits.append((op.start, op.end, latin1Bytes(text)))
        }
        // Its pictures in the flow turn with it.
        if !paragraph.pictures.isEmpty {
            if target.form != nil { throw ContentEditError(changed) }
            for pic in paragraph.pictures {
                guard let found = walked.images.first(where: { $0.id == pic.image.id && near($0.box, pic.image.box) }), found.blocked == nil,
                      let ctm = walked.imageCtm[found.id], found.id >= 0, found.id < ops.count else { throw ContentEditError(changed) }
                edits.append(try placing(ops, ops[found.id], try turnMatrix(frame, ctm, center, degrees), streams.bytes))
            }
        }
        try writeTarget(doc, page, target, edits)
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    /// A show operator's drawing alone, as Tj or TJ (' and " leave their line step and spacing to `nextLine`).
    private static func showOnly(_ op: COp, _ content: [UInt8]) -> String {
        if op.name == "Tj" || op.name == "TJ" { return latin1String(content[op.start..<op.end]) }
        guard let text = op.operands.last else { return "" }
        return latin1String(content[text.start..<text.end]) + (text.kind == .array ? " TJ" : " Tj")
    }

    /// A turn of `degrees` clockwise about a page point, in the page's user space.
    private static func pageTurnInUser(_ frame: PageFrame, _ center: PointD, _ degrees: Double) throws -> Mat {
        let r = degrees * .pi / 180
        let s = sin(r), c = cos(r)
        // Page space is y-down: this turns clockwise as the page shows.
        let e: Double = center.x - center.x * c + center.y * s
        let f: Double = center.y - center.x * s - center.y * c
        let d = Mat(c, s, -s, c, e, f)
        let p2u = pageToUser(frame)
        guard let u2p = p2u.inverted() else { throw ContentEditError(loc("This page's size can't be read.")) }
        return u2p.times(d).times(p2u)
    }

    /// The matrix that, put before a picture drawn at `ctm`, turns it about a page point.
    private static func turnMatrix(_ frame: PageFrame, _ ctm: Mat, _ center: PointD, _ degrees: Double) throws -> Mat {
        guard let inv = ctm.inverted() else { throw ContentEditError(loc("This picture is drawn squashed flat, so it can't be moved.")) }
        return ctm.times(try pageTurnInUser(frame, center, degrees)).times(inv)
    }

    /// The direction a picture's own x axis takes on the page: degrees clockwise from left-to-right.
    static func imageAngle(_ frame: PageFrame, _ ctm: Mat) -> Double {
        let p0 = ctm.apply(0, 0), p1 = ctm.apply(1, 0)
        let a = frame.toPage(p0.x, p0.y), b = frame.toPage(p1.x, p1.y)
        if abs(b.x - a.x) < 1e-9 && abs(b.y - a.y) < 1e-9 { return 0 }
        let degrees = turn(atan2(b.y - a.y, b.x - a.x) * 180 / .pi)
        return (degrees * 1e6).rounded(.toNearestOrEven) / 1e6
    }
}
