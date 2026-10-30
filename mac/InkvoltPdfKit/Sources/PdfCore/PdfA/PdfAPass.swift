import Foundation

extension PdfA {
    /// The conversion's walk over the document (Windows' `PdfA.Pass`): fixes what can be fixed in place and collects the
    /// blockers.
    final class Pass {
        let doc: MuDoc
        private(set) var changes: [String]
        private(set) var blockers: [String] = []
        private var removedAnnots = 0, hiddenAnnots = 0, actions = 0, aa = 0, images = 0, lzw = 0, tr = 0, ocNames = 0
        private(set) var embedded = 0
        private let pages: [PObj]
        /// Pages' content streams and Type 3 glyph procedures, by identity (form XObjects and tiling patterns are told by
        /// their entries).
        private var contents = Set<UInt>()

        init(_ doc: MuDoc, _ changes: [String]) throws {
            self.doc = doc
            self.changes = changes
            pages = try doc.pages()
        }

        func run() throws {
            let catalog = doc.catalog
            catalog.remove("AA")
            catalog.remove("NeedsRendering")
            catalog.remove("Perms")
            if let acro = catalog.dict("AcroForm") {
                acro.remove("XFA")
                try FormEditor.ensureAppearances(doc, acro)
                acro.remove("NeedAppearances")
            }
            for page in pages {
                page.remove("AA")
                page.remove("PresSteps")
                annotations(page)
            }

            // Everything reachable from the catalog (what a validator reads), each object once.
            walk(catalog) { visit($0) }
            fonts()
            optionalContent(catalog)
            outputIntent(catalog)

            if removedAnnots > 0 {
                changes.append("\(count(removedAnnots, "comment or field", "comments and fields")) that PDF/A doesn't allow, or without an appearance, removed")
            }
            if hiddenAnnots > 0 { changes.append("\(count(hiddenAnnots, "hidden comment", "hidden comments")) removed") }
            if actions + aa > 0 { changes.append("\(count(actions + aa, "action", "actions")) PDF/A doesn't allow removed") }
            if images > 0 { changes.append("smoothing and alternate versions PDF/A doesn't allow taken off \(count(images, "picture", "pictures"))") }
            if lzw > 0 { changes.append("\(count(lzw, "LZW stream", "LZW streams")) re-compressed") }
            if tr > 0 { changes.append("transfer and halftone functions removed") }
            if embedded > 0 { changes.append("\(count(embedded, "standard font", "standard fonts")) embedded") }
            if ocNames > 0 { changes.append("layer configurations named") }
            changes.append("sRGB output intent and PDF/A metadata added")
        }

        /// Annotations PDF/A forbids or that wouldn't show are removed; the rest print, and keep only their normal appearance.
        private func annotations(_ page: PObj) {
            guard let annots = page.array("Annots") else { return }
            for i in stride(from: annots.count - 1, through: 0, by: -1) {
                guard let a = annots[i], a.isDict else {
                    annots.remove(at: i)
                    continue
                }
                let subtype = a.name("Subtype") ?? ""
                let flags = a.int("F") ?? 0
                if removedAnnotations.contains(subtype) {
                    annots.remove(at: i)
                    removedAnnots += 1
                    continue
                }
                if subtype != "Popup" && flags & (flagHidden | flagNoView) != 0 {
                    annots.remove(at: i)
                    hiddenAnnots += 1
                    continue
                }
                let zero = PdfA.zeroRect(a.array("Rect"))
                let ap = a.dict("AP")
                ap?.remove("R")
                ap?.remove("D")
                let hasNormal = ap?["N"] != nil
                if !hasNormal && subtype != "Popup" && subtype != "Link" && !zero {
                    if subtype == "Widget" {
                        blockers.append("A form field has no appearance of its own, so it can't be shown the same everywhere.")
                        continue
                    }
                    annots.remove(at: i)
                    removedAnnots += 1
                    continue
                }
                if !hasNormal && ap != nil { a.remove("AP") }
                // Every annotation prints and shows (popups too: their flags are only for the pop-up window).
                a.set("F", doc.int((flags | flagPrint) & ~(flagInvisible | flagHidden | flagNoView | flagToggleNoView)))
            }
        }

        /// Checks and fixes one dictionary (or stream) by what it is.
        private func visit(_ d: PObj) {
            if d.has("AA") {
                d.remove("AA")
                aa += 1
            }
            for key in ["A", "OpenAction", "PA"] {
                if let action = d.dict(key), Self.isForbidden(action) {
                    d.remove(key)
                    actions += 1
                }
            }
            if let next = d["Next"] {
                if next.isDict && Self.isForbidden(next) {
                    d.remove("Next")
                    actions += 1
                } else if next.isArray {
                    for i in stride(from: next.count - 1, through: 0, by: -1) {
                        if let x = next[i], x.isDict, Self.isForbidden(x) {
                            next.remove(at: i)
                            actions += 1
                        }
                    }
                }
            }

            let subtype = d.name("Subtype")
            let type = d.name("Type")
            if d.isStream {
                if d.has("F") && (d.has("FFilter") || type == nil && subtype == nil && !d.has("Length")) {
                    blockers.append("It refers to content in another file (an external stream).")
                }
                reencodeLzw(d)
            }
            switch subtype {
            case "Image":
                var changed = false
                for key in ["Alternates", "OPI"] where d.has(key) {
                    d.remove(key)
                    changed = true
                }
                if let i = d["Interpolate"], i.kind == .bool, i.bool {
                    d.set("Interpolate", doc.bool(false))
                    changed = true
                }
                if let intent = d.name("Intent"), !["AbsoluteColorimetric", "RelativeColorimetric", "Saturation", "Perceptual"].contains(intent) {
                    d.remove("Intent")
                    changed = true
                }
                if changed { images += 1 }
            case "PS":
                blockers.append("It holds PostScript code (a PostScript XObject), which PDF/A doesn't allow.")
            case "Form":
                d.remove("OPI")
                d.remove("Ref")
                if d.name("Subtype2") == "PS" { blockers.append("It holds PostScript code (a PostScript XObject), which PDF/A doesn't allow.") }
            default:
                break
            }
            if type == "ExtGState" || d.has("TR") || d.has("HTP") {
                var changed = false
                for key in ["TR", "HTP"] where d.has(key) {
                    d.remove(key)
                    changed = true
                }
                if let tr2 = d["TR2"], tr2.kind != .name || tr2.name != "Default" {
                    d.remove("TR2")
                    changed = true
                }
                if changed { tr += 1 }
            }
            if type == "FontDescriptor" {
                d.remove("CIDSet")
                d.remove("CharSet")
            }
            checkColor(d)
        }

        static func isForbidden(_ action: PObj) -> Bool {
            guard let s = action.name("S") else { return false }
            if action.has("K") || action.has("P") && !action.has("Type") { return false } // a structure element
            return forbiddenActions.contains(s) || s == "Named" && !allowedNamed.contains(action.name("N") ?? "")
        }

        private func reencodeLzw(_ d: PObj) {
            let filter = d["Filter"]
            let names = filter?.isArray == true ? filter!.elements.map { $0.name ?? "" } : [filter?.name ?? ""]
            guard names.contains(where: { $0 == "LZWDecode" || $0 == "LZW" }), let decoded = d.streamData else { return }
            d.remove("DP")
            d.setStream(decoded, deflate: true) // /FlateDecode, its /DecodeParms gone
            lzw += 1
        }

        /// CMYK color can't be shown under an RGB output intent without a CMYK profile, which isn't at hand.
        private func checkColor(_ d: PObj) {
            for key in ["ColorSpace", "CS"] {
                guard let cs = d[key] else { continue }
                if key == "ColorSpace" && cs.isDict {
                    for k in cs.keys where Self.usesCmyk(cs[k]) { cmykBlocker() }
                } else if Self.usesCmyk(cs) {
                    cmykBlocker()
                }
            }
            if d.isStream && isContent(d) { scanContent(d) }
        }

        /// Page contents, form XObjects, tiling patterns and Type 3 glyphs (pages' /Contents are marked when walked).
        private func isContent(_ d: PObj) -> Bool {
            contents.contains(d.identity) || d.name("Subtype") == "Form" || d.int("PatternType") == 1
        }

        private func scanContent(_ d: PObj) {
            guard let bytes = d.streamData, let ops = try? ContentLexer.parse(bytes, cancel: nil) else { return }
            func names(_ op: COp, _ wanted: Set<String>) -> Bool { op.operands.contains { $0.kind == .name && wanted.contains($0.name) } }
            for op in ops {
                let setsCmyk = op.name == "k" || op.name == "K"
                let last = op.operands.last
                let cmykSpace = (op.name == "cs" || op.name == "CS") && last?.kind == .name && last?.name == "DeviceCMYK"
                if setsCmyk || cmykSpace || op.name == "BI" && names(op, ["CMYK", "DeviceCMYK"]) {
                    cmykBlocker()
                    return
                }
                if op.name == "BI" && names(op, ["LZW", "LZWDecode"]) {
                    blockers.append("An inline picture is LZW-compressed, which PDF/A doesn't allow.")
                    return
                }
            }
        }

        func block(_ why: String) { blockers.append(why) }

        func noteEmbedded() { embedded += 1 }

        private func cmykBlocker() {
            blockers.append("It uses CMYK color without a color profile; a PDF/A-2b copy here gets an RGB (sRGB) output intent, so that color can't be kept as it is.")
        }

        static func usesCmyk(_ cs: PObj?, depth: Int = 0) -> Bool {
            guard let cs, depth < 8 else { return false }
            if cs.kind == .name { return cs.name == "DeviceCMYK" || cs.name == "CMYK" }
            guard cs.isArray, cs.count > 0 else { return false }
            switch cs[0]?.name {
            case "Indexed", "I": return cs.count > 1 && usesCmyk(cs[1], depth: depth + 1)
            case "Separation", "DeviceN": return cs.count > 2 && usesCmyk(cs[2], depth: depth + 1)
            case "Pattern": return cs.count > 1 && usesCmyk(cs[1], depth: depth + 1)
            default: return false
            }
        }

        /// Calls `body` on every dictionary reachable from `root`, each once, before its entries are followed (so what it
        /// removes isn't walked); pages' content streams and Type 3 glyphs are marked as content.
        func walk(_ root: PObj, _ body: (PObj) -> Void) {
            for page in pages {
                guard let c = page["Contents"] else { continue }
                if c.isArray {
                    for s in c.elements where s.isDict { contents.insert(s.identity) }
                } else if c.isDict {
                    contents.insert(c.identity)
                }
            }
            var seen = Set<UInt>()
            var stack = [root]
            while let item = stack.popLast() {
                guard item.isDict || item.isArray, seen.insert(item.identity).inserted else { continue }
                if item.isArray {
                    for e in item.elements where e.isDict || e.isArray { stack.append(e) }
                    continue
                }
                body(item)
                if let procs = item.dict("CharProcs") {
                    for k in procs.keys { if let p = procs[k], p.isDict { contents.insert(p.identity) } }
                }
                for key in item.keys where key != "Parent" && key != "P" {
                    if let v = item[key], v.isDict || v.isArray { stack.append(v) }
                }
            }
        }

        // ───────────── optional content, output intent ─────────────

        private func optionalContent(_ catalog: PObj) {
            guard let oc = catalog.dict("OCProperties") else { return }
            var configs: [PObj] = []
            if let d = oc.dict("D") { configs.append(d) }
            configs += oc.array("Configs")?.elements.filter(\.isDict) ?? []
            var names = Set<String>()
            for (i, c) in configs.enumerated() {
                if c.has("AS") {
                    c.remove("AS")
                    ocNames += 1
                }
                var name = c.text("Name") ?? ""
                if name.isEmpty || !names.insert(name).inserted {
                    name = i == 0 ? "Default" : "Configuration \(i + 1)"
                    while !names.insert(name).inserted { name += " (2)" }
                    c.set("Name", doc.text(name))
                    ocNames += 1
                }
            }
        }

        private func outputIntent(_ catalog: PObj) {
            let profile = doc.addStream(IccProfiles.srgb(), dict: doc.dict([("N", doc.int(3))]), deflate: true)
            let intent = doc.add(doc.dict([
                ("Type", doc.name("OutputIntent")),
                ("S", doc.name("GTS_PDFA1")),
                ("OutputConditionIdentifier", doc.text("sRGB IEC61966-2.1")),
                ("RegistryName", doc.text("http://www.color.org")),
                ("Info", doc.text("sRGB IEC61966-2.1")),
                ("DestOutputProfile", profile),
            ]))
            catalog.set("OutputIntents", doc.array([intent]))
        }
    }

    /// A /Rect that is missing or has no width or height.
    static func zeroRect(_ rect: PObj?) -> Bool {
        guard let rect else { return true }
        return abs(rect.num(2) - rect.num(0)) < 1e-6 || abs(rect.num(3) - rect.num(1)) < 1e-6
    }
}
