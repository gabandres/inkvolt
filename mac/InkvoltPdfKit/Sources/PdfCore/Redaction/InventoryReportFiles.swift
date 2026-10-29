import Foundation

/// The "What's in this PDF" report (`InventoryReport`) as a self-contained web page (no scripts, no files beside it,
/// accessible: language, headings in order, tables with header cells, light and dark colors with enough contrast, words
/// and not color alone) or as JSON (fields always in the same order, for scripts and diffs). The Windows app's
/// `InventoryReportFiles`.
public enum InventoryReportFiles {
    /// The JSON format's marker and version.
    public static let jsonFormat = "inkvolt-pdf-inventory"
    public static let jsonVersion = 1

    /// - Parameter fileName: the file's name, for the title.
    public static func html(_ report: InventoryReport, _ fileName: String, madeAt: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMMM yyyy, HH:mm"
        let date = f.string(from: madeAt)
        let pages = report.pages == 1 ? "1 page." : "\(DocumentInventory.n0(report.pages)) pages."

        var sb = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        sb += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        sb += "<meta name=\"generator\" content=\"Inkvolt PDF\">\n"
        sb += "<title>What's in this PDF: " + encode(fileName) + "</title>\n<style>\n" + css + "</style>\n</head>\n<body>\n"
        sb += "<a class=\"skip\" href=\"#main\">Skip to the summary</a>\n"
        sb += "<header>\n<h1>What's in this PDF</h1>\n<p class=\"file\">" + encode(fileName) + "</p>\n"
        sb += "<p>Looked at on " + encode(date) + " by Inkvolt PDF. " + pages
        sb += " Everything the file carries besides what its pages show, and what it does when it is opened.</p>\n</header>\n"
        sb += "<nav aria-label=\"Sections\">\n<ul>\n<li><a href=\"#summary\">Summary</a></li>\n"
        for s in InventorySection.allCases where report.items.contains(where: { $0.section == s }) {
            sb += "<li><a href=\"#" + s.id + "\">" + encode(DocumentInventory.title(s)) + "</a></li>\n"
        }
        sb += "<li><a href=\"#sanitize\">What Sanitize removes</a></li>\n"
        if !report.notes.isEmpty { sb += "<li><a href=\"#notes\">Not looked at</a></li>\n" }
        sb += "</ul>\n</nav>\n<main id=\"main\">\n"

        sb += "<section aria-labelledby=\"summary\">\n<h2 id=\"summary\">Summary</h2>\n<p class=\"verdict " + (report.isEmpty ? "clean" : "found") + "\">"
        sb += encode(report.summary) + "</p>\n</section>\n"

        for s in InventorySection.allCases {
            let items = report.items(in: s)
            if items.isEmpty { continue }
            sb += section(s, items)
        }

        sb += "<section aria-labelledby=\"sanitize\">\n<h2 id=\"sanitize\">What Sanitize removes</h2>\n"
        sb += "<p>Review › Sanitize Document removes these kinds and rewrites the file as one version.</p>\n<table aria-labelledby=\"sanitize\">\n"
        sb += "<thead><tr><th scope=\"col\">Kind</th><th scope=\"col\">Found</th></tr></thead>\n<tbody>\n"
        for (item, label, _) in kinds {
            sb += "<tr><th scope=\"row\">" + encode(label) + "</th><td>" + DocumentInventory.n0(report.counts[item]) + "</td></tr>\n"
        }
        sb += "<tr><th scope=\"row\">Earlier versions</th><td>" + DocumentInventory.n0(report.counts.earlierRevisions) + "</td></tr>\n"
        sb += "<tr><th scope=\"row\">Objects nothing uses</th><td>" + DocumentInventory.n0(report.counts.unusedObjects) + "</td></tr>\n"
        sb += "</tbody>\n</table>\n</section>\n"

        if !report.notes.isEmpty {
            sb += "<section aria-labelledby=\"notes\">\n<h2 id=\"notes\">Not looked at</h2>\n<ul>\n"
            for n in report.notes { sb += "<li>" + encode(n) + "</li>\n" }
            sb += "</ul>\n</section>\n"
        }
        sb += "</main>\n<footer>\n<p>Made by Inkvolt PDF on this computer; nothing was sent anywhere, and no address in the file was contacted.</p>\n</footer>\n</body>\n</html>\n"
        return sb
    }

    /// One section's table.
    private static func section(_ s: InventorySection, _ items: [InventoryItem]) -> String {
        let id = s.id
        let trigger = s == .scripts || s == .actions || s == .addresses
        var sb = "<section aria-labelledby=\"" + id + "\">\n<h2 id=\"" + id + "\">" + encode(DocumentInventory.title(s))
        sb += " (" + DocumentInventory.n0(items.count) + ")</h2>\n<table aria-labelledby=\"" + id + "\">\n<thead><tr>"
        sb += "<th scope=\"col\">What</th><th scope=\"col\">Where</th>" + (trigger ? "<th scope=\"col\">Runs</th>" : "")
        sb += "<th scope=\"col\">Found</th></tr></thead>\n<tbody>\n"
        for i in items {
            sb += "<tr" + (i.withoutClick ? " class=\"auto\"" : "") + "><th scope=\"row\">" + encode(i.what) + "</th><td>" + encode(i.place) + "</td>"
            if trigger {
                sb += "<td>" + encode(DocumentInventory.name(i.trigger)) + (i.withoutClick ? " <strong>(no click needed)</strong>" : "") + "</td>"
            }
            sb += "<td><code>" + encode(i.detail) + "</code>"
            if !i.calls.isEmpty { sb += "<br><span class=\"calls\">It " + encode(i.calls.joined(separator: ", ")) + ".</span>" }
            sb += "</td></tr>\n"
        }
        return sb + "</tbody>\n</table>\n</section>\n"
    }

    public static func json(_ report: InventoryReport, _ fileName: String, madeAt: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        var w = "{\n"
        w += "  \"format\": " + quote(jsonFormat) + ",\n"
        w += "  \"version\": \(jsonVersion),\n"
        w += "  \"file\": " + quote(fileName) + ",\n"
        w += "  \"madeAt\": " + quote(f.string(from: madeAt)) + ",\n"
        w += "  \"pages\": \(report.pages),\n"
        w += "  \"summary\": " + quote(report.summary) + ",\n"
        w += "  \"items\": [" + (report.items.isEmpty ? "" : "\n")
        for (n, i) in report.items.enumerated() {
            w += item(i) + (n == report.items.count - 1 ? "\n  " : ",\n")
        }
        w += "],\n  \"sanitizeFinds\": {\n"
        for (item, _, key) in kinds { w += "    \"\(key)\": \(report.counts[item]),\n" }
        w += "    \"earlierVersions\": \(report.counts.earlierRevisions),\n"
        w += "    \"unusedObjects\": \(report.counts.unusedObjects)\n  },\n"
        w += "  \"notes\": [" + report.notes.map { "\n    " + quote($0) }.joined(separator: ",") + (report.notes.isEmpty ? "" : "\n  ") + "]\n"
        return w + "}\n"
    }

    private static func item(_ i: InventoryItem) -> String {
        let runs: String
        switch i.trigger {
        case .automatic: runs = "automatic"
        case .pointer: runs = "pointer"
        case .use: runs = "use"
        case .none: runs = "none"
        }
        var w = "    {\n"
        w += "      \"section\": " + quote(i.section.id) + ",\n"
        w += "      \"what\": " + quote(i.what) + ",\n"
        w += "      \"where\": " + quote(i.place) + ",\n"
        w += "      \"found\": " + quote(i.detail) + ",\n"
        w += "      \"page\": " + (i.page >= 0 ? "\(i.page + 1)" : "null") + ",\n"
        w += "      \"runs\": " + quote(runs) + ",\n"
        w += "      \"withoutClick\": " + (i.withoutClick ? "true" : "false") + ",\n"
        w += "      \"calls\": [" + i.calls.map(quote).joined(separator: ", ") + "],\n"
        w += "      \"sanitizeRemoves\": " + (i.removedBy.map { quote(key($0)) } ?? "null") + "\n"
        return w + "    }"
    }

    /// A JSON string: quotes, backslashes and control characters escaped; other characters as they are (UTF-8).
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// Text for a web page: &, <, >, " and ' as entities.
    static func encode(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Each kind's name in JSON ("hiddenLayers").
    static func key(_ item: SanitizeItem) -> String { kinds.first { $0.item == item }?.key ?? "\(item)" }

    private static let kinds: [(item: SanitizeItem, label: String, key: String)] = [
        (.metadata, "Metadata", "metadata"),
        (.hiddenLayers, "Hidden layers", "hiddenLayers"),
        (.hiddenAnnotations, "Hidden comments and fields", "hiddenAnnotations"),
        (.comments, "Comments, markup, stamps and drawings", "comments"),
        (.formValues, "Form values", "formValues"),
        (.bookmarks, "Bookmarks", "bookmarks"),
        (.thumbnails, "Page thumbnails", "thumbnails"),
        (.activeContent, "Scripts and active content", "activeContent"),
        (.externalLinks, "Links to web pages and other files", "externalLinks"),
        (.embeddedFiles, "Attached files", "embeddedFiles"),
        (.signatures, "Digital signatures", "signatures"),
    ]

    private static let css = """
        :root { color-scheme: light dark; --fg: #1b1b1b; --bg: #ffffff; --muted: #4a4a4a; --line: #c8c8c8; --warn: #8a4b00; --ok: #0b6a0b; --head: #f2f2f2; --link: #0b57d0; }
        @media (prefers-color-scheme: dark) { :root { --fg: #ececec; --bg: #161616; --muted: #bdbdbd; --line: #4a4a4a; --warn: #ffb35c; --ok: #7fd87f; --head: #262626; --link: #8ab4f8; } }
        body { font: 16px/1.5 -apple-system, "Segoe UI", system-ui, sans-serif; color: var(--fg); background: var(--bg); max-width: 72rem; margin: 0 auto; padding: 1rem 1.5rem 3rem; }
        a { color: var(--link); }
        a:focus-visible, :focus-visible { outline: 3px solid var(--link); outline-offset: 2px; }
        .skip { position: absolute; left: -999px; }
        .skip:focus { left: 1rem; top: 1rem; background: var(--bg); padding: .5rem 1rem; z-index: 1; }
        h1 { font-size: 1.8rem; margin: .5rem 0 0; }
        h2 { font-size: 1.4rem; margin-top: 2.2rem; border-bottom: 1px solid var(--line); padding-bottom: .2rem; }
        .file { font-size: 1.1rem; font-weight: 600; margin: .2rem 0; word-break: break-all; }
        nav ul { list-style: none; padding: 0; display: flex; flex-wrap: wrap; gap: .4rem 1.4rem; }
        .verdict { font-size: 1.1rem; padding: .7rem 1rem; border-left: 6px solid; }
        .verdict.clean { border-color: var(--ok); } .verdict.found { border-color: var(--warn); }
        table { border-collapse: collapse; width: 100%; margin: .5rem 0 1rem; }
        th, td { border: 1px solid var(--line); padding: .4rem .55rem; text-align: left; vertical-align: top; }
        thead th { background: var(--head); }
        tbody th { font-weight: 600; }
        code { font: .92rem/1.4 ui-monospace, "SF Mono", "Cascadia Mono", Consolas, monospace; white-space: pre-wrap; word-break: break-word; }
        tr.auto td strong { color: var(--warn); }
        .calls { color: var(--muted); }
        footer { margin-top: 3rem; color: var(--muted); font-size: .9rem; }
        @media print { nav, .skip { display: none; } body { max-width: none; } }

        """
}
