import Foundation
import PrintCore

/// Text inside form XObjects (drawings a page reuses: stamped or flattened pages, some generators' every block) is edited
/// where it is drawn: the form's own content stream is rewritten (roadmap 2.1, part d; the Windows app's
/// ContentEditor.Forms.cs). A form the page draws more than once, or that other pages draw too, is copied for the Do that
/// was clicked first, so only that one changes. A form drawn through another form can't be copied that way: it is edited
/// when nothing in its chain is shared, else left alone.
extension ContentEditor {
    /// The content an edit rewrites: the page's own streams, or one form XObject's stream.
    struct Target {
        var ops: [COp]
        var bytes: [UInt8]
        /// The page's streams (nil: a form).
        var streams: PageStreams?
        var form: FormPlace?
        /// The form to write (a copy when the original was shared).
        var formObject: PObj?
        /// The dictionary whose /Resources get the fonts an edit adds: the innermost form with resources of its own, else
        /// the page.
        var resourceOwner: PObj
        /// The resources the content's operators use.
        var resources: PObj?

        /// The operator a run is drawn by.
        func opOf(_ run: TextRun, _ walked: Walked) -> COp {
            form == nil ? ops[run.id] : ops[walked.formOf[run.id]!.index]
        }
    }

    /// Where `run` is edited; a form shared with other drawings of it is copied for this page's Do first.
    static func targetOf(_ doc: MuDoc, _ page: PObj, _ streams: PageStreams, _ pageOps: [COp], _ walked: Walked, _ run: TextRun) throws -> Target {
        guard let place = walked.formOf[run.id]?.place else {
            return Target(ops: pageOps, bytes: streams.bytes, streams: streams, form: nil, formObject: nil, resourceOwner: page,
                          resources: PageBoxes.inherited(page, "Resources").flatMap { $0.isDict ? $0 : nil })
        }
        var form = place.form
        if (walked.formUses[form.id] ?? 0) > 1 || sharedElsewhere(doc, page, place) {
            if place.outer != nil {
                throw ContentEditError(loc("This text can't be edited: it is inside a drawing (a form XObject) that other pages share, drawn through another drawing, and an edit would change every copy."))
            }
            form = try copyForm(doc, page, streams, pageOps, place)
        }
        var owner = page
        if form.dict("Resources") != nil {
            owner = form
        } else {
            var f = place.outer
            while let p = f {
                if p.form.dict("Resources") != nil {
                    owner = p.form
                    break
                }
                f = p.outer
            }
        }
        return Target(ops: place.ops, bytes: place.bytes, streams: nil, form: place, formObject: form, resourceOwner: owner,
                      resources: place.resources)
    }

    /// Whether another page draws any form of `place`'s chain (through its XObject resources, at any depth).
    private static func sharedElsewhere(_ doc: MuDoc, _ page: PObj, _ place: FormPlace) -> Bool {
        let chain = Set(place.chain.map(\.id))
        var seen = Set<ObjId>()
        func visit(_ xo: PObj?, _ depth: Int) -> Bool {
            guard let xo, depth <= maxDepth else { return false }
            for key in xo.keys {
                guard let form = xo.dict(key), form.name("Subtype") == "Form" else { continue }
                if chain.contains(form.id) { return true }
                if !seen.insert(form.id).inserted { continue }
                if visit(form.dict("Resources")?.dict("XObject"), depth + 1) { return true }
            }
            return false
        }
        guard let count = try? doc.pageCount() else { return false }
        let mine = page.id
        for i in 0..<count {
            let other = doc.page(i)
            if other.id == mine { continue }
            if visit(PageBoxes.inherited(other, "Resources")?.dict("XObject"), 0) { return true }
        }
        return false
    }

    /// A copy of a form the page draws directly, under a name of its own, with the Do changed to draw the copy.
    private static func copyForm(_ doc: MuDoc, _ page: PObj, _ streams: PageStreams, _ pageOps: [COp], _ place: FormPlace) throws -> PObj {
        let dict = doc.dict()
        for key in place.form.keys where !["Filter", "DecodeParms", "Length"].contains(key) {
            if let v = place.form[key] { dict.set(key, ownCopy(doc, v)) } // its inline /Resources its own, not the original's
        }
        let copy = doc.addStream(place.bytes, dict: dict, deflate: true)
        let name = addXObject(doc, page, copy, prefix: "InkFm")
        let op = pageOps[place.doId]
        try writeContent(doc, page, streams, pageOps, [(op.start, op.end, latin1Bytes("/\(name) Do"))])
        return copy
    }

    /// Writes the edits into the target's content: the page's streams, or the form's stream.
    static func writeTarget(_ doc: MuDoc, _ page: PObj, _ target: Target, _ edits: Edits) throws {
        if let streams = target.streams {
            try writeContent(doc, page, streams, target.ops, edits)
        } else if let form = target.formObject {
            form.remove("DecodeParms")
            form.setStream(try splice(target.bytes, edits), deflate: true)
        }
    }

    /// Adds fonts to the page's or form's own font resources (copying shared dictionaries first).
    static func addFonts(_ doc: MuDoc, _ owner: PObj, _ fonts: PObj) {
        let inherited = owner.name("Type") == "Page" ? PageBoxes.inherited(owner, "Resources") : nil
        let res = ownDict(doc, owner, "Resources", inherited)
        let fd = ownDict(doc, res, "Font")
        for key in fonts.keys {
            if let v = fonts[key] { fd.set(key, v) }
        }
    }

    /// A name prefix for stand-in fonts that no font of the content's resources has yet.
    static func standInPrefix(_ target: Target) -> String {
        let keys = target.resources?.dict("Font")?.keys ?? []
        var k = 1
        while keys.contains(where: { $0.hasPrefix("\(standInKey)\(k)_") }) { k += 1 }
        return "/\(standInKey)\(k)_"
    }
}
