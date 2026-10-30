import Foundation

/// What `Flattener.flatten` merges into the pages.
public struct FlattenOptions: Equatable, Sendable {
    /// Comments and other annotations (everything but form fields and links). Their popups go too.
    public var annotations = true
    /// Form fields: their widgets are drawn and the fields removed from the form. Signature fields stay.
    public var formFields = true
    /// Links (removed: they have nothing to draw, usually).
    public var links = false
    /// Draw only annotations meant to print (/F Print flag); the others are removed without a trace.
    public var printableOnly = false

    public init(annotations: Bool = true, formFields: Bool = true, links: Bool = false, printableOnly: Bool = false) {
        self.annotations = annotations
        self.formFields = formFields
        self.links = links
        self.printableOnly = printableOnly
    }
}

/// Flattening (the Windows app's `Flattener`): each annotation's normal appearance (/AP /N, the /AS state for check
/// boxes and radios) is drawn into its page's content as a form XObject, mapped onto the annotation's /Rect the way
/// viewers do (ISO 32000-2 12.5.5: the /BBox transformed by the /Matrix, fitted to the /Rect), with its opacity (/CA)
/// and layer (/OC); then the annotation is removed. Hidden annotations (Hidden, NoView flags) are removed without being
/// drawn. Text and choice fields without an appearance (or with /NeedAppearances) get one generated first. Pages change,
/// which no signature permits, so a signed document needs the caller's consent (`SignedEdits.run` with the rewrite
/// allowed).
public enum Flattener {
    private static let flagHidden = 2, flagPrint = 4, flagNoView = 32

    /// - Throws: `SignaturesWouldBreak` when the document is signed and the rewrite wasn't allowed; `OwnerPasswordRequired`.
    public static func flatten(_ data: [UInt8], _ password: String?, _ options: FlattenOptions = FlattenOptions()) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        let catalog = doc.catalog
        let acro = catalog.dict("AcroForm")
        var removed = Set<UInt>()
        var removedKeys: [Int] = []
        var widgets: [PObj] = []
        var pagesTouched = false
        let pages = try doc.pages()

        for page in pages {
            guard page.array("Annots") != nil else { continue }
            let annots = doc.annots(page) // the page's own array, if pages share one
            var take: [PObj] = []
            for a in annots.elements where a.isDict {
                let flatten: Bool
                switch a.name("Subtype") {
                case "Widget": flatten = options.formFields && FormEditor.inherited(a, "FT")?.name != "Sig"
                case "Link": flatten = options.links
                default: flatten = options.annotations
                }
                if flatten { take.append(a) }
            }
            if take.isEmpty { continue }
            if !pagesTouched {
                try SignedEdits.requireRewrite(data, reason: "flattening changes page content, which no signature permits")
                if options.formFields, let acro { try FormEditor.ensureAppearances(doc, acro) }
                pagesTouched = true
            }

            var ops = ""
            for a in take {
                draw(doc, page, a, options, &ops)
                removed.insert(a.identity)
                if let key = a.int("StructParent") { removedKeys.append(key) }
                if a.name("Subtype") == "Widget" { widgets.append(a) }
            }
            for i in stride(from: annots.count - 1, through: 0, by: -1) {
                if let a = annots[i], a.isDict, removed.contains(a.identity) { annots.remove(at: i) }
            }
            if annots.count == 0 { page.remove("Annots") }
            if !ops.isEmpty { appendContent(doc, page, ops) }
        }
        if !pagesTouched { return data }

        // Annotations that stay must not point at removed ones (a popup's /Parent, a reply's /IRT, a markup's /Popup).
        for page in pages {
            for a in page.array("Annots")?.elements ?? [] where a.isDict {
                for key in ["Parent", "IRT", "Popup"] {
                    if let target = a.dict(key), removed.contains(target.identity) { a.remove(key) }
                }
            }
        }

        if !widgets.isEmpty, let acro { removeFields(catalog, acro, widgets, &removed) }
        if !removed.isEmpty { StructTree.prune(doc, gonePages: [], goneKeys: removedKeys) { removed.contains($0.identity) } }
        InfoDict.setDate(doc, "ModDate", Date())
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password, rewrite: true)
    }

    /// Takes the flattened widgets out of the form; a form left without fields goes entirely.
    private static func removeFields(_ catalog: PObj, _ acro: PObj, _ widgets: [PObj], _ removed: inout Set<UInt>) {
        for w in widgets { Redaction.removeWidget(acro, w, &removed) }
        if let co = acro.array("CO") {
            for i in stride(from: co.count - 1, through: 0, by: -1) {
                if let f = co[i], f.isDict, removed.contains(f.identity) { co.remove(at: i) }
            }
        }
        // An XFA form keeps its own copy of the values; once AcroForm fields went, the AcroForm is what remains.
        acro.remove("XFA")
        if (acro.array("Fields")?.count ?? 0) == 0 { catalog.remove("AcroForm") }
    }

    /// Appends the drawing of `annot`'s normal appearance to `ops`, if it shows.
    private static func draw(_ doc: MuDoc, _ page: PObj, _ annot: PObj, _ options: FlattenOptions, _ ops: inout String) {
        let flags = annot.int("F") ?? 0
        if flags & (flagHidden | flagNoView) != 0 || (options.printableOnly && flags & flagPrint == 0) { return }
        guard let form = appearance(annot), form.isRef, let r = annot.array("Rect"), r.count >= 4,
              let bb = form.array("BBox"), bb.count >= 4 else { return }

        let rx1 = min(r.num(0), r.num(2)), ry1 = min(r.num(1), r.num(3))
        let rx2 = max(r.num(0), r.num(2)), ry2 = max(r.num(1), r.num(3))
        let (bx1, by1, bx2, by2) = transformedBox(form, bb)
        if bx2 - bx1 <= 1e-6 || by2 - by1 <= 1e-6 || rx2 - rx1 <= 1e-6 || ry2 - ry1 <= 1e-6 { return }
        // Matrix A of 12.5.5: maps the transformed bounding box onto the rectangle.
        let sx = (rx2 - rx1) / (bx2 - bx1)
        let sy = (ry2 - ry1) / (by2 - by1)

        form.set("Type", doc.name("XObject"))
        form.set("Subtype", doc.name("Form"))
        let resources = resourcesOf(doc, page)
        let name = add(doc, resources, "XObject", "Flat", form)

        // An annotation in a layer stays in it.
        var oc: String?
        if let ocItem = annot["OC"], ocItem.isDict { oc = add(doc, resources, "Properties", "FlatOC", ocItem) }
        if let oc { ops += "/OC /\(oc) BDC\n" }
        ops += "q\n"
        if let ca = annot.number("CA"), ca < 1 {
            let v = min(max(ca, 0), 1)
            let gs = doc.dict([("Type", doc.name("ExtGState")), ("CA", doc.real(v)), ("ca", doc.real(v))])
            ops += "/\(add(doc, resources, "ExtGState", "FlatGS", gs)) gs\n"
        }
        ops += "\(PdfNum.f(sx)) 0 0 \(PdfNum.f(sy)) \(PdfNum.f(rx1 - bx1 * sx)) \(PdfNum.f(ry1 - by1 * sy)) cm /\(name) Do\nQ\n"
        if oc != nil { ops += "EMC\n" }
    }

    /// The normal appearance stream: /AP /N itself, or its /AS state's entry.
    private static func appearance(_ annot: PObj) -> PObj? {
        guard let n = annot.dict("AP")?["N"], n.isDict else { return nil }
        if n.isStream { return n }
        guard let state = annot.name("AS"), let s = n[state], s.isStream else { return nil }
        return s
    }

    /// The form's /BBox transformed by its /Matrix, as an axis-aligned box.
    private static func transformedBox(_ form: PObj, _ bb: PObj) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        let m: [Double]
        if let ma = form.array("Matrix"), ma.count >= 6 { m = (0..<6).map { ma.num($0) } } else { m = [1, 0, 0, 1, 0, 0] }
        let x1 = bb.num(0), y1 = bb.num(1), x2 = bb.num(2), y2 = bb.num(3)
        var xs: [Double] = [], ys: [Double] = []
        for (x, y) in [(x1, y1), (x2, y1), (x1, y2), (x2, y2)] {
            xs.append(m[0] * x + m[2] * y + m[4])
            ys.append(m[1] * x + m[3] * y + m[5])
        }
        return (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
    }

    /// The page's own resources dictionary (a copy of the inherited one, or a new one, when it has none).
    private static func resourcesOf(_ doc: MuDoc, _ page: PObj) -> PObj {
        if let res = page.dict("Resources") { return res }
        let res = doc.dict()
        if let inherited = PageBoxes.inherited(page, "Resources"), inherited.isDict {
            for k in inherited.keys { res.set(k, inherited[k]) }
        }
        page.set("Resources", res)
        return res
    }

    /// Adds `value` to a resource category under a fresh name ("Flat0", ...), which it returns (without its slash).
    private static func add(_ doc: MuDoc, _ resources: PObj, _ category: String, _ prefix: String, _ value: PObj) -> String {
        var dict = resources.dict(category)
        if dict == nil {
            dict = doc.dict()
            resources.set(category, dict)
        }
        var i = 0
        while dict!.has("\(prefix)\(i)") { i += 1 }
        let name = "\(prefix)\(i)"
        dict!.set(name, value)
        return name
    }

    /// Appends `ops` after the page's content, which is wrapped in q/Q so its graphics state can't leak.
    private static func appendContent(_ doc: MuDoc, _ page: PObj, _ ops: String) {
        var contents: [PObj] = [doc.addStream(Array("q\n".utf8), deflate: false)]
        if let existing = page["Contents"] {
            contents += existing.isArray ? existing.elements : [existing]
        }
        contents.append(doc.addStream(Array(("Q\n" + ops).utf8), deflate: false))
        page.set("Contents", doc.array(contents))
    }
}

extension FormEditor {
    /// Every field gets appearance streams that show its value (a producer relying on /NeedAppearances, or a value
    /// written without one), so drawing the widgets draws what the user sees.
    static func ensureAppearances(_ doc: MuDoc, _ acro: PObj) throws {
        let fields = try collect(doc, acro)
        finishAppearances(doc, acro, fields, fields, nil)
    }
}
