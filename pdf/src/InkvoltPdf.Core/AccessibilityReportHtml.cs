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
        // The page's words in the interface's language (English on the command line), its dates' month names too.
        var date = checkedAt.ToString(PdfStrings.A11y_ReportDateFormat, PdfLanguage.Culture);

        sb.Append("<!DOCTYPE html>\n<html lang=\"").Append(PdfStrings.A11y_ReportLang).Append("\">\n<head>\n<meta charset=\"utf-8\">\n")
          .Append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
          .Append("<meta name=\"generator\" content=\"Inkvolt PDF\">\n")
          .Append("<title>").Append(Loc.Format(PdfStrings.A11y_ReportTitleOf, E(fileName))).Append("</title>\n<style>\n").Append(Css).Append("</style>\n</head>\n<body>\n")
          .Append("<a class=\"skip\" href=\"#main\">").Append(PdfStrings.A11y_ReportSkip).Append("</a>\n")
          .Append("<header>\n<h1>").Append(PdfStrings.A11y_ReportTitle).Append("</h1>\n<p class=\"file\">").Append(E(fileName)).Append("</p>\n")
          .Append("<p>").Append(Loc.Format(PdfStrings.A11y_ReportCheckedOn, E(date)))
          .Append(Loc.Plural(report.Pages, report.Tagged ? PdfStrings.A11y_ReportPagesTagged_One : PdfStrings.A11y_ReportPagesUntagged_One,
                                           report.Tagged ? PdfStrings.A11y_ReportPagesTagged_Many : PdfStrings.A11y_ReportPagesUntagged_Many)).Append("</p>\n</header>\n")
          .Append("<nav aria-label=\"").Append(PdfStrings.A11y_ReportSections).Append("\">\n<ul>\n<li><a href=\"#result\">").Append(PdfStrings.A11y_ReportResult).Append("</a></li>\n")
          .Append(report.Failures.Count == 0 ? "" : "<li><a href=\"#failures\">" + PdfStrings.A11y_ReportWhatFails + "</a></li>\n")
          .Append("<li><a href=\"#person\">").Append(PdfStrings.A11y_ReportPersonChecks).Append("</a></li>\n<li><a href=\"#conditions\">").Append(PdfStrings.A11y_ReportEveryCondition).Append("</a></li>\n")
          .Append(report.Notes.Count > 0 ? "<li><a href=\"#notes\">" + PdfStrings.A11y_ReportNotChecked + "</a></li>\n" : "")
          .Append("</ul>\n</nav>\n<main id=\"main\">\n");

        // Result
        var verdict = report.Outcome switch { AccessibilityOutcome.Passes => "pass", AccessibilityOutcome.NotFullyChecked => "partly", _ => "fail" };
        sb.Append("<section aria-labelledby=\"result\">\n<h2 id=\"result\">").Append(PdfStrings.A11y_ReportResult).Append("</h2>\n<p class=\"verdict ").Append(verdict).Append("\"><strong>")
          .Append(report.Verdict).Append("</strong> ").Append(E(report.Summary)).Append("</p>\n");
        var ticked = report.HumanChecks.Count(h => done.Contains(h.Id));
        sb.Append("<p>").Append(Loc.Format(PdfStrings.A11y_ReportTicked, ticked, report.HumanChecks.Count)).Append("</p>\n</section>\n");

        // What fails, by checkpoint
        if (report.Failures.Count > 0)
        {
            sb.Append("<section aria-labelledby=\"failures\">\n<h2 id=\"failures\">").Append(Loc.Format(PdfStrings.A11y_ReportWhatFailsN, report.Failures.Count)).Append("</h2>\n");
            foreach (var group in report.Failures.GroupBy(f => AccessibilityCheck.Condition(f.Condition)?.Checkpoint ?? "00"))
            {
                var title = AccessibilityCheck.Checkpoints.GetValueOrDefault(group.Key, "");
                var heading = group.Key == "00" ? title : Loc.Format(PdfStrings.A11y_ReportCheckpoint, group.Key, title);
                var id = "cp" + group.Key;
                sb.Append("<h3 id=\"").Append(id).Append("\">").Append(E(heading)).Append("</h3>\n<table aria-labelledby=\"").Append(id).Append("\">\n<thead><tr>")
                  .Append("<th scope=\"col\">").Append(PdfStrings.A11y_ReportColCondition).Append("</th><th scope=\"col\">").Append(PdfStrings.A11y_ReportColWhere)
                  .Append("</th><th scope=\"col\">").Append(PdfStrings.A11y_ReportColWhat).Append("</th><th scope=\"col\">").Append(PdfStrings.A11y_ReportColWrong)
                  .Append("</th><th scope=\"col\">").Append(PdfStrings.A11y_ReportColFix).Append("</th>")
                  .Append("</tr></thead>\n<tbody>\n");
                foreach (var f in group)
                    sb.Append("<tr><th scope=\"row\">").Append(E(f.Condition)).Append("</th><td>").Append(E(f.Where)).Append("</td><td>").Append(E(f.Element))
                      .Append("</td><td>").Append(E(f.Problem)).Append("</td><td>").Append(E(f.Fix)).Append("</td></tr>\n");
                sb.Append("</tbody>\n</table>\n");
            }
            sb.Append("</section>\n");
        }

        // The person's checklist
        sb.Append("<section aria-labelledby=\"person\">\n<h2 id=\"person\">").Append(Loc.Format(PdfStrings.A11y_ReportPersonChecksN, report.HumanChecks.Count)).Append("</h2>\n")
          .Append("<p>").Append(PdfStrings.A11y_ReportPersonIntro).Append("</p>\n<ul class=\"checklist\">\n");
        foreach (var h in report.HumanChecks)
        {
            var ok = done.Contains(h.Id);
            sb.Append("<li class=\"").Append(ok ? "done" : "todo").Append("\"><span class=\"mark\" aria-hidden=\"true\">").Append(ok ? "&#x2611;" : "&#x2610;")
              .Append("</span> <strong>").Append(E(h.Question)).Append("</strong> <span class=\"state\">(").Append(ok ? PdfStrings.A11y_ReportDone : PdfStrings.A11y_ReportNotDone).Append(")</span>")
              .Append("<br>").Append(E(h.How)).Append(" <span class=\"ids\">Matterhorn ").Append(E(string.Join(", ", h.Conditions))).Append("</span></li>\n");
        }
        sb.Append("</ul>\n</section>\n");

        // Every condition
        sb.Append("<section aria-labelledby=\"conditions\">\n<h2 id=\"conditions\">").Append(PdfStrings.A11y_ReportEveryCondition).Append("</h2>\n")
          .Append("<p>").Append(PdfStrings.A11y_ReportConditionsIntro).Append("</p>\n")
          .Append("<table aria-labelledby=\"conditions\">\n<thead><tr><th scope=\"col\">").Append(PdfStrings.A11y_ReportColCondition)
          .Append("</th><th scope=\"col\">").Append(PdfStrings.A11y_ReportColCheckpoint).Append("</th><th scope=\"col\">").Append(PdfStrings.A11y_ReportColFailsWhen)
          .Append("</th><th scope=\"col\">").Append(PdfStrings.A11y_ReportResult).Append("</th></tr></thead>\n<tbody>\n");
        foreach (var c in AccessibilityCheck.Conditions)
        {
            var (css, result) = c.How switch
            {
                ConditionCheck.Machine when counts.TryGetValue(c.Id, out var n) => ("fail", Loc.Plural(n, PdfStrings.A11y_ReportFailsN_One, PdfStrings.A11y_ReportFailsN_Many)),
                ConditionCheck.Machine when report.Notes.Count > 0 => ("none", PdfStrings.A11y_ReportNothingFound),
                ConditionCheck.Machine => ("pass", PdfStrings.A11y_ReportPasses),
                ConditionCheck.Human => ("human", PdfStrings.A11y_ReportForPerson),
                ConditionCheck.NotChecked => ("none", c.Note ?? PdfStrings.A11y_ReportNotChecked),
                _ => ("none", PdfStrings.A11y_ReportNoTest),
            };
            sb.Append("<tr class=\"").Append(css).Append("\"><th scope=\"row\">").Append(E(c.Id)).Append("</th><td>")
              .Append(E(AccessibilityCheck.Checkpoints.GetValueOrDefault(c.Checkpoint, c.Checkpoint))).Append("</td><td>").Append(E(c.Text))
              .Append("</td><td>").Append(E(result)).Append("</td></tr>\n");
        }
        sb.Append("</tbody>\n</table>\n</section>\n");

        if (report.Notes.Count > 0)
        {
            sb.Append("<section aria-labelledby=\"notes\">\n<h2 id=\"notes\">").Append(PdfStrings.A11y_ReportNotCheckedHere).Append("</h2>\n<ul>\n");
            foreach (var n in report.Notes) sb.Append("<li>").Append(E(n)).Append("</li>\n");
            sb.Append("</ul>\n</section>\n");
        }
        sb.Append("</main>\n<footer>\n<p>").Append(PdfStrings.A11y_ReportFooter).Append("</p>\n</footer>\n</body>\n</html>\n");
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
        .verdict.pass { border-color: var(--pass); } .verdict.fail { border-color: var(--fail); } .verdict.partly { border-color: var(--muted); }
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
