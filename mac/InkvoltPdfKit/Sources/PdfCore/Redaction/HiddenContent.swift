import Foundation

/// Cuts optional content out of a content stream (the Windows app's `HiddenContent`): marked content (/OC /name BDC …
/// EMC) of a hidden layer, and XObjects of a hidden layer (Do). Viewers still apply the graphics state a hidden section
/// sets (PDF 2.0, 8.11.3.2), so its q/Q, transformations, colors, line and text-state settings and clipping paths stay;
/// what it draws (text, paths, images, XObjects, shadings) goes. Inside a text object, text positioning stays; a section
/// that shows text the visible text after it is placed after (no Td/Tm in between) can't be cut without moving that
/// text, so it is kept.
enum HiddenContent {
    private static let state: Set<String> = ["q", "Q", "cm", "w", "J", "j", "M", "d", "ri", "i", "gs", "CS", "cs", "SC", "SCN", "sc", "scn", "G",
                                             "g", "RG", "rg", "K", "k", "Tc", "Tw", "Tz", "TL", "Tf", "Tr", "Ts"]
    private static let textPosition: Set<String> = ["Td", "TD", "Tm", "T*"]
    private static let path: Set<String> = ["m", "l", "c", "v", "y", "h", "re"]
    private static let paint: Set<String> = ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"]
    private static let show: Set<String> = ["Tj", "TJ", "'", "\""]

    /// - Parameters:
    ///   - hiddenTag: whether a /OC property name (without the slash) is a hidden layer.
    ///   - hiddenXObject: whether an XObject name (without the slash) belongs to a hidden layer.
    /// - Returns: the new content (nil when nothing changed), and why some hidden content had to stay (nil when all of it
    ///   went).
    static func strip(_ content: [UInt8], hiddenTag: (String) -> Bool, hiddenXObject: (String) -> Bool) -> (content: [UInt8]?, kept: String?) {
        var kept: String?
        let ops = ContentLexer.parse(content)
        let broken = ops.last?.broken ?? false
        var output: [UInt8] = []
        var copied = 0 // content before this is written
        var changed = false
        var inText = false

        func copy(to end: Int) {
            if end > copied { output += content[copied..<end] }
        }

        var i = 0
        while i < ops.count {
            let op = ops[i]
            defer { i += 1 }
            switch op.name {
            case "BT":
                inText = true
                continue
            case "ET":
                inText = false
                continue
            case "Do" where op.operands.last?.kind == .name && hiddenXObject(op.operands.last!.name):
                copy(to: op.start)
                copied = op.end
                changed = true
                continue
            case "BDC" where op.operands.count >= 2 && op.operands[0].kind == .name && op.operands[0].name == "OC"
                && op.operands[1].kind == .name && hiddenTag(op.operands[1].name):
                break
            default:
                continue
            }

            // A hidden section: from this BDC to its EMC (or to the end).
            var end = -1
            var depth = 1
            var k = i + 1
            while k < ops.count {
                if ops[k].name == "BMC" || ops[k].name == "BDC" {
                    depth += 1
                } else if ops[k].name == "EMC" {
                    depth -= 1
                    if depth == 0 {
                        end = k
                        break
                    }
                }
                k += 1
            }
            if end < 0 && broken {
                kept = "hidden content runs into data that can't be read"
                continue
            }
            let last = end < 0 ? ops.count : end
            guard let plan = section(ops, i + 1, last, inText) else {
                kept = "hidden content can't be cut without moving visible text"
                continue
            }
            if inText && plan.showsText && !nextTextRepositions(ops, last + 1) {
                kept = "hidden text can't be cut without moving the visible text after it"
                continue
            }
            copy(to: op.start)
            for part in plan.keep {
                if let text = part.text {
                    output += Array(text.utf8)
                } else {
                    output += content[part.start..<part.end]
                }
                output.append(10)
            }
            copied = end < 0 ? content.count : ops[end].end
            changed = true
            i = last
        }
        if !changed { return (nil, kept) }
        copy(to: content.count)
        return (output, kept)
    }

    private struct Plan {
        var keep: [(start: Int, end: Int, text: String?)]
        var showsText: Bool
    }

    /// What of ops [from, to) stays: graphics state, clipping paths, and (inside an open text object) text positioning.
    private static func section(_ ops: [COp], _ from: Int, _ to: Int, _ inText: Bool) -> Plan? {
        var keep: [(start: Int, end: Int, text: String?)] = []
        var pathOps: [(start: Int, end: Int, text: String?)] = []
        var clip = false
        var ownText = false // a text object that starts (and ends) inside the section
        var shows = false
        for k in stride(from: from, to: to, by: 1) {
            let op = ops[k]
            let name = op.name
            if name == "BT" {
                if inText || ownText { return nil }
                ownText = true
                continue
            }
            if name == "ET" {
                if !ownText { return nil } // closes the text object the section started in
                ownText = false
                continue
            }
            if state.contains(name) {
                keep.append((op.start, op.end, nil))
            } else if path.contains(name) || name == "W" || name == "W*" {
                if name == "W" || name == "W*" { clip = true }
                pathOps.append((op.start, op.end, nil))
            } else if paint.contains(name) {
                if clip {
                    keep += pathOps
                    keep.append((0, 0, "n"))
                }
                pathOps.removeAll()
                clip = false
            } else if inText && !ownText {
                if textPosition.contains(name) {
                    keep.append((op.start, op.end, nil))
                } else if name == "'" {
                    keep.append((0, 0, "T*"))
                    shows = true
                } else if name == "\"" && op.operands.count >= 3 {
                    keep.append((0, 0, "\(ContentLexer.number(op.n(0))) Tw \(ContentLexer.number(op.n(1))) Tc T*"))
                    shows = true
                } else if show.contains(name) {
                    shows = true
                }
            }
        }
        if ownText { return nil } // a text object left open
        return Plan(keep: keep, showsText: shows)
    }

    /// Whether the visible text after a cut section starts from a new position (or the text object ends) before it shows
    /// anything.
    private static func nextTextRepositions(_ ops: [COp], _ from: Int) -> Bool {
        for k in stride(from: from, to: ops.count, by: 1) {
            switch ops[k].name {
            case "Tj", "TJ": return false
            case "Td", "TD", "Tm", "T*", "'", "\"", "ET", "BT": return true
            default: continue
            }
        }
        return true
    }
}
