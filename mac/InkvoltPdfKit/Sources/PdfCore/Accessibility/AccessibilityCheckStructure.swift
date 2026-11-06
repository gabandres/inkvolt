import Foundation
import PrintCore

extension AccessibilityCheck {
    /// The standard structure types of ISO 32000-1, 14.8.4 (what PDF/UA-1 tags must be, or map to).
    static let standardTypes: Set<String> = [
        "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index", "NonStruct", "Private",
        "P", "H", "H1", "H2", "H3", "H4", "H5", "H6", "L", "LI", "Lbl", "LBody", "Table", "TR", "TH", "TD", "THead", "TBody", "TFoot",
        "Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Annot", "Ruby", "RB", "RT", "RP", "Warichu", "WT", "WP",
        "Figure", "Formula", "Form",
    ]
}

/// A structure element (tag) as the check sees it.
final class AccessibilityElem {
    let dict: PObj
    /// Its /S, without the slash.
    let type: String
    /// The standard type it is or maps to; nil when it maps to none.
    var std: String?
    let parent: AccessibilityElem?
    var kids: [AccessibilityElem] = []
    /// Every kid in order: an element, a marked-content id or an object reference (for the Form rule).
    var kidCount = 0
    var objects: [PObj] = []
    /// Its /Pg (index), or -1.
    var page = -1
    /// Where its own marked content is drawn (filled by the content walk).
    var content: [(page: Int, box: RectD)] = []

    init(_ dict: PObj, _ type: String, _ parent: AccessibilityElem?) {
        self.dict = dict
        self.type = type
        self.parent = parent
    }

    /// The type to compare with: the standard one, else its own.
    var kind: String { std ?? type }
}

extension AccessibilityChecker {
    static let maxElements = 500_000, maxDepth = 256
    /// Places a table's grid may add or write (about 64 MB). Spans can ask for 5,000 rows of a million columns; no real table comes near.
    static let maxTablePlaces = 16_000_000

    func pageOf(_ pg: PObj?) -> Int {
        guard let pg else { return -1 }
        if pg.isRef, let n = pageByNumber[pg.num] { return n }
        return pg.isDict ? pageByIdentity[pg.identity] ?? -1 : -1
    }

    func readStructure() throws {
        guard let root else { return }
        if let roles = root.dict("RoleMap") {
            for key in roles.keys {
                if let to = roles.name(key) { roleMap[key] = to }
            }
        }
        classMap = root.dict("ClassMap")
        for (key, value) in PdfStructure.numberTree(root.dict("ParentTree")).prefix(2_000_000) where parentTree[key] == nil {
            parentTree[key] = value
        }

        // The tree in reading order, on an explicit stack (a crafted file nests to the depth limit).
        struct Level {
            var parent: AccessibilityElem?
            var items: [PObj]
            var next = 0
            var depth: Int
        }
        func kids(_ k: PObj?) -> [PObj] {
            guard let k else { return [] }
            return k.isArray ? k.elements : [k]
        }
        var stack = [Level(parent: nil, items: kids(root["K"]), depth: 0)]
        var visits = 0
        while !stack.isEmpty {
            let top = stack.count - 1
            guard stack[top].next < stack[top].items.count else {
                stack.removeLast()
                continue
            }
            let item = stack[top].items[stack[top].next]
            stack[top].next += 1
            let (parent, depth) = (stack[top].parent, stack[top].depth)
            visits += 1
            if visits & 4095 == 0 { try cancel.check() }

            if item.kind == .int || item.kind == .real {
                if !item.isRef { parent?.kidCount += 1 } // (an indirect number isn't a marked-content id on Windows either)
                continue
            }
            guard item.isDict else { continue }
            let type = item.name("Type")
            if type == "MCR" {
                parent?.kidCount += 1
            } else if type == "OBJR" {
                guard let parent else { continue }
                parent.kidCount += 1
                if let obj = item.dict("Obj") { parent.objects.append(obj) }
            } else if item.has("S"), depth < Self.maxDepth, elems.count < Self.maxElements, elems[item.identity] == nil {
                let e = AccessibilityElem(item, item.name("S") ?? "", parent)
                elems[item.identity] = e
                ordered.append(e)
                e.std = mapRole(e.type).std
                e.page = item.has("Pg") ? pageOf(item["Pg"]) : parent?.page ?? -1
                if let parent {
                    parent.kids.append(e)
                    parent.kidCount += 1
                }
                stack.append(Level(parent: e, items: kids(item["K"]), depth: depth + 1))
            } else if item.has("S"), elems[item.identity] == nil {
                noteOnce(loc("The document's tags are too many or too deeply nested; the rest weren't checked."))
            }
        }
    }

    enum Mapping { case standard, mapped, remapped, circular, unmapped }

    /// The standard type `type` is or maps to (nil: none), and how it got there.
    func mapRole(_ type: String) -> (std: String?, how: Mapping) {
        let standard = AccessibilityCheck.standardTypes
        var seen: Set<String> = [type]
        if standard.contains(type) {
            // A standard type in the role map: remapped, unless the map leads back to it (Div → Div is a circle).
            var how = Mapping.standard
            var s = type
            while how == .standard, let to = roleMap[s] {
                how = to == type || !seen.insert(to).inserted ? .circular : standard.contains(to) ? .remapped : .standard
                s = to
            }
            if how == .standard && roleMap[type] != nil { how = .remapped }
            return (type, how)
        }
        var t = type
        while let next = roleMap[t] {
            if standard.contains(next) { return (next, .mapped) }
            if !seen.insert(next).inserted || seen.count > 32 { return (nil, .circular) }
            t = next
        }
        return (nil, .unmapped)
    }

    // MARK: Where an element is

    /// The page an element is on and its box there: from its marked content (its own, else its kids'), else its /Pg.
    func locate(_ e: AccessibilityElem) -> (page: Int, box: RectD) {
        var stack = [e]
        var page = -1, visited = 0
        var box = RectD.zero
        while let x = stack.popLast(), visited < 5000 {
            visited += 1
            for (p, b) in x.content {
                if page < 0 { page = p }
                if p == page { box = box.union(b) }
            }
            if page >= 0 && visited > 64 { break }
            stack.append(contentsOf: x.kids.reversed())
        }
        if page >= 0 { return (page, box) }
        if e.page >= 0 { return (e.page, .zero) }
        for o in e.objects {
            let n = pageOf(o["P"])
            if n >= 0 { return (n, o.array("Rect").map { PageBoxes.rectToPage(pageObjects[n], $0) } ?? .zero) }
        }
        return (-1, .zero)
    }

    static func label(_ e: AccessibilityElem) -> String {
        guard let std = e.std else { return loc("Tag “{0}”", e.type) }
        return std == e.type ? describe(std) : loc("{0} (tagged “{1}”)", describe(std), e.type)
    }

    static func describe(_ std: String) -> String {
        switch std {
        case "H": return loc("Heading")
        case "P": return loc("Paragraph")
        case "L": return loc("List")
        case "LI": return loc("List item")
        case "LBody": return loc("List item body")
        case "Lbl": return loc("List label")
        case "TR": return loc("Table row")
        case "TH": return loc("Table header cell")
        case "TD": return loc("Table cell")
        case "THead": return loc("Table header group")
        case "TBody": return loc("Table body")
        case "TFoot": return loc("Table footer group")
        case "TOC": return loc("Table of contents")
        case "TOCI": return loc("Contents item")
        default:
            let u = Array(std.utf8)
            return u.count == 2 && u[0] == 72 && (48...57).contains(u[1]) ? loc("Heading {0}", std) : std
        }
    }

    /// "this table header group"…: the start of a sentence about a table part (Windows' `ThisPart`).
    static func thisPart(_ std: String) -> String {
        switch std {
        case "THead": loc("this table header group")
        case "TBody": loc("this table body")
        case "TFoot": loc("this table footer group")
        case "TH": loc("this table header cell")
        default: loc("this table cell")
        }
    }

    func addAt(_ e: AccessibilityElem, _ condition: String, _ problem: @autoclosure () -> String) {
        // Past the limit only the count is kept, so a crafted tree of 500,000 such tags isn't searched 500,000 times.
        let (page, box) = full(condition) ? (-1, RectD.zero) : locate(e)
        add(condition, problem(), page: page, box: box, element: Self.label(e))
    }

    static func hasLang(_ e: AccessibilityElem?) -> Bool {
        var e = e
        var depth = 0
        while let x = e, depth < maxDepth {
            if x.dict.has("Lang") { return true }
            e = x.parent
            depth += 1
        }
        return false
    }

    /// An attribute of the element (its /A, then its classes in the class map), owned by `owner` ("Table").
    func attribute(_ e: AccessibilityElem, _ owner: String, _ key: String) -> PObj? {
        func find(_ a: PObj?) -> PObj? {
            guard let a else { return nil }
            if a.isDict { return a.name("O") == owner ? a[key] : nil }
            guard a.isArray else { return nil }
            for item in a.elements where item.isDict {
                if let v = find(item) { return v }
            }
            return nil
        }
        if let own = find(e.dict["A"]) { return own }
        guard let classMap, let c = e.dict["C"] else { return nil }
        let classes = c.kind == .name ? [c.name].compactMap { $0 } : c.elements.compactMap(\.name)
        for name in classes {
            if let v = find(classMap[name]) { return v }
        }
        return nil
    }

    // MARK: The checks

    func checkStructure() throws {
        var noteIds = Set<String>()
        var roleReported = Set<String>()
        var firstH: AccessibilityElem?, firstHn: AccessibilityElem?
        var lastLevel = 0
        for (index, e) in ordered.enumerated() {
            if index & 1023 == 0 { try cancel.check() }
            if !e.dict.has("P") { addAt(e, "UA 7.1-P", loc("This tag has no link to its parent tag (no P entry).")) }
            if let lang = Self.text(e.dict["Lang"]), !AccessibilityCheck.isLanguage(lang) {
                addAt(e, "UA 7.2-Lang", loc("This tag's language is “{0}”, which isn't a language code.", Self.short(lang)))
            }

            switch mapRole(e.type).how {
            case .remapped where roleReported.insert("02-004 " + e.type).inserted:
                addAt(e, "02-004", loc("The standard type {0} is mapped to {1} in the role map.", e.type, roleMap[e.type] ?? ""))
            case .circular where roleReported.insert("02-003 " + e.type).inserted:
                addAt(e, "02-003", loc("The role map sends the type “{0}” round in a circle.", e.type))
            case .unmapped where roleReported.insert("02-001 " + e.type).inserted:
                addAt(e, "02-001", e.type.isEmpty ? loc("A tag has no type (no S entry).") : loc("The tag type “{0}” isn't standard and isn't mapped to a standard type.", e.type))
            default:
                break
            }

            if !docLang && !Self.hasLang(e) {
                var which: [String] = []
                if e.dict.has("Alt") { which.append(loc("alternate text")) }
                if e.dict.has("ActualText") { which.append(loc("actual text")) }
                if e.dict.has("E") { which.append(loc("expansion text")) }
                if let last = which.last {
                    let texts = which.count == 1 ? last : loc("{0} and {1}", which.dropLast().joined(separator: ", "), last)
                    addAt(e, "11-002", loc("This tag's {0} has no language, and neither the tags around it nor the document have one.", texts))
                }
            }

            let kids = e.kids.map(\.kind)
            switch e.std {
            case "Figure":
                if !Self.hasText(e.dict, "Alt") && !e.dict.has("ActualText") { addAt(e, "13-004", loc("This figure has no alternate text, so a screen reader can't say what it shows.")) }
            case "Formula":
                if !Self.hasText(e.dict, "Alt") && !e.dict.has("ActualText") { addAt(e, "17-002", loc("This formula has no alternate text, so a screen reader can't read it out.")) }
            case "Note":
                let id = Self.text(e.dict["ID"]) ?? ""
                if id.isEmpty {
                    addAt(e, "19-003", loc("This note has no ID."))
                } else if !noteIds.insert(id).inserted {
                    addAt(e, "19-004", loc("This note's ID “{0}” is used by another note too.", Self.short(id)))
                }
            case "Table":
                table(e, kids)
            case "TR":
                if !["Table", "THead", "TBody", "TFoot"].contains(e.parent?.kind ?? "") { addAt(e, "09-004", loc("This table row isn't inside a table, or a table's header, body or footer group.")) }
                if kids.contains(where: { $0 != "TH" && $0 != "TD" }) { addAt(e, "09-004", loc("This table row holds {0}; a row may hold only TH and TD cells.", Self.others(kids, "TH", "TD"))) }
            case "THead", "TBody", "TFoot":
                let this = Self.thisPart(e.kind)
                if e.parent?.kind != "Table" { addAt(e, "09-004", Self.cap(loc("{0} isn't directly inside a table.", this))) }
                if kids.contains(where: { $0 != "TR" }) { addAt(e, "09-004", Self.cap(loc("{0} holds {1}; it may hold only rows (TR).", this, Self.others(kids, "TR")))) }
            case "TH", "TD":
                if e.parent?.kind != "TR" { addAt(e, "09-004", Self.cap(loc("{0} isn't inside a table row (TR).", Self.thisPart(e.kind)))) }
            case "L":
                if kids.contains(where: { !["L", "LI", "Caption"].contains($0) }) {
                    addAt(e, "09-005", loc("This list holds {0}; a list may hold only list items (LI), lists and a caption.", Self.others(kids, "L", "LI", "Caption")))
                }
                if kids.dropFirst().contains("Caption") { addAt(e, "09-005", loc("This list's caption isn't its first part.")) }
            case "LI":
                if e.parent?.kind != "L" { addAt(e, "09-005", loc("This list item isn't inside a list (L).")) }
                if kids.contains(where: { $0 != "Lbl" && $0 != "LBody" }) {
                    addAt(e, "09-005", loc("This list item holds {0}; a list item may hold only a label (Lbl) and a body (LBody).", Self.others(kids, "Lbl", "LBody")))
                }
            case "LBody":
                if e.parent?.kind != "LI" { addAt(e, "09-005", loc("This list item body (LBody) isn't inside a list item (LI).")) }
            case "TOC":
                if kids.contains(where: { !["TOC", "TOCI", "Caption"].contains($0) }) {
                    addAt(e, "09-006", loc("This table of contents holds {0}; it may hold only contents items (TOCI), nested contents and a caption.", Self.others(kids, "TOC", "TOCI", "Caption")))
                }
                if kids.dropFirst().contains("Caption") { addAt(e, "09-006", loc("This table of contents' caption isn't its first part.")) }
            case "TOCI":
                if e.parent?.kind != "TOC" { addAt(e, "09-006", loc("This contents item (TOCI) isn't inside a table of contents (TOC).")) }
            case "Form":
                let holdsItsField = e.kidCount == 1 && e.objects.count == 1 && e.objects[0].name("Subtype") == "Widget"
                if attribute(e, "PrintField", "Role") == nil && !holdsItsField {
                    addAt(e, "28-010", loc("This Form tag holds more than its form field (or no form field): without a Role attribute it must hold just the field."))
                }
            case "H":
                if firstH == nil { firstH = e }
            default:
                if let h = e.std, h.utf8.count == 2, h.hasPrefix("H"), let level = Int(h.dropFirst()), (1...6).contains(level) {
                    if firstHn == nil { firstHn = e }
                    if level > lastLevel + 1 {
                        if lastLevel == 0 {
                            addAt(e, "14-002", loc("The first numbered heading is {0}, not H1.", h))
                        } else {
                            let skipped = (lastLevel + 1..<level).map { "H\($0)" }.joined(separator: ", ")
                            addAt(e, "14-003", loc("This {0} heading follows an H{1}: heading level {2} is skipped.", h, CoreLanguage.number(lastLevel), skipped))
                        }
                    }
                    lastLevel = level
                }
            }
            let headings = kids.filter { $0 == "H" }.count
            if headings > 1 { addAt(e, "14-006", loc("This tag holds {0} H headings; a tag may hold one.", CoreLanguage.number(headings))) }
        }
        if let firstH, firstHn != nil { addAt(firstH, "14-007", loc("The document uses H headings and numbered headings (H1-H6) both.")) }
    }

    /// "a P and a Span": the kinds in `kids` other than `allowed`.
    static func others(_ kids: [String], _ allowed: String...) -> String {
        var seen = Set<String>()
        var list: [String] = []
        for k in kids where !allowed.contains(k) && seen.insert(k).inserted {
            list.append(k.isEmpty ? loc("an untyped tag") : loc("a {0}", k))
            if list.count == 3 { break }
        }
        switch list.count {
        case 0: return loc("nothing else")
        case 1: return list[0]
        default: return loc("{0} and {1}", list.dropLast().joined(separator: ", "), list[list.count - 1])
        }
    }

    private func table(_ table: AccessibilityElem, _ kids: [String]) {
        func count(_ kind: String) -> Int { kids.filter { $0 == kind }.count }
        if kids.contains(where: { !["TR", "THead", "TBody", "TFoot", "Caption"].contains($0) }) {
            addAt(table, "09-004", loc("This table holds {0}; a table may hold only rows (TR), header, body and footer groups and a caption.", Self.others(kids, "TR", "THead", "TBody", "TFoot", "Caption")))
        }
        if count("THead") > 1 { addAt(table, "09-004", loc("This table has more than one header group (THead).")) }
        if count("TFoot") > 1 { addAt(table, "09-004", loc("This table has more than one footer group (TFoot).")) }
        if (count("THead") > 0 || count("TFoot") > 0) && count("TBody") == 0 {
            addAt(table, "09-004", loc("This table has a header or footer group but no body group (TBody)."))
        }
        if count("Caption") > 1 {
            addAt(table, "09-004", loc("This table has more than one caption."))
        } else if kids.count > 2 && kids.dropFirst().dropLast().contains("Caption") {
            addAt(table, "09-004", loc("This table's caption is neither its first nor its last part."))
        }

        // The cells on a grid, spans taken into account.
        var rows: [AccessibilityElem] = []
        for k in table.kids {
            if k.kind == "TR" {
                rows.append(k)
            } else if ["THead", "TBody", "TFoot"].contains(k.kind) {
                rows += k.kids.filter { $0.kind == "TR" }
            }
        }
        if rows.isEmpty || rows.count > 5000 { return }
        // A place on the grid holds its cell's index in `placed`, or -1.
        var grid = [[Int32]](repeating: [], count: rows.count)
        var placed: [(cell: AccessibilityElem, row: Int, column: Int)] = []
        var overlap = false, spanPast = false
        var places = 0
        for r in 0..<rows.count {
            var c = 0
            if rows[r].kids.lazy.filter({ $0.kind == "TH" || $0.kind == "TD" }).count > 1000 {
                noteOnce(loc("A table's row has more than 1,000 cells; only the first 1,000 were compared."))
            }
            for cell in rows[r].kids.lazy.filter({ $0.kind == "TH" || $0.kind == "TD" }).prefix(1000) {
                while c < grid[r].count && grid[r][c] >= 0 { c += 1 }
                let rs = min(max(attribute(cell, "Table", "RowSpan")?.int ?? 1, 1), 1000)
                let cs = min(max(attribute(cell, "Table", "ColSpan")?.int ?? 1, 1), 1000)
                if r + rs > rows.count { spanPast = true }
                placed.append((cell, r, c))
                for dr in 0..<rs where r + dr < rows.count {
                    // What this adds (the empty places left of a span too) and what it writes (over other cells too).
                    places += max(0, c + cs - grid[r + dr].count) + cs
                    if places > Self.maxTablePlaces {
                        let note = loc("A table's rows and columns are too many to lay out; its cells weren't compared.")
                        if !notes.contains(note) { notes.append(note) }
                        return
                    }
                    if grid[r + dr].count < c + cs { grid[r + dr] += [Int32](repeating: -1, count: c + cs - grid[r + dr].count) }
                    for dc in 0..<cs {
                        if grid[r + dr][c + dc] >= 0 { overlap = true }
                        grid[r + dr][c + dc] = Int32(placed.count - 1)
                    }
                }
                c += cs
            }
        }
        if overlap { addAt(table, "09-004", loc("Cells of this table overlap (their row and column spans cover the same place).")) }
        let widths = grid.map { row in row.reduce(0) { $1 >= 0 ? $0 + 1 : $0 } }
        let distinct = Array(Set(widths)).sorted()
        if spanPast {
            addAt(table, "09-004", loc("A cell of this table spans more rows than the table has."))
        } else if distinct.count > 1 {
            addAt(table, "09-004", loc("The rows of this table don't have the same number of cells (spans counted): {0}.", distinct.prefix(4).map { String($0) }.joined(separator: ", ")))
        }

        // Headers (Matterhorn 15-003): in a table that doesn't tie its data cells to header cells through Headers and IDs,
        // every header cell needs a scope. Checked on regular tables only (an irregular one already fails above).
        if overlap || spanPast || distinct.count > 1 { return }
        let headerCells = placed.map { $0.cell }.filter { $0.kind == "TH" }
        let unscoped = headerCells.filter { attribute($0, "Table", "Scope") == nil }.count
        if unscoped == 0 { return }
        var ids = Set<String>()
        for th in headerCells {
            if let id = Self.text(th.dict["ID"]), !id.isEmpty { ids.insert(id) }
        }
        var unlinked = 0, unknown = 0
        for (cell, r, c) in placed {
            if cell.kind != "TD" || (r == 0 && c == 0) { continue }
            if let headers = attribute(cell, "Table", "Headers"), headers.isArray, headers.count > 0 {
                if headers.elements.contains(where: { h in Self.text(h).map { !ids.contains($0) } ?? true }) { unknown += 1 }
            } else {
                unlinked += 1
            }
        }
        if unlinked + unknown == 0 { return }
        let cells: String
        if unlinked > 0 {
            cells = unlinked == 1 ? loc("{0} data cell don't name their header cells (Headers)", CoreLanguage.number(unlinked)) : loc("{0} data cells don't name their header cells (Headers)", CoreLanguage.number(unlinked))
        } else {
            cells = unknown == 1 ? loc("{0} data cell name header cells the table doesn't have", CoreLanguage.number(unknown)) : loc("{0} data cells name header cells the table doesn't have", CoreLanguage.number(unknown))
        }
        let problem = unscoped == 1
            ? loc("{0} header cell of this table has no scope, and {1}, so a screen reader can't tell which header goes with which cell.", CoreLanguage.number(unscoped), cells)
            : loc("{0} header cells of this table have no scope, and {1}, so a screen reader can't tell which header goes with which cell.", CoreLanguage.number(unscoped), cells)
        addAt(table, "15-003", problem)
    }
}
