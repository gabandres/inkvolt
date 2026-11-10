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
    /// Signature fields are drawn and removed too (the print copy only: their signatures no longer verify).
    var signatureFields = false

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
/// and layer (/OC); then the annotation is removed. What the screen doesn't show (`Look.nothing`: popups, the Invisible,
/// Hidden and NoView flags, a widget of no field, a /Rect without area) is removed without being drawn, as is what has
/// no appearance of its own to draw. Text and choice fields without an appearance (or with /NeedAppearances) get one generated first. Pages change,
/// which no signature permits, so a signed document needs the caller's consent (`SignedEdits.run` with the rewrite
/// allowed).
public enum Flattener {
    private static let flagInvisible = 1, flagHidden = 2, flagPrint = 4, flagNoView = 32

    /// - Throws: `SignaturesWouldBreak` when the document is signed and the rewrite wasn't allowed; `OwnerPasswordRequired`.
    public static func flatten(_ data: [UInt8], _ password: String?, _ options: FlattenOptions = FlattenOptions()) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        let touched = try flattenPages(doc, options) {
            try SignedEdits.requireRewrite(data, reason: "flattening changes page content, which no signature permits")
        }
        if !touched { return data }
        InfoDict.setDate(doc, "ModDate", Date())
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password, rewrite: true)
    }

    /// Flattens `doc` in place (what `flatten` does before saving it; `PrintCopy` too). `beforeChange` runs once, before
    /// the first page changes; `appearancesReady`: the form fields already have their appearances. False when nothing
    /// was flattened.
    static func flattenPages(_ doc: MuDoc, _ options: FlattenOptions, appearancesReady: Bool = false, cancel: CancelToken? = nil,
                             beforeChange: () throws -> Void = {}) throws -> Bool {
        let catalog = doc.catalog
        let acro = catalog.dict("AcroForm")
        var removed = Set<UInt>()
        var removedKeys: [Int] = []
        var widgets: [PObj] = []
        var pagesTouched = false
        let pages = try doc.pages()

        for page in pages {
            try cancel.check()
            guard page.array("Annots") != nil else { continue }
            let annots = doc.annots(page) // the page's own array, if pages share one
            var take: [PObj] = []
            for a in annots.elements where a.isDict {
                let flatten: Bool
                switch a.name("Subtype") {
                case "Widget":
                    flatten = options.formFields && (options.signatureFields || FormEditor.inherited(a, "FT")?.name != "Sig")
                case "Link": flatten = options.links
                default: flatten = options.annotations
                }
                if flatten { take.append(a) }
            }
            if take.isEmpty { continue }
            if !pagesTouched {
                try beforeChange()
                if options.formFields, !appearancesReady, let acro { try FormEditor.ensureAppearances(doc, acro) }
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
        if !pagesTouched { return false }

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
        return true
    }

    /// How an annotation shows on screen, read the way MuPDF 1.25 draws it (pdf_process_annot after the appearances it
    /// makes up when a page loads), and so how flattening draws it: one rule for both, so a flattened page shows what
    /// the screen does, never more or less.
    enum Look {
        /// MuPDF draws nothing, and neither does flattening: a link or popup; marked Invisible, Hidden or NoView; a
        /// widget of no field (no /FT or /T); a /Rect without width or height.
        case nothing
        /// Its own appearance (a form XObject), mapped onto its /Rect by `toRect` (ISO 32000-2 12.5.5's matrix A).
        case own(PObj, toRect: Affine)
        /// MuPDF draws something flattening can't: an appearance it makes up (none of the annotation's own, an
        /// /AS state its appearances lack, an unsigned signature's "sign here" box), or one that can't be fitted to
        /// the /Rect (a box without width or height, numbers that aren't).
        case madeUp
    }

    static func look(_ annot: PObj) -> Look {
        let subtype = annot.name("Subtype")
        if subtype == "Link" || subtype == "Popup" { return .nothing }
        if (annot.int("F") ?? 0) & (flagInvisible | flagHidden | flagNoView) != 0 { return .nothing }
        let widget = subtype == "Widget"
        if widget && (FormEditor.inherited(annot, "FT") == nil || FormEditor.inherited(annot, "T") == nil) { return .nothing }
        guard let r = annot.array("Rect"), r.count >= 4 else { return .madeUp }
        let rx1 = min(r.num(0), r.num(2)), ry1 = min(r.num(1), r.num(3))
        let rx2 = max(r.num(0), r.num(2)), ry2 = max(r.num(1), r.num(3))
        guard rx1.isFinite, ry1.isFinite, rx2.isFinite, ry2.isFinite else { return .madeUp }
        if rx2 - rx1 <= 1e-6 || ry2 - ry1 <= 1e-6 { return .nothing }
        if widget && FormEditor.inherited(annot, "FT")?.name == "Sig" && !signed(annot) { return .madeUp }
        guard let form = appearance(annot), form.isRef, let bb = form.array("BBox"), bb.count >= 4 else { return .madeUp }
        let (bx1, by1, bx2, by2) = transformedBox(form, bb)
        guard bx1.isFinite, by1.isFinite, bx2.isFinite, by2.isFinite, bx2 - bx1 > 1e-6, by2 - by1 > 1e-6 else { return .madeUp }
        let sx: Double = (rx2 - rx1) / (bx2 - bx1)
        let sy: Double = (ry2 - ry1) / (by2 - by1)
        return .own(form, toRect: Affine(sx, 0, 0, sy, rx1 - bx1 * sx, ry1 - by1 * sy))
    }

    /// A signature field with a signature in it (MuPDF's pdf_signature_is_signed: its value a dictionary, of /Type
    /// /Sig when it says).
    private static func signed(_ widget: PObj) -> Bool {
        guard let v = FormEditor.inherited(widget, "V"), v.isDict else { return false }
        guard let type = v["Type"] else { return true }
        return type.name == "Sig"
    }

    /// Whether MuPDF shows `annot` with an appearance flattening can't draw: a page carrying one prints as a picture
    /// (`PrintCopy`).
    static func showsWithoutAppearance(_ annot: PObj) -> Bool {
        if case .madeUp = look(annot) { return true }
        return false
    }

    /// Whether MuPDF shows anything for `annot` on screen.
    static func shows(_ annot: PObj) -> Bool {
        if case .nothing = look(annot) { return false }
        return true
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

    /// Appends the drawing of `annot`'s normal appearance to `ops`, if it shows as its own (`look`).
    private static func draw(_ doc: MuDoc, _ page: PObj, _ annot: PObj, _ options: FlattenOptions, _ ops: inout String) {
        if options.printableOnly && (annot.int("F") ?? 0) & flagPrint == 0 { return }
        guard case .own(let form, let m) = look(annot) else { return }

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
        ops += "\(PdfNum.f(m.a)) 0 0 \(PdfNum.f(m.d)) \(PdfNum.f(m.tx)) \(PdfNum.f(m.ty)) cm /\(name) Do\nQ\n"
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
            for k in inherited.keys { res.set(k, inherited[k].map { ContentEditor.ownCopy(doc, $0) }) } // its inline /Font, /ExtGState its own
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
