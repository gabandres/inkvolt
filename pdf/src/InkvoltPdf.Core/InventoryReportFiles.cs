using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;

namespace InkvoltPdf.Core;

/// <summary>
/// The "What's in this PDF" report (<see cref="InventoryReport"/>) as a self-contained web page (no scripts, no files
/// beside it, accessible: language, headings in order, tables with header cells, light and dark colors with enough
/// contrast, words and not color alone) or as JSON (fields always in the same order, for scripts and diffs).
/// </summary>
public static class InventoryReportFiles
{
    /// <summary>The JSON format's marker and version.</summary>
    public const string JsonFormat = "inkvolt-pdf-inventory";
    public const int JsonVersion = 1;

    /// <param name="fileName">The file's name, for the title.</param>
    public static string Html(InventoryReport report, string fileName, DateTime madeAt)
    {
        var sb = new StringBuilder();
        string E(string s) => WebUtility.HtmlEncode(s);
        var date = madeAt.ToString("d MMMM yyyy, HH:mm", CultureInfo.InvariantCulture);
        var sections = Enum.GetValues<InventorySection>();

        sb.Append("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n")
          .Append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
          .Append("<meta name=\"generator\" content=\"Inkvolt PDF\">\n")
          .Append("<title>What's in this PDF: ").Append(E(fileName)).Append("</title>\n<style>\n").Append(Css).Append("</style>\n</head>\n<body>\n")
          .Append("<a class=\"skip\" href=\"#main\">Skip to the summary</a>\n")
          .Append("<header>\n<h1>What's in this PDF</h1>\n<p class=\"file\">").Append(E(fileName)).Append("</p>\n")
          .Append("<p>Looked at on ").Append(E(date)).Append(" by Inkvolt PDF. ").Append(report.Pages == 1 ? "1 page." : $"{report.Pages:N0} pages.")
          .Append(" Everything the file carries besides what its pages show, and what it does when it is opened.</p>\n</header>\n")
          .Append("<nav aria-label=\"Sections\">\n<ul>\n<li><a href=\"#summary\">Summary</a></li>\n");
        foreach (var s in sections)
            if (report.In(s).Any()) sb.Append("<li><a href=\"#").Append(Id(s)).Append("\">").Append(E(DocumentInventory.Title(s))).Append("</a></li>\n");
        sb.Append("<li><a href=\"#sanitize\">What Sanitize removes</a></li>\n")
          .Append(report.Notes.Count > 0 ? "<li><a href=\"#notes\">Not looked at</a></li>\n" : "")
          .Append("</ul>\n</nav>\n<main id=\"main\">\n");

        sb.Append("<section aria-labelledby=\"summary\">\n<h2 id=\"summary\">Summary</h2>\n<p class=\"verdict ").Append(report.IsEmpty ? "clean" : "found").Append("\">")
          .Append(E(report.Summary)).Append("</p>\n</section>\n");

        foreach (var s in sections)
        {
            var items = report.In(s).ToList();
            if (items.Count == 0) continue;
            var id = Id(s);
            var trigger = s is InventorySection.Scripts or InventorySection.Actions or InventorySection.Addresses;
            sb.Append("<section aria-labelledby=\"").Append(id).Append("\">\n<h2 id=\"").Append(id).Append("\">").Append(E(DocumentInventory.Title(s)))
              .Append(" (").Append(items.Count.ToString("N0", CultureInfo.InvariantCulture)).Append(")</h2>\n<table aria-labelledby=\"").Append(id).Append("\">\n<thead><tr>")
              .Append("<th scope=\"col\">What</th><th scope=\"col\">Where</th>").Append(trigger ? "<th scope=\"col\">Runs</th>" : "")
              .Append("<th scope=\"col\">Found</th></tr></thead>\n<tbody>\n");
            foreach (var i in items)
            {
                sb.Append("<tr").Append(i.WithoutClick ? " class=\"auto\"" : "").Append("><th scope=\"row\">").Append(E(i.What)).Append("</th><td>").Append(E(i.Where)).Append("</td>");
                if (trigger) sb.Append("<td>").Append(E(DocumentInventory.Name(i.Trigger))).Append(i.WithoutClick ? " <strong>(no click needed)</strong>" : "").Append("</td>");
                sb.Append("<td><code>").Append(E(i.Detail)).Append("</code>");
                if (i.Calls.Count > 0) sb.Append("<br><span class=\"calls\">It ").Append(E(string.Join(", ", i.Calls))).Append(".</span>");
                sb.Append("</td></tr>\n");
            }
            sb.Append("</tbody>\n</table>\n</section>\n");
        }

        sb.Append("<section aria-labelledby=\"sanitize\">\n<h2 id=\"sanitize\">What Sanitize removes</h2>\n")
          .Append("<p>Review › Sanitize Document removes these kinds and rewrites the file as one version.</p>\n<table aria-labelledby=\"sanitize\">\n")
          .Append("<thead><tr><th scope=\"col\">Kind</th><th scope=\"col\">Found</th></tr></thead>\n<tbody>\n");
        foreach (var (item, label) in Kinds)
            sb.Append("<tr><th scope=\"row\">").Append(E(label)).Append("</th><td>").Append(report.Counts[item].ToString("N0", CultureInfo.InvariantCulture)).Append("</td></tr>\n");
        sb.Append("<tr><th scope=\"row\">Earlier versions</th><td>").Append(report.Counts.EarlierRevisions.ToString("N0", CultureInfo.InvariantCulture)).Append("</td></tr>\n")
          .Append("<tr><th scope=\"row\">Objects nothing uses</th><td>").Append(report.Counts.UnusedObjects.ToString("N0", CultureInfo.InvariantCulture)).Append("</td></tr>\n")
          .Append("</tbody>\n</table>\n</section>\n");

        if (report.Notes.Count > 0)
        {
            sb.Append("<section aria-labelledby=\"notes\">\n<h2 id=\"notes\">Not looked at</h2>\n<ul>\n");
            foreach (var n in report.Notes) sb.Append("<li>").Append(E(n)).Append("</li>\n");
            sb.Append("</ul>\n</section>\n");
        }
        sb.Append("</main>\n<footer>\n<p>Made by Inkvolt PDF on this computer; nothing was sent anywhere, and no address in the file was contacted.</p>\n</footer>\n</body>\n</html>\n");
        return sb.ToString();
    }

    public static string Json(InventoryReport report, string fileName, DateTime madeAt)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true }))
        {
            w.WriteStartObject();
            w.WriteString("format", JsonFormat);
            w.WriteNumber("version", JsonVersion);
            w.WriteString("file", fileName);
            w.WriteString("madeAt", madeAt.ToString("yyyy-MM-ddTHH:mm:ssK", CultureInfo.InvariantCulture));
            w.WriteNumber("pages", report.Pages);
            w.WriteString("summary", report.Summary);
            w.WriteStartArray("items");
            foreach (var i in report.Items)
            {
                w.WriteStartObject();
                w.WriteString("section", Id(i.Section));
                w.WriteString("what", i.What);
                w.WriteString("where", i.Where);
                w.WriteString("found", i.Detail);
                if (i.Page >= 0) w.WriteNumber("page", i.Page + 1);
                else w.WriteNull("page");
                w.WriteString("runs", i.Trigger switch
                {
                    InventoryTrigger.Automatic => "automatic",
                    InventoryTrigger.Pointer => "pointer",
                    InventoryTrigger.Use => "use",
                    _ => "none",
                });
                w.WriteBoolean("withoutClick", i.WithoutClick);
                w.WriteStartArray("calls");
                foreach (var c in i.Calls) w.WriteStringValue(c);
                w.WriteEndArray();
                if (i.RemovedBy is { } r) w.WriteString("sanitizeRemoves", JsonNamingPolicy.CamelCase.ConvertName(r.ToString()));
                else w.WriteNull("sanitizeRemoves");
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteStartObject("sanitizeFinds");
            foreach (var (item, _) in Kinds) w.WriteNumber(JsonNamingPolicy.CamelCase.ConvertName(item.ToString()), report.Counts[item]);
            w.WriteNumber("earlierVersions", report.Counts.EarlierRevisions);
            w.WriteNumber("unusedObjects", report.Counts.UnusedObjects);
            w.WriteEndObject();
            w.WriteStartArray("notes");
            foreach (var n in report.Notes) w.WriteStringValue(n);
            w.WriteEndArray();
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray()) + "\n";
    }

    private static string Id(InventorySection s) => JsonNamingPolicy.CamelCase.ConvertName(s.ToString());

    private static readonly (SanitizeItem Item, string Label)[] Kinds =
    [
        (SanitizeItem.Metadata, "Metadata"),
        (SanitizeItem.HiddenLayers, "Hidden layers"),
        (SanitizeItem.HiddenAnnotations, "Hidden comments and fields"),
        (SanitizeItem.Comments, "Comments, markup, stamps and drawings"),
        (SanitizeItem.FormValues, "Form values"),
        (SanitizeItem.Bookmarks, "Bookmarks"),
        (SanitizeItem.Thumbnails, "Page thumbnails"),
        (SanitizeItem.ActiveContent, "Scripts and active content"),
        (SanitizeItem.ExternalLinks, "Links to web pages and other files"),
        (SanitizeItem.EmbeddedFiles, "Attached files"),
        (SanitizeItem.Signatures, "Digital signatures"),
    ];

    private const string Css = """
        :root { color-scheme: light dark; --fg: #1b1b1b; --bg: #ffffff; --muted: #4a4a4a; --line: #c8c8c8; --warn: #8a4b00; --ok: #0b6a0b; --head: #f2f2f2; --link: #0b57d0; }
        @media (prefers-color-scheme: dark) { :root { --fg: #ececec; --bg: #161616; --muted: #bdbdbd; --line: #4a4a4a; --warn: #ffb35c; --ok: #7fd87f; --head: #262626; --link: #8ab4f8; } }
        body { font: 16px/1.5 "Segoe UI", system-ui, sans-serif; color: var(--fg); background: var(--bg); max-width: 72rem; margin: 0 auto; padding: 1rem 1.5rem 3rem; }
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
        code { font: .92rem/1.4 "Cascadia Mono", Consolas, monospace; white-space: pre-wrap; word-break: break-word; }
        tr.auto td strong { color: var(--warn); }
        .calls { color: var(--muted); }
        footer { margin-top: 3rem; color: var(--muted); font-size: .9rem; }
        @media print { nav, .skip { display: none; } body { max-width: none; } }

        """;
}
