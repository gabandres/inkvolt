import Foundation

/// The accessibility report (`AccessibilityReport`) as one self-contained web page: no scripts, no files beside it,
/// accessible itself (language set, headings in order, tables with header cells and captions, a skip link, colors with
/// enough contrast in light and dark mode, and words, not color alone, for each result).
public enum AccessibilityReportHtml {
    /// The report's file name beside `displayName` ("Annual report accessibility.html").
    public static func fileName(for displayName: String) -> String {
        (displayName as NSString).deletingPathExtension + " accessibility.html"
    }

    /// - Parameters:
    ///   - fileName: the checked file's name, for the title.
    ///   - done: the person's checks ticked as done (`HumanCheck.id`).
    public static func write(_ report: AccessibilityReport, _ fileName: String, checkedAt: Date, done: Set<String> = []) -> String {
        func e(_ s: String) -> String { InventoryReportFiles.encode(s) }
        var counts: [String: Int] = [:]
        for f in report.failures { counts[f.condition, default: 0] += 1 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMMM yyyy, HH:mm"
        let date = f.string(from: checkedAt)
        let checks = report.humanChecks

        var sb = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        sb += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        sb += "<meta name=\"generator\" content=\"Inkvolt PDF\">\n"
        sb += "<title>Accessibility report: " + e(fileName) + "</title>\n<style>\n" + css + "</style>\n</head>\n<body>\n"
        sb += "<a class=\"skip\" href=\"#main\">Skip to the result</a>\n"
        sb += "<header>\n<h1>Accessibility report</h1>\n<p class=\"file\">" + e(fileName) + "</p>\n"
        sb += "<p>Checked on " + e(date) + " by Inkvolt PDF against the machine-checkable conditions of the Matterhorn Protocol 1.1, "
        sb += "which spells out PDF/UA-1 (ISO 14289-1). "
        sb += (report.pages == 1 ? "1 page" : "\(report.pages) pages") + (report.tagged ? ", tagged." : ", not tagged.") + "</p>\n</header>\n"
        sb += "<nav aria-label=\"Sections\">\n<ul>\n<li><a href=\"#result\">Result</a></li>\n"
        sb += report.passed ? "" : "<li><a href=\"#failures\">What fails</a></li>\n"
        sb += "<li><a href=\"#person\">Checks for a person</a></li>\n<li><a href=\"#conditions\">Every condition</a></li>\n"
        sb += report.notes.isEmpty ? "" : "<li><a href=\"#notes\">Not checked</a></li>\n"
        sb += "</ul>\n</nav>\n<main id=\"main\">\n"

        // Result
        sb += "<section aria-labelledby=\"result\">\n<h2 id=\"result\">Result</h2>\n<p class=\"verdict " + (report.passed ? "pass" : "fail") + "\"><strong>"
        sb += (report.passed ? "Passes the machine checks." : "Fails.") + "</strong> " + e(report.summary) + "</p>\n"
        let ticked = checks.filter { done.contains($0.id) }.count
        sb += "<p>Checks for a person: \(ticked) of \(checks.count) done. "
        sb += "A document is accessible only when it passes the machine checks and a person has made these checks.</p>\n</section>\n"

        // What fails, by checkpoint
        if !report.passed {
            sb += "<section aria-labelledby=\"failures\">\n<h2 id=\"failures\">What fails (\(report.failures.count))</h2>\n"
            var groups: [(key: String, findings: [AccessibilityFinding])] = []
            for f in report.failures {
                let key = AccessibilityCheck.condition(f.condition)?.checkpoint ?? "00"
                if let at = groups.firstIndex(where: { $0.key == key }) {
                    groups[at].findings.append(f)
                } else {
                    groups.append((key, [f]))
                }
            }
            for group in groups {
                let title = AccessibilityCheck.checkpoints[group.key] ?? ""
                let heading = group.key == "00" ? title : "Checkpoint \(group.key): \(title)"
                let id = "cp" + group.key
                sb += "<h3 id=\"" + id + "\">" + e(heading) + "</h3>\n<table aria-labelledby=\"" + id + "\">\n<thead><tr>"
                sb += "<th scope=\"col\">Condition</th><th scope=\"col\">Where</th><th scope=\"col\">What</th><th scope=\"col\">What's wrong</th><th scope=\"col\">How to fix it</th>"
                sb += "</tr></thead>\n<tbody>\n"
                for f in group.findings {
                    sb += "<tr><th scope=\"row\">" + e(f.condition) + "</th><td>" + e(f.place) + "</td><td>" + e(f.element)
                    sb += "</td><td>" + e(f.problem) + "</td><td>" + e(f.fix) + "</td></tr>\n"
                }
                sb += "</tbody>\n</table>\n"
            }
            sb += "</section>\n"
        }

        // The person's checklist
        sb += "<section aria-labelledby=\"person\">\n<h2 id=\"person\">Checks for a person (\(checks.count))</h2>\n"
        sb += "<p>The machine can't tell whether these make sense. Each was "
        sb += "marked done or not done in Inkvolt PDF when this report was saved.</p>\n<ul class=\"checklist\">\n"
        for h in checks {
            let ok = done.contains(h.id)
            sb += "<li class=\"" + (ok ? "done" : "todo") + "\"><span class=\"mark\" aria-hidden=\"true\">" + (ok ? "&#x2611;" : "&#x2610;")
            sb += "</span> <strong>" + e(h.question) + "</strong> <span class=\"state\">(" + (ok ? "done" : "not done yet") + ")</span>"
            sb += "<br>" + e(h.how) + " <span class=\"ids\">Matterhorn " + e(h.conditions.joined(separator: ", ")) + "</span></li>\n"
        }
        sb += "</ul>\n</section>\n"

        // Every condition
        sb += "<section aria-labelledby=\"conditions\">\n<h2 id=\"conditions\">Every condition</h2>\n"
        sb += "<p>The Matterhorn Protocol's 137 failure conditions, and PDF/UA's basic rules (marked UA), with what this check found for each.</p>\n"
        sb += "<table aria-labelledby=\"conditions\">\n<thead><tr><th scope=\"col\">Condition</th><th scope=\"col\">Checkpoint</th><th scope=\"col\">Fails when</th><th scope=\"col\">Result</th></tr></thead>\n<tbody>\n"
        for c in AccessibilityCheck.conditions {
            let css: String, result: String
            switch c.how {
            case .machine:
                if let n = counts[c.id] {
                    (css, result) = ("fail", n == 1 ? "Fails (1 problem)" : "Fails (\(n) problems)")
                } else {
                    (css, result) = ("pass", "Passes")
                }
            case .human: (css, result) = ("human", "For a person to check")
            case .notChecked: (css, result) = ("none", c.note ?? "Not checked")
            case .noTest: (css, result) = ("none", "No test of its own")
            }
            sb += "<tr class=\"" + css + "\"><th scope=\"row\">" + e(c.id) + "</th><td>"
            sb += e(AccessibilityCheck.checkpoints[c.checkpoint] ?? c.checkpoint) + "</td><td>" + e(c.text)
            sb += "</td><td>" + e(result) + "</td></tr>\n"
        }
        sb += "</tbody>\n</table>\n</section>\n"

        if !report.notes.isEmpty {
            sb += "<section aria-labelledby=\"notes\">\n<h2 id=\"notes\">Not checked in this file</h2>\n<ul>\n"
            for n in report.notes { sb += "<li>" + e(n) + "</li>\n" }
            sb += "</ul>\n</section>\n"
        }
        sb += "</main>\n<footer>\n<p>Made by Inkvolt PDF. The checks run on this computer; nothing was sent anywhere. "
        sb += "Condition numbers are the Matterhorn Protocol 1.1's (PDF Association).</p>\n</footer>\n</body>\n</html>\n"
        return sb
    }

    private static let css = """
    :root { color-scheme: light dark; --fg: #1b1b1b; --bg: #ffffff; --muted: #4a4a4a; --line: #c8c8c8; --fail: #a4000f; --pass: #0b6a0b; --head: #f2f2f2; --link: #0b57d0; }
    @media (prefers-color-scheme: dark) { :root { --fg: #ececec; --bg: #161616; --muted: #bdbdbd; --line: #4a4a4a; --fail: #ff8a8a; --pass: #7fd87f; --head: #262626; --link: #8ab4f8; } }
    body { font: 16px/1.5 "Segoe UI", system-ui, sans-serif; color: var(--fg); background: var(--bg); max-width: 72rem; margin: 0 auto; padding: 1rem 1.5rem 3rem; }
    a { color: var(--link); }
    a:focus-visible, :focus-visible { outline: 3px solid var(--link); outline-offset: 2px; }
    .skip { position: absolute; left: -999px; }
    .skip:focus { left: 1rem; top: 1rem; background: var(--bg); padding: .5rem 1rem; z-index: 1; }
    h1 { font-size: 1.8rem; margin: .5rem 0 0; }
    h2 { font-size: 1.4rem; margin-top: 2.2rem; border-bottom: 1px solid var(--line); padding-bottom: .2rem; }
    h3 { font-size: 1.15rem; margin-top: 1.6rem; }
    .file { font-size: 1.1rem; font-weight: 600; margin: .2rem 0; word-break: break-all; }
    nav ul { list-style: none; padding: 0; display: flex; flex-wrap: wrap; gap: .4rem 1.4rem; }
    .verdict { font-size: 1.1rem; padding: .7rem 1rem; border-left: 6px solid; }
    .verdict.pass { border-color: var(--pass); } .verdict.fail { border-color: var(--fail); }
    table { border-collapse: collapse; width: 100%; margin: .5rem 0 1rem; }
    th, td { border: 1px solid var(--line); padding: .4rem .55rem; text-align: left; vertical-align: top; }
    thead th { background: var(--head); }
    tbody th { white-space: nowrap; font-weight: 600; }
    tr.fail td:last-child { color: var(--fail); font-weight: 600; }
    tr.pass td:last-child { color: var(--pass); }
    tr.human td:last-child, tr.none td:last-child { color: var(--muted); }
    .checklist { list-style: none; padding: 0; }
    .checklist li { margin: 0 0 .9rem; }
    .mark { font-size: 1.2rem; }
    .state, .ids { color: var(--muted); }
    .ids { font-size: .9rem; }
    footer { margin-top: 3rem; color: var(--muted); font-size: .9rem; }
    @media print { nav, .skip { display: none; } body { max-width: none; } }

    """
}
