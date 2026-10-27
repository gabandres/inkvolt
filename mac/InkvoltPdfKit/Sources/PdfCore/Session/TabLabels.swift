import Foundation

/// The captions of open tabs. A tab shows its file name, or the document's title when the file asks for it; when two
/// tabs would read the same, each gets what tells it apart: its file name when the title isn't that, else (or when the
/// file names clash too) its folder ("report.pdf · 2026").
public enum TabLabels {
    public static func labels(_ tabs: [(title: String, path: String?)]) -> [String] {
        var labels = tabs.map(\.title)
        func same(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        func name(_ i: Int) -> String? { tabs[i].path.map { ($0 as NSString).lastPathComponent } }
        func folder(_ i: Int) -> String? {
            tabs[i].path.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }
        }
        var grouped: [String: [Int]] = [:]
        var order: [String] = []
        for i in tabs.indices {
            let key = tabs[i].title.lowercased()
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(i)
        }
        for key in order {
            let members = grouped[key]!
            if members.count < 2 { continue }
            for i in members {
                var hints: [String] = []
                if let n = name(i), !same(n, tabs[i].title) { hints.append(n) }
                let nameTellsApart = !hints.isEmpty && members.filter { same(name($0), name(i)) }.count == 1
                if !nameTellsApart, let f = folder(i), !f.isEmpty, f != "/" { hints.append(f) }
                if !hints.isEmpty { labels[i] = ([tabs[i].title] + hints).joined(separator: " · ") }
            }
        }
        return labels
    }
}
