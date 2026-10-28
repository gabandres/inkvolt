import Foundation

extension FormEditor {
    /// Empties the fields that have one of `widgets` (by identity) everywhere: the value is removed where it lives (the
    /// field, and any ancestor whose /V it inherits, with every field sharing it), check boxes and radio buttons are
    /// turned off, text and choice fields get fresh (empty) appearances, and the XFA form, which keeps its own copy of
    /// every value, goes (the Windows app's `FormEditor.ClearFields`). False when none of the widgets is a field's.
    static func clearFields(_ doc: MuDoc, _ widgets: Set<UInt>) throws -> Bool {
        let acro = doc.catalog.dict("AcroForm")
        let fields = try collect(doc, acro)

        func chain(_ d: PObj) -> [PObj] {
            var out: [PObj] = []
            var n: PObj? = d
            while let cur = n, out.count < 64 {
                out.append(cur)
                n = cur.dict("Parent")
            }
            return out
        }

        // Where the values live: the hit fields, and any ancestor whose /V they inherit.
        var holders: [UInt: PObj] = [:]
        for f in fields where f.widgets.contains(where: { widgets.contains($0.identity) }) {
            for n in chain(f.dict) where n.identity == f.dict.identity || n.has("V") { holders[n.identity] = n }
        }
        if holders.isEmpty { return false }

        let cleared = fields.filter { chain($0.dict).contains { holders[$0.identity] != nil } }
        for n in Array(holders.values) + cleared.flatMap(\.widgets) {
            for key in ["V", "RV", "I"] { n.remove(key) }
        }
        for f in cleared {
            switch f.type {
            case "Btn" where f.flags & ffPushButton == 0:
                f.dict.set("V", doc.name("Off"))
                for w in f.widgets where w.has("AS") || w.has("AP") { w.set("AS", doc.name("Off")) }
            case "Tx", "Ch":
                for w in f.widgets { w.remove("AP") } // a widget whose appearance can't be rebuilt shows nothing
                writeAppearances(doc, acro, f)
            default:
                break
            }
        }
        // XFA datasets keep their own copy of every value.
        acro?.remove("XFA")
        return true
    }
}
