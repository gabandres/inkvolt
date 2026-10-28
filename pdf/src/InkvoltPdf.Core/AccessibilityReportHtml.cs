using System.Globalization;
using System.Net;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>
/// The accessibility report (<see cref="AccessibilityReport"/>) as one self-contained web page: no scripts, no files beside
/// it, accessible itself (language set, headings in order, tables with header cells and captions, a skip link, colors with
/// enough contrast in light and dark mode, and words, not color alone, for each result).
/// </summary>
public static class AccessibilityReportHtml
{
    /// <param name="fileName">The checked file's name, for the title.</param>
    /// <param name="done">The person's checks ticked as done (<see cref="HumanCheck.Id"/>).</param>
    public static string Write(AccessibilityReport report, string fileName, DateTime checkedAt, IReadOnlySet<string>? done = null)
    {
        done ??= new HashSet<string>();
        var sb = new StringBuilder();
        string E(string s) => WebUtility.HtmlEncode(s);
        var counts = report.Failures.GroupBy(f => f.Condition).ToDictionary(g => g.Key, g => g.Count());
        var date = checkedAt.ToString("d MMMM yyyy, HH:mm", CultureInfo.InvariantCulture);

        sb.Append("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n")
          .Append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
          .Append("<meta name=\"generator\" content=\"Inkvolt PDF\">\n")
          .Append("<title>Accessibility report: ").Append(E(fileName)).Append("</title>\n<style>\n").Append(Css).Append("</style>\n</head>\n<body>\n")
          .Append("<a class=\"skip\" href=\"#main\">Skip to the result</a>\n")
          .Append("<header>\n<h1>Accessibility report</h1>\n<p class=\"file\">").Append(E(fileName)).Append("</p>\n")
          .Append("<p>Checked on ").Append(E(date)).Append(" by Inkvolt PDF against the machine-checkable conditions of the Matterhorn Protocol 1.1, ")
          .Append("which spells out PDF/UA-1 (ISO 14289-1). ")
          .Append(report.Pages == 1 ? "1 page" : $"{report.Pages} pages").Append(report.Tagged ? ", tagged." : ", not tagged.").Append("</p>\n</header>\n")
          .Append("<nav aria-label=\"Sections\">\n<ul>\n<li><a href=\"#result\">Result</a></li>\n")
          .Append(report.Passed ? "" : "<li><a href=\"#failures\">What fails</a></li>\n")
          .Append("<li><a href=\"#person\">Checks for a person</a></li>\n<li><a href=\"#conditions\">Every condition</a></li>\n")
          .Append(report.Notes.Count > 0 ? "<li><a href=\"#notes\">Not checked</a></li>\n" : "")
          .Append("</ul>\n</nav>\n<main id=\"main\">\n");

        // Result
        sb.Append("<section aria-labelledby=\"result\">\n<h2 id=\"result\">Result</h2>\n<p class=\"verdict ").Append(report.Passed ? "pass" : "fail").Append("\"><strong>")
          .Append(report.Passed ? "Passes the machine checks." : "Fails.").Append("</strong> ").Append(E(report.Summary)).Append("</p>\n");
        var ticked = report.HumanChecks.Count(h => done.Contains(h.Id));
        sb.Append("<p>Checks for a person: ").Append(ticked).Append(" of ").Append(report.HumanChecks.Count).Append(" done. ")
          .Append("A document is accessible only when it passes the machine checks and a person has made these checks.</p>\n</section>\n");

        // What fails, by checkpoint
        if (!report.Passed)
        {
            sb.Append("<section aria-labelledby=\"failures\">\n<h2 id=\"failures\">What fails (").Append(report.Failures.Count).Append(")</h2>\n");
            foreach (var group in report.Failures.GroupBy(f => AccessibilityCheck.Condition(f.Condition)?.Checkpoint ?? "00"))
            {
                var title = AccessibilityCheck.Checkpoints.GetValueOrDefault(group.Key, "");
                var heading = group.Key == "00" ? title : $"Checkpoint {group.Key}: {title}";
                var id = "cp" + group.Key;
                sb.Append("<h3 id=\"").Append(id).Append("\">").Append(E(heading)).Append("</h3>\n<table aria-labelledby=\"").Append(id).Append("\">\n<thead><tr>")
                  .Append("<th scope=\"col\">Condition</th><th scope=\"col\">Where</th><th scope=\"col\">What</th><th scope=\"col\">What's wrong</th><th scope=\"col\">How to fix it</th>")
                  .Append("</tr></thead>\n<tbody>\n");
                foreach (var f in group)
                    sb.Append("<tr><th scope=\"row\">").Append(E(f.Condition)).Append("</th><td>").Append(E(f.Where)).Append("</td><td>").Append(E(f.Element))
                      .Append("</td><td>").Append(E(f.Problem)).Append("</td><td>").Append(E(f.Fix)).Append("</td></tr>\n");
                sb.Append("</tbody>\n</table>\n");
            }
            sb.Append("</section>\n");
        }

        // The person's checklist
        sb.Append("<section aria-labelledby=\"person\">\n<h2 id=\"person\">Checks for a person (").Append(report.HumanChecks.Count).Append(")</h2>\n")
          .Append("<p>The machine can't tell whether these make sense. Each was ")
          .Append("marked done or not done in Inkvolt PDF when this report was saved.</p>\n<ul class=\"checklist\">\n");
        foreach (var h in report.HumanChecks)
        {
            var ok = done.Contains(h.Id);
            sb.Append("<li class=\"").Append(ok ? "done" : "todo").Append("\"><span class=\"mark\" aria-hidden=\"true\">").Append(ok ? "&#x2611;" : "&#x2610;")
              .Append("</span> <strong>").Append(E(h.Question)).Append("</strong> <span class=\"state\">(").Append(ok ? "done" : "not done yet").Append(")</span>")
              .Append("<br>").Append(E(h.How)).Append(" <span class=\"ids\">Matterhorn ").Append(E(string.Join(", ", h.Conditions))).Append("</span></li>\n");
        }
        sb.Append("</ul>\n</section>\n");

        // Every condition
        sb.Append("<section aria-labelledby=\"conditions\">\n<h2 id=\"conditions\">Every condition</h2>\n")
          .Append("<p>The Matterhorn Protocol's 137 failure conditions, and PDF/UA's basic rules (marked UA), with what this check found for each.</p>\n")
          .Append("<table aria-labelledby=\"conditions\">\n<thead><tr><th scope=\"col\">Condition</th><th scope=\"col\">Checkpoint</th><th scope=\"col\">Fails when</th><th scope=\"col\">Result</th></tr></thead>\n<tbody>\n");
        foreach (var c in AccessibilityCheck.Conditions)
        {
            var (css, result) = c.How switch
            {
                ConditionCheck.Machine when counts.TryGetValue(c.Id, out var n) => ("fail", n == 1 ? "Fails (1 problem)" : $"Fails ({n} problems)"),
                ConditionCheck.Machine => ("pass", "Passes"),
                ConditionCheck.Human => ("human", "For a person to check"),
                ConditionCheck.NotChecked => ("none", c.Note ?? "Not checked"),
                _ => ("none", "No test of its own"),
            };
            sb.Append("<tr class=\"").Append(css).Append("\"><th scope=\"row\">").Append(E(c.Id)).Append("</th><td>")
              .Append(E(AccessibilityCheck.Checkpoints.GetValueOrDefault(c.Checkpoint, c.Checkpoint))).Append("</td><td>").Append(E(c.Text))
              .Append("</td><td>").Append(E(result)).Append("</td></tr>\n");
        }
        sb.Append("</tbody>\n</table>\n</section>\n");

        if (report.Notes.Count > 0)
        {
            sb.Append("<section aria-labelledby=\"notes\">\n<h2 id=\"notes\">Not checked in this file</h2>\n<ul>\n");
            foreach (var n in report.Notes) sb.Append("<li>").Append(E(n)).Append("</li>\n");
            sb.Append("</ul>\n</section>\n");
        }
        sb.Append("</main>\n<footer>\n<p>Made by Inkvolt PDF. The checks run on this computer; nothing was sent anywhere. ")
          .Append("Condition numbers are the Matterhorn Protocol 1.1's (PDF Association).</p>\n</footer>\n</body>\n</html>\n");
        return sb.ToString();
    }

    private const string Css = """
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

        """;
}
