import Foundation

extension Annotations {
    /// Gives an imported annotation that came without an appearance (XFDF, CSV) the one Inkvolt PDF would draw for it
    /// (the Windows app's `Annotations.MakeAppearance`): drawings from their geometry and style, text markups from their
    /// quads, notes their icon, stamps their design (a built-in one by /Name, else the name in a frame). Kinds it doesn't
    /// draw are left to the viewer. /M stays as it was.
    static func makeAppearance(_ doc: MuDoc, _ page: PObj, _ annot: PObj) {
        let subtype = annot.name("Subtype") ?? ""
        let modified = annot["M"]
        let color = colorOf(annot.array("C"))
        defer {
            if let modified { annot.set("M", modified) } else { annot.remove("M") }
        }
        if isDrawing(annot, subtype) {
            guard let d = describe(page, annot, subtype), (try? validate(subtype, d.geometry, d.style)) != nil else { return }
            apply(doc, page, annot, subtype, d.geometry, d.style)
        } else if let markup = TextMarkupKind(rawValue: subtype) {
            var quads: [Quad] = []
            if let qp = annot.array("QuadPoints") {
                var k = 0
                func point(_ i: Int) -> QuadPoint { (x: qp.num(i), y: qp.num(i + 1)) }
                while k + 7 < qp.count && quads.count < maxPoints {
                    let q: Quad = (ul: point(k), ur: point(k + 2), ll: point(k + 4), lr: point(k + 6))
                    quads.append(q)
                    k += 8
                }
            }
            if quads.isEmpty { return }
            setAppearance(doc, annot, markupForm(doc, markup, quads, color ?? .yellow).form)
        } else if subtype == "Text" {
            setAppearance(doc, annot, noteForm(doc, page, color ?? .yellow))
        } else if subtype == "Stamp", let r = annot.array("Rect"), r.count == 4 {
            let w = abs(r.num(2) - r.num(0)), h = abs(r.num(3) - r.num(1))
            if w < 1 || h < 1 { return }
            let design = RubberStamps.designOf(annot) ?? stampDesign(annot.name("Name") ?? "Draft", color)
            let (ops, resources) = RubberStamps.appearance(doc, design, w, h)
            setAppearance(doc, annot, doc.formXObject(ops, 0, 0, w, h, resources))
        }
    }

    /// A stamp's design from its /Name: a built-in one ("Approved", "#Draft", "SBApproved"…), else the name in capitals.
    private static func stampDesign(_ name: String, _ color: AnnotColor?) -> StampDesign {
        let bare = name.hasPrefix("#") ? String(name.dropFirst()) : name
        let key = bare.replacingOccurrences(of: "Stamp", with: "").lowercased()
        if let builtIn = RubberStamps.builtIn.first(where: { $0.name.lowercased() == key }) { return builtIn }
        return StampDesign(name, name, bare.uppercased(), nil, color ?? StampDesign.blue)
    }
}
