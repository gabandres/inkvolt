using System.Xml.Linq;
using InkvoltPdf.Core;

// check <file.pdf>...                       Each file's result: PASS/FAIL and the conditions that fail.
// show <file.pdf>                           Every finding of one file (condition, page, element, problem).
// html <file.pdf> <out.html>                The report as the app saves it.
// obj <file.pdf> <number|root>             One object as PDFsharp reads it (a stream's first 1,500 bytes decoded).
// find <file.pdf> <text>                   The objects whose dictionary holds the text ("/ZapfDingbats").
// tags <file.pdf> [type]                   The structure tree as PDFsharp reads it (each tag, its attributes), or only the
//                                           subtrees of one type ("Table").
// tag [--all] <out-folder> <file.pdf>...  Make Accessible on each untagged file (tagged ones are skipped, or with --all their
//                                           tags replaced) into the folder,
//                                           each figure given a stand-in alternate text (as a person would type one), then
//                                           checked: PASS/FAIL and the conditions that fail.
// pdfa <out-folder> <file.pdf>...          Save as PDF/A-2a (the files must be tagged: run tag first), for veraPDF -f 2a.
// compare <verapdf.xml> <folder> [out.csv]  Our result against veraPDF's PDF/UA-1 report (verapdf --format xml), file by file
//                                           and by condition (veraPDF's rules mapped to Matterhorn numbers, Map below).
switch (args)
{
    case ["check", .. var files]:
        foreach (var f in files)
        {
            var r = Check(f);
            Console.WriteLine($"{Path.GetFileName(f)} {(r is null ? "ERROR" : r.Passed ? "PASS" : "FAIL")} {(r is null ? "" : string.Join(' ', r.FailedConditions))}");
        }
        return 0;
    case ["tag", .. var tagArgs] when tagArgs.Length > 0:
    {
        var all = tagArgs[0] == "--all";
        var outDir = tagArgs[all ? 1 : 0];
        var files = tagArgs[(all ? 2 : 1)..];
        Directory.CreateDirectory(outDir);
        foreach (var f in files)
        {
            var name = Path.GetFileName(f);
            try
            {
                var data = File.ReadAllBytes(f);
                if (!all && AccessibilityCheck.Run(data, null).Tagged)
                {
                    Console.WriteLine($"{name} skipped (tagged)");
                    continue;
                }
                using var engine = PdfEngine.Open(data, MuPDFCore.InputFileTypes.PDF, null);
                var plan = AutoTag.Plan(engine, data, null);
                var figures = 0;
                for (var i = 0; i < plan.Blocks.Count; i++)
                    if (plan.Blocks[i].Kind == TagBlockKind.Figure)
                    {
                        var n = ++figures;
                        plan = AutoTag.With(plan, i, b => b with { Alt = $"Figure {n} on page {b.Page + 1}" });
                    }
                var tagged = AutoTag.Write(data, null, plan, new AccessibleOptions { Title = plan.Title ?? Path.GetFileNameWithoutExtension(f), Language = plan.Language ?? "en" });
                var path = Path.Combine(outDir, name);
                File.WriteAllBytes(path, tagged);
                var r = AccessibilityCheck.Run(tagged, null);
                Console.WriteLine($"{name} {(r.Passed ? "PASS" : "FAIL")} {string.Join(' ', r.FailedConditions)} ({plan.Blocks.Count} blocks, {figures} figures)");
            }
            catch (Exception ex) when (ex is InvalidOperationException or PasswordRequiredException or ArgumentException or NotSupportedException)
            {
                Console.WriteLine($"{name} ERROR {ex.Message}");
            }
        }
        return 0;
    }
    case ["pdfa", var outDir, .. var files]:
        Directory.CreateDirectory(outDir);
        foreach (var f in files)
            try
            {
                var r = PdfA.Convert(File.ReadAllBytes(f), null, conformance: PdfAConformance.A);
                File.WriteAllBytes(Path.Combine(outDir, Path.GetFileName(f)), r.Data);
                Console.WriteLine($"{Path.GetFileName(f)} saved; {string.Join("; ", r.Changes)}");
            }
            catch (PdfAException ex)
            {
                Console.WriteLine($"{Path.GetFileName(f)} refused: {string.Join(" ", ex.Blockers)}");
            }
        return 0;
    case ["show", var file]:
    {
        var r = Check(file);
        if (r is null) return 1;
        Console.WriteLine(r.Summary);
        foreach (var f in r.Failures) Console.WriteLine($"{f.Condition} | {f.Where} | {f.Element} | x{f.Count} | {f.Problem}");
        foreach (var n in r.Notes) Console.WriteLine("note: " + n);
        return 0;
    }
    case ["html", var file, var html]:
    {
        var r = Check(file);
        if (r is null) return 1;
        File.WriteAllText(html, AccessibilityReportHtml.Write(r, Path.GetFileName(file), DateTime.Now));
        return 0;
    }
    case ["obj", var file, var number]:
    {
        using var doc = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(HybridXref.Normalize(File.ReadAllBytes(file))), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var o = number == "root" ? doc.Internals.Catalog : doc.Internals.GetObject(new PdfSharp.Pdf.PdfObjectID(int.Parse(number)));
        Console.WriteLine(o?.ToString());
        if (o is PdfSharp.Pdf.PdfDictionary { Stream: not null } sd) Console.WriteLine(System.Text.Encoding.Latin1.GetString(sd.Stream.UnfilteredValue.Take(1500).ToArray()));
        return 0;
    }
    case ["find", var file, var text]:
    {
        using var doc = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(HybridXref.Normalize(File.ReadAllBytes(file))), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        foreach (var o in doc.Internals.GetAllObjects())
            if (o is PdfSharp.Pdf.PdfDictionary d && d.ToString() is var t && t.Contains(text, StringComparison.Ordinal))
                Console.WriteLine($"{o.Reference?.ObjectNumber}: {(t.Length > 400 ? t[..400] : t)}");
        return 0;
    }
    case ["tags", var file, .. var only]:
        Tags(file, only.FirstOrDefault());
        return 0;
    case ["compare", var xml, var folder, .. var rest]:
        return Compare(xml, folder, rest.FirstOrDefault());
    default:
        Console.Error.WriteLine("usage: A11yCorpus check <pdf>... | show <pdf> | html <pdf> <out.html> | compare <verapdf.xml> <folder> [out.csv] | tags <pdf> [type] | obj <pdf> <n|root> | find <pdf> <text>");
        return 2;
}

static AccessibilityReport? Check(string file)
{
    try
    {
        return AccessibilityCheck.Run(File.ReadAllBytes(file), null);
    }
    catch (Exception ex) when (ex is InvalidOperationException or PasswordRequiredException)
    {
        Console.Error.WriteLine($"{Path.GetFileName(file)}: {ex.Message}");
        return null;
    }
}

static void Tags(string file, string? only)
{
    using var doc = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(HybridXref.Normalize(File.ReadAllBytes(file))), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
    var seen = new HashSet<PdfSharp.Pdf.PdfDictionary>(ReferenceEqualityComparer.Instance);
    void Walk(PdfSharp.Pdf.PdfItem? k, int depth, bool show)
    {
        var item = k is PdfSharp.Pdf.Advanced.PdfReference r ? r.Value : k;
        if (item is PdfSharp.Pdf.PdfArray a) { foreach (var e in a.Elements) Walk(e, depth, show); return; }
        if (item is not PdfSharp.Pdf.PdfDictionary d || !d.Elements.ContainsKey("/S") || !seen.Add(d) || depth > 64) return;
        var s = d.Elements["/S"]?.ToString() ?? "";
        show |= only is null || s == "/" + only;
        if (show)
            Console.WriteLine($"{new string(' ', 2 * depth)}{s} {string.Join(' ', d.Elements.Keys.Where(x => x is not ("/K" or "/P" or "/S" or "/Pg" or "/Type")).Select(x => $"{x}={Show(d.Elements[x])}"))}");
        Walk(d.Elements["/K"], depth + 1, show);
    }
    static string Show(PdfSharp.Pdf.PdfItem? item) => (item is PdfSharp.Pdf.Advanced.PdfReference r ? r.Value : item) switch
    {
        PdfSharp.Pdf.PdfArray a => "[" + string.Join(' ', a.Elements.Select(Show)) + "]",
        PdfSharp.Pdf.PdfDictionary d => "<<" + string.Join(' ', d.Elements.Keys.Select(k => k + " " + Show(d.Elements[k]))) + ">>",
        var x => x?.ToString() ?? "null",
    };
    var root = doc.Internals.Catalog.Elements["/StructTreeRoot"] is PdfSharp.Pdf.Advanced.PdfReference rr ? rr.Value as PdfSharp.Pdf.PdfDictionary : null;
    Walk(root?.Elements["/K"], 0, false);
}

static int Compare(string xmlPath, string folder, string? csv)
{
    var vera = new Dictionary<string, (bool Pass, HashSet<string> Groups, List<string> Rules)>(StringComparer.OrdinalIgnoreCase);
    foreach (var job in XDocument.Load(xmlPath).Descendants("job"))
    {
        var name = Path.GetFileName(job.Element("item")?.Element("name")?.Value ?? "");
        var report = job.Descendants("validationReport").FirstOrDefault();
        if (name.Length == 0 || report is null) continue;
        var rules = report.Descendants("rule").Where(r => (string?)r.Attribute("status") == "failed")
            .Select(r => $"{r.Attribute("clause")?.Value}-{r.Attribute("testNumber")?.Value}").ToList();
        vera[name] = ((string?)report.Attribute("isCompliant") == "true", [.. rules.Select(VeraGroup)], rules);
    }

    var rows = new List<string[]>();
    int fileMatch = 0, files = 0, groupMatch = 0;
    foreach (var pdf in Directory.EnumerateFiles(folder, "*.pdf").Order(StringComparer.OrdinalIgnoreCase))
    {
        var name = Path.GetFileName(pdf);
        if (!vera.TryGetValue(name, out var v)) continue;
        files++;
        var r = Check(pdf);
        var ours = r is null ? [] : r.FailedConditions.Select(OurGroup).ToHashSet();
        var pass = r?.Passed == true;
        var onlyVera = v.Groups.Except(ours).Order().ToList();
        var onlyOurs = ours.Except(v.Groups).Order().ToList();
        var same = r is not null && pass == v.Pass; // a file we can't read is never a match
        var sameGroups = r is not null && onlyVera.Count == 0 && onlyOurs.Count == 0;
        if (same) fileMatch++;
        if (sameGroups) groupMatch++;
        rows.Add([name, v.Pass ? "pass" : "fail", r is null ? "error" : pass ? "pass" : "fail", same ? "yes" : "NO",
            sameGroups ? "yes" : "no", string.Join(' ', onlyVera), string.Join(' ', onlyOurs)]);
    }
    string[] header = ["file", "veraPDF", "Inkvolt", "same result", "same conditions", "only veraPDF", "only Inkvolt"];
    var widths = header.Select((h, i) => Math.Min(44, Math.Max(h.Length, rows.Count == 0 ? 0 : rows.Max(r => r[i].Length)))).ToArray();
    Console.WriteLine(string.Join("  ", header.Select((h, i) => h.PadRight(widths[i]))));
    foreach (var row in rows) Console.WriteLine(string.Join("  ", row.Select((c, i) => (c.Length > 44 ? c[..43] + "…" : c).PadRight(widths[i]))));
    Console.WriteLine($"\nSame pass/fail: {fileMatch} of {files} files. Same failing conditions: {groupMatch} of {files}.");
    if (csv is not null)
        File.WriteAllLines(csv, [string.Join(',', header), .. rows.Select(r => string.Join(',', r.Select(c => $"\"{c.Replace("\"", "\"\"")}\"")))]);
    return fileMatch == files ? 0 : 1;
}

// veraPDF's PDF/UA-1 rules (ISO 14289-1 clause and test number) → the Matterhorn condition (or group of them) they check.
static string VeraGroup(string rule)
{
    var dash = rule.LastIndexOf('-');
    var clause = rule[..dash];
    var test = int.Parse(rule[(dash + 1)..], System.Globalization.CultureInfo.InvariantCulture);
    return (clause, test) switch
    {
        ("5", _) => "06-002",
        ("6.1", _) => "UA 6.1",
        ("6.2", _) => "UA 6.2",
        ("7.1", 1) => "01-003",
        ("7.1", 2) => "01-004",
        ("7.1", 3) => "01-005",
        ("7.1", 4) => "01-007",
        ("7.1", 5) => "02-001",
        ("7.1", 6) => "02-003",
        ("7.1", 7) => "02-004",
        ("7.1", 8) => "06-001",
        ("7.1", 9) => "06-003",
        ("7.1", 10) => "07-001/2",
        ("7.1", 11) => "UA 7.1",
        ("7.1", 12) => "UA 7.1-P",
        ("7.2", 2) => "11-003",
        ("7.2", >= 3 and <= 16) or ("7.2", >= 36 and <= 39) or ("7.2", >= 41 and <= 43) => "09-004",
        ("7.2", >= 17 and <= 20) or ("7.2", 40) => "09-005",
        ("7.2", >= 26 and <= 28) => "09-006",
        ("7.2", >= 21 and <= 23) or ("7.2", >= 30 and <= 32) => "11-002",
        ("7.2", 24) => "11-004",
        ("7.2", 25) => "11-005",
        ("7.2", 29) => "UA 7.2-Lang",
        ("7.2", 33) => "11-006",
        ("7.2", 34) => "11-001",
        ("7.3", _) => "13-004",
        ("7.4.2", _) => "14-002/3",
        ("7.4.4", 1) => "14-006",
        ("7.4.4", _) => "14-007",
        ("7.5", _) => "15-003",
        ("7.7", _) => "17-002",
        ("7.9", 1) => "19-003",
        ("7.9", _) => "19-004",
        ("7.10", 1) => "20-001/2",
        ("7.10", _) => "20-003",
        ("7.11", _) => "21-001",
        ("7.15", _) => "25-001",
        ("7.16", _) => "26-001/2",
        ("7.18.1", 1) => "28-002",
        ("7.18.1", 2) => "28-004",
        ("7.18.1", 3) => "28-005",
        ("7.18.2", _) => "28-007",
        ("7.18.3", _) => "28-008/9",
        ("7.18.4", _) => "28-010",
        ("7.18.5", 1) => "28-011",
        ("7.18.5", _) => "28-012",
        ("7.18.6.2", 1) => "28-014",
        ("7.18.6.2", _) => "28-015",
        ("7.18.8", _) => "28-017",
        ("7.20", 1) => "30-001",
        ("7.20", _) => "30-002",
        ("7.21.3.1", _) => "31-001/3",
        ("7.21.3.2", _) => "31-004/5",
        ("7.21.3.3", 1) => "31-006/8", // a CMap another one uses counts as a CMap here too
        ("7.21.3.3", 2) => "31-007",
        ("7.21.3.3", _) => "31-006/8",
        ("7.21.4.1", 1) => "31-009",
        ("7.21.4.1", _) => "31-011",
        ("7.21.4.2", 1) => "31-012/3",
        ("7.21.4.2", _) => "31-014/5",
        ("7.21.5", _) => "31-016",
        ("7.21.6", 1) => "31-017",
        ("7.21.6", 2) => "31-019/22",
        ("7.21.6", 3) => "31-024",
        ("7.21.6", _) => "31-025/6",
        ("7.21.7", 1) => "31-027",
        ("7.21.7", _) => "31-028/9",
        ("7.21.8", _) => "31-030",
        _ => "veraPDF " + rule,
    };
}

// Our conditions, grouped the way veraPDF's rules group them.
static string OurGroup(string id) => id switch
{
    "07-001" or "07-002" => "07-001/2",
    "14-002" or "14-003" => "14-002/3",
    "20-001" or "20-002" => "20-001/2",
    "26-001" or "26-002" => "26-001/2",
    "28-008" or "28-009" => "28-008/9",
    "28-016" => "21-001",
    "31-001" or "31-002" or "31-003" => "31-001/3",
    "31-004" or "31-005" => "31-004/5",
    "31-019" or "31-020" or "31-021" or "31-022" => "31-019/22",
    "31-025" or "31-026" => "31-025/6",
    "31-012" or "31-013" => "31-012/3",
    "31-006" or "31-008" => "31-006/8",
    "31-014" or "31-015" => "31-014/5",
    "31-028" or "31-029" => "31-028/9",
    _ => id,
};
