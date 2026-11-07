using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using MuPDFCore;
using MuPDFCore.StructuredText;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.FormsCorpus;

/// <summary>One thing that went wrong with a form: <see cref="Kind"/> is the signature it is grouped by.</summary>
public sealed record Failure(string Kind, string Field, string Detail);

/// <summary>What the harness plans to put in a field and what it then finds there.</summary>
public sealed record Planned(string Name, string Kind, string Sent, string? State, bool Password, string Format, string Stored = "", string Display = "");

/// <summary>One form's run: its fields, what was filled, the failures and notes.</summary>
public sealed class FormReport
{
    public string Name { get; set; } = "";
    public string Status { get; set; } = "pass";
    public string? Skip { get; set; }
    public int Fields { get; set; }
    public int Widgets { get; set; }
    public int PdfJsFields { get; set; } = -1;
    public int Filled { get; set; }
    public long Ms { get; set; }
    public List<string> Features { get; set; } = [];
    public List<Planned> Plan { get; set; } = [];
    public List<string> Names { get; set; } = [];
    /// <summary>Widgets per field on Inkvolt's page view (FormEditor.Read).</summary>
    public Dictionary<string, int> WidgetCounts { get; set; } = [];
    public List<Failure> Failures { get; set; } = [];
    public List<string> Notes { get; set; } = [];

    public void Fail(string kind, string field, string detail)
    {
        if (Failures.Count(f => f.Kind == kind) >= 25) return; // enough to see the pattern
        Failures.Add(new Failure(kind, field, detail.Length > 300 ? detail[..300] + "…" : detail));
    }
}

/// <summary>
/// Fills one form the way the app does (<see cref="FormEditor.Read"/> for the widgets the page view shows,
/// <see cref="FormEditor.Fill(byte[], string?, IReadOnlyDictionary{string, string})"/> for what a typed or clicked value
/// becomes), saves it, reads it back with FormEditor, checks every filled widget's appearance stream (PDFsharp) and what
/// MuPDF draws, and leaves the pdf.js comparison to <see cref="ComparePdfJs"/>.
/// </summary>
public static class FormsHarness
{
    public static readonly JsonSerializerOptions Json = new() { WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public static FormReport FillOne(string name, byte[] data, string outDir)
    {
        var report = new FormReport { Name = name };
        var clock = Stopwatch.StartNew();
        try
        {
            Run(report, data, outDir);
        }
        catch (Exception ex)
        {
            report.Fail("harness-exception", "", Signature(ex));
        }
        report.Ms = clock.ElapsedMilliseconds;
        if (report.Skip is not null) report.Status = "skip";
        else report.Status = report.Failures.Count == 0 ? "pass" : "fail";
        return report;
    }

    private static void Run(FormReport report, byte[] data, string outDir)
    {
        report.Features = Features(data);
        IReadOnlyList<FormWidget> widgets;
        try
        {
            widgets = FormEditor.Read(data, null);
        }
        catch (Exception ex)
        {
            report.Fail("read-exception", "", Signature(ex));
            return;
        }
        report.Widgets = widgets.Count;
        report.Names = [.. widgets.Select(w => w.FieldName).Distinct()];
        report.WidgetCounts = widgets.GroupBy(w => w.FieldName).ToDictionary(g => g.Key, g => g.Count());
        report.Fields = report.Names.Count;
        if (widgets.Count == 0)
        {
            var (xfa, xfaOnly) = SafeXfa(data);
            report.Skip = xfaOnly ? "XFA-only form" : xfa ? "XFA, no widgets" : "no form fields";
            return;
        }

        IReadOnlyList<FormDataField> dataFields;
        try
        {
            dataFields = FormEditor.DataFields(data, null);
        }
        catch (Exception ex)
        {
            report.Fail("read-exception", "", Signature(ex));
            return;
        }
        // Hidden widgets aren't on the page view, but their fields are still found (by data import, scripts).
        report.Names = [.. report.Names.Union(dataFields.Select(f => f.Name))];
        var scripts = Scripts(data);
        var hasScripts = scripts.Values.Any(s => s.Format is not null || s.Keystroke is not null) || widgets.Any(w => w.Calculated || w.Triggers != FormTriggers.None);
        if (hasScripts) report.Features.Add("JavaScript");
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var ordinal = 0;
        foreach (var f in dataFields)
        {
            var ws = widgets.Where(w => w.FieldName == f.Name).ToList();
            if (f.ReadOnly || ws.Count == 0 || ws.All(w => w.ReadOnly)) continue;
            if (ws.Any(w => w.Calculated)) continue; // its value comes from the others
            ordinal++;
            scripts.TryGetValue(f.Name, out var js);
            var format = FormatOf(js);
            string? state = null;
            string sent;
            switch (f.Kind)
            {
                case FormFieldKind.Text:
                    sent = TextValue(ordinal, format, js, f.MaxLength, ws.Any(w => w.Multiline), Comb(js));
                    break;
                case FormFieldKind.CheckBox:
                    state = ws.Select(w => w.OnState).FirstOrDefault(s => s is not null);
                    if (state is null)
                    {
                        report.Fail("checkbox-cannot-be-ticked", f.Name, "no widget has an on appearance (/AP /N state), so the page view refuses to tick it");
                        continue;
                    }
                    sent = state;
                    break;
                case FormFieldKind.Radio:
                    var states = ws.Select(w => w.OnState).OfType<string>().Distinct().ToList();
                    if (states.Count == 0)
                    {
                        report.Fail("radio-cannot-be-chosen", f.Name, "no button has an on appearance");
                        continue;
                    }
                    state = states[^1];
                    sent = state;
                    break;
                case FormFieldKind.Choice:
                    if (f.Options.Count == 0)
                    {
                        if (!f.Editable)
                        {
                            report.Notes.Add($"{f.Name}: choice field without options");
                            continue;
                        }
                        sent = $"Ink{ordinal}";
                    }
                    else if (f.MultiSelect && f.Options.Count > 2) sent = f.Options[1] + "\n" + f.Options[2];
                    else sent = f.Options.Count > 1 && f.Options[1].Trim().Length > 0 ? f.Options[1] : f.Options[0];
                    break;
                default:
                    continue;
            }
            values[f.Name] = sent;
            report.Plan.Add(new Planned(f.Name, f.Kind.ToString(), sent, state, ws.Any(w => w.Password), format));
        }
        if (values.Count == 0)
        {
            report.Notes.Add("nothing to fill (every field read-only or calculated)");
            return;
        }

        // Fill as the page view does (one batch of values through FormEditor.Fill); a value a script refuses is tried
        // again as digits, then as a date, as a person would.
        FormFillResult fill;
        try
        {
            fill = FormEditor.Fill(data, null, values);
        }
        catch (Exception ex)
        {
            report.Fail("fill-exception", "", Signature(ex));
            return;
        }
        var saved = fill.Data;
        var rejected = fill.Rejected.ToDictionary(r => r.FieldName, r => r.Message);
        foreach (var alternate in new Func<Planned, string?>[] { p => "1234", p => "1", p => "03/15/2024" })
        {
            if (rejected.Count == 0) break;
            var retry = new Dictionary<string, string>();
            foreach (var name in rejected.Keys)
                if (report.Plan.FindIndex(p => p.Name == name) is var i and >= 0 && report.Plan[i].Kind == "Text" && alternate(report.Plan[i]) is { } v)
                {
                    retry[name] = v;
                    report.Plan[i] = report.Plan[i] with { Sent = v };
                }
            if (retry.Count == 0) break;
            try
            {
                var again = FormEditor.Fill(saved, null, retry);
                saved = again.Data;
                rejected = again.Rejected.ToDictionary(r => r.FieldName, r => r.Message);
            }
            catch (Exception ex)
            {
                report.Fail("fill-exception", "", Signature(ex));
                return;
            }
        }
        foreach (var (name, why) in rejected)
            report.Fail("value-rejected-by-script", name, why.Length == 0 ? "(refused in a dialog)" : why.ReplaceLineEndings(" "));
        report.Plan.RemoveAll(p => rejected.ContainsKey(p.Name));
        report.Filled = report.Plan.Count;

        Directory.CreateDirectory(outDir);
        var filledPath = Path.Combine(outDir, report.Name + ".filled.pdf");
        File.WriteAllBytes(filledPath, saved);

        // Reopen and read back.
        IReadOnlyList<FormDataField> after;
        IReadOnlyList<FormWidget> afterWidgets;
        try
        {
            after = FormEditor.DataFields(saved, null);
            afterWidgets = FormEditor.Read(saved, null);
        }
        catch (Exception ex)
        {
            report.Fail("reopen-exception", "", Signature(ex));
            return;
        }
        var afterByName = after.GroupBy(f => f.Name).ToDictionary(g => g.Key, g => g.First());
        for (var i = 0; i < report.Plan.Count; i++)
        {
            var p = report.Plan[i];
            if (!afterByName.TryGetValue(p.Name, out var got))
            {
                report.Fail("field-gone-after-save", p.Name, "");
                continue;
            }
            // What the field shows: a text field's value through its format script, a choice's display text.
            var display = afterWidgets.FirstOrDefault(w => w.FieldName == p.Name)?.DisplayValue ?? got.Value;
            if (p.Kind == "Choice" && got.Options.ToList().IndexOf(got.Value) is var li and >= 0 && li < got.Labels.Count) display = got.Labels[li];
            report.Plan[i] = p = p with { Stored = got.Value, Display = display };
            var ok = p.Kind switch
            {
                "Text" => got.Value == p.Sent || got.Value.ReplaceLineEndings("\n") == p.Sent || Digits(got.Value).Length > 0 && Digits(got.Value) == Digits(p.Sent),
                "Choice" => got.Value == p.Sent || got.Value.Replace("\r", "") == p.Sent,
                _ => got.Value is not ("Off" or ""),
            };
            if (ok && SpanishAmount(p.Format, p.Sent) is { } want && !Normalize(display).Contains(want, StringComparison.Ordinal))
                report.Fail("spanish-number-misread", p.Name, $"{p.Format}: typed '{p.Sent}', stored '{Esc(got.Value)}', shows '{Esc(display)}' (expected {want})");
            if (ok) continue;
            // Filled alone, does it keep the value? Then another field's script changed it (the form's own doing).
            var alone = SafeFill(data, p.Name, p.Sent);
            if (alone is not null && alone == p.Sent)
            {
                report.Notes.Add($"{p.Name}: kept alone, changed to '{Esc(got.Value)}' when filled with the others (a script of the form)");
                continue;
            }
            report.Fail(got.Value.Length == 0 || got.Value == "Off" ? "value-not-kept" : "value-changed", p.Name, $"{p.Kind} {p.Format}: sent '{Esc(p.Sent)}', read back '{Esc(got.Value)}'");
        }

        // Fields nobody filled keep their values, unless the form's scripts or calculations set them.
        var planned = report.Plan.Select(p => p.Name).ToHashSet();
        var calculated = widgets.Where(w => w.Calculated).Select(w => w.FieldName).ToHashSet();
        foreach (var f in dataFields)
        {
            if (planned.Contains(f.Name) || calculated.Contains(f.Name) || !afterByName.TryGetValue(f.Name, out var now) || now.Value == f.Value) continue;
            if (hasScripts) report.Notes.Add($"{f.Name}: not filled, changed '{Esc(f.Value)}' → '{Esc(now.Value)}' (the form has scripts)");
            else report.Fail("untouched-field-changed", f.Name, $"{f.Kind}: '{Esc(f.Value)}' became '{Esc(now.Value)}' though it wasn't filled");
        }

        CheckAppearances(report, saved);
        CheckMuPdf(report, saved, afterWidgets);
        CheckCalculations(report, widgets, afterWidgets);
    }

    /// <summary>
    /// How Acrobat shows an amount typed with a decimal comma in a sepStyle 2 (1.234,56) or 3 (1234,56) field with
    /// nDec decimals: 1007,5 → 1.007,50 or 1007,50 (or 1008 with no decimals). Null for other formats or values.
    /// </summary>
    internal static string? SpanishAmount(string format, string typed)
    {
        var m = Regex.Match(format, @"^number:([23]):(\d+)$");
        if (!m.Success || !typed.Contains(',')) return null;
        var dec = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
        var v = Math.Round(decimal.Parse(typed.Replace(',', '.'), CultureInfo.InvariantCulture), dec, MidpointRounding.AwayFromZero);
        var text = v.ToString(dec == 0 ? "0" : "0." + new string('0', dec), CultureInfo.InvariantCulture);
        var (whole, frac) = text.Contains('.') ? (text[..text.IndexOf('.')], text[(text.IndexOf('.') + 1)..]) : (text, "");
        if (m.Groups[1].Value == "2")
            for (var i = whole.Length - 3; i > 0; i -= 3) whole = whole[..i] + "." + whole[i..];
        return frac.Length > 0 ? whole + "," + frac : whole;
    }

    /// <summary>One field filled by itself on the original: the value it then holds, or null when that fails.</summary>
    private static string? SafeFill(byte[] data, string name, string value)
    {
        try
        {
            var saved = FormEditor.Fill(data, null, new Dictionary<string, string> { [name] = value }).Data;
            return FormEditor.DataFields(saved, null).FirstOrDefault(f => f.Name == name)?.Value;
        }
        catch
        {
            return null;
        }
    }

    // ───────────────────────────── values ─────────────────────────────

    /// <summary>What kind of value a text field's format or keystroke script expects: number, percent, date, time,
    /// zip, zip4, phone, ssn, mask:..., custom (other JavaScript) or plain.</summary>
    internal static string FormatOf(FieldScripts? js)
    {
        var s = (js?.Format ?? "") + "\n" + (js?.Keystroke ?? "");
        if (s.Trim().Length == 0) return "plain";
        // number:<sepStyle>: 0 1,234.56 · 1 1234.56 · 2 1.234,56 · 3 1234,56 (Acrobat's AFNumber_Format)
        if (Regex.Match(s, @"AFNumber_Format\s*\(\s*(\d+)\s*,\s*(\d)") is { Success: true } num) return $"number:{num.Groups[2].Value}:{num.Groups[1].Value}";
        if (Regex.Match(s, @"AFNumber_Keystroke\s*\(\s*(\d+)\s*,\s*(\d)") is { Success: true } numk) return $"number:{numk.Groups[2].Value}:{numk.Groups[1].Value}";
        if (Regex.IsMatch(s, @"AFNumber_(Format|Keystroke)")) return "number:0";
        if (Regex.IsMatch(s, @"AFPercent_(Format|Keystroke)")) return "percent";
        if (Regex.Match(s, @"AFDate_(?:Format|Keystroke)Ex\s*\(\s*[""']([^""']*)[""']") is { Success: true } d) return "date:" + d.Groups[1].Value;
        if (Regex.Match(s, @"AFDate_(?:Format|Keystroke)\s*\(\s*(\d+)") is { Success: true } dn) return "date:" + DateFormat(int.Parse(dn.Groups[1].Value, CultureInfo.InvariantCulture));
        if (Regex.IsMatch(s, @"AFTime_(Format|Keystroke)")) return "time";
        if (Regex.Match(s, @"AFSpecial_(?:Format|Keystroke)\s*\(\s*(\d)") is { Success: true } sp) return sp.Groups[1].Value switch { "0" => "zip", "1" => "zip4", "2" => "phone", _ => "ssn" };
        if (Regex.Match(s, @"AFSpecial_KeystrokeEx\s*\(\s*[""']([^""']*)[""']") is { Success: true } m) return "mask:" + m.Groups[1].Value;
        return "custom";
    }

    private static string DateFormat(int n)
    {
        string[] formats = ["m/d", "m/d/yy", "mm/dd/yy", "mm/yy", "d-mmm", "d-mmm-yy", "dd-mmm-yy", "yy-mm-dd", "mmm-yy", "mmmm-yy", "mmm d, yyyy", "mmmm d, yyyy", "m/d/yy h:MM tt", "m/d/yy HH:MM"];
        return n >= 0 && n < formats.Length ? formats[n] : "mm/dd/yyyy";
    }

    internal static string TextValue(int ordinal, string format, FieldScripts? js, int maxLen, bool multiline, bool comb)
    {
        var digits = (1000 + ordinal * 7 % 9000).ToString(CultureInfo.InvariantCulture);
        var value = format switch
        {
            // A Spanish-format amount typed the way its readers type it: decimal comma.
            _ when format.StartsWith("number:2", StringComparison.Ordinal) || format.StartsWith("number:3", StringComparison.Ordinal) => $"{digits},5",
            "percent" => "12",
            _ when format.StartsWith("number", StringComparison.Ordinal) => digits,
            "time" => "13:30",
            "zip" => "00901",
            "zip4" => "009011234",
            "phone" => "7875551234",
            "ssn" => "123456789",
            _ when format.StartsWith("date:", StringComparison.Ordinal) => FormatDate(format[5..]),
            _ when format.StartsWith("mask:", StringComparison.Ordinal) => FillMask(format[5..]),
            _ when comb => "123456789",
            _ when multiline => $"Ink{ordinal}\nline two",
            _ => $"Ink{ordinal}",
        };
        if (maxLen > 0 && value.Length > maxLen)
            value = format == "plain" && maxLen >= 2 ? $"I{ordinal}"[..Math.Min(maxLen, $"I{ordinal}".Length)] : new string(Enumerable.Range(0, maxLen).Select(i => (char)('1' + i % 9)).ToArray());
        return value;
    }

    private static string FormatDate(string fmt)
    {
        var d = new DateTime(2024, 3, 15, 13, 30, 0, DateTimeKind.Unspecified);
        return Regex.Replace(fmt, "yyyy|yy|mmmm|mmm|mm|m|dddd|ddd|dd|d|HH|H|hh|h|MM|M|ss|s|tt|t", t => t.Value switch
        {
            "yyyy" => "2024", "yy" => "24", "mmmm" => "March", "mmm" => "Mar", "mm" => "03", "m" => "3",
            "dddd" => "Friday", "ddd" => "Fri", "dd" => "15", "d" => "15",
            "HH" or "H" => "13", "hh" or "h" => "1", "MM" or "M" => "30", "ss" or "s" => "00", "tt" => "pm", _ => "p",
        });
    }

    private static string FillMask(string mask)
    {
        var sb = new StringBuilder();
        var n = 1;
        foreach (var c in mask)
            sb.Append(c switch { '9' => (char)('0' + n++ % 10), 'A' => 'K', 'X' or '*' or 'O' => 'K', _ => c });
        return sb.ToString();
    }

    // ───────────────────────────── scripts and features (read with PDFsharp, independently of FormEditor) ─────────────────────────────

    public sealed record FieldScripts(string? Format, string? Keystroke, int Flags);

    private static bool Comb(FieldScripts? js) => js is not null && (js.Flags & (1 << 24)) != 0 && (js.Flags & ((1 << 12) | (1 << 13))) == 0;

    internal static Dictionary<string, FieldScripts> Scripts(byte[] data)
    {
        var result = new Dictionary<string, FieldScripts>(StringComparer.Ordinal);
        try
        {
            using var doc = PdfReader.Open(new MemoryStream(data), PdfDocumentOpenMode.Import);
            var tree = new FieldTree(doc);
            foreach (var page in doc.Pages)
                foreach (var w in Widgets(page))
                {
                    var chain = tree.Chain(w);
                    var name = tree.FullName(w);
                    if (name.Length == 0) continue;
                    var f = Script(chain, "/F");
                    var k = Script(chain, "/K");
                    var flags = chain.Select(d => Resolve(d.Elements["/Ff"])).OfType<PdfInteger>().FirstOrDefault()?.Value ?? 0;
                    if (result.TryGetValue(name, out var had)) result[name] = new FieldScripts(had.Format ?? f, had.Keystroke ?? k, had.Flags | flags);
                    else result[name] = new FieldScripts(f, k, flags);
                }
        }
        catch
        {
            // FormEditor read it; scripts are only a hint for the values.
        }
        return result;
    }

    private static string? Script(List<PdfDictionary> chain, string key)
    {
        foreach (var d in chain)
            if (Resolve(d.Elements["/AA"]) is PdfDictionary aa && Resolve(aa.Elements[key]) is PdfDictionary action && Resolve(action.Elements["/JS"]) is { } js)
                return js switch
                {
                    PdfString s => s.Value,
                    PdfDictionary { Stream: { } st } => Encoding.Latin1.GetString(st.UnfilteredValue),
                    _ => null,
                };
        return null;
    }

    internal static IEnumerable<PdfDictionary> Widgets(PdfPage page)
    {
        if (Resolve(page.Elements["/Annots"]) is not PdfArray annots) yield break;
        foreach (var item in annots.Elements)
            if (Resolve(item) is PdfDictionary a && a.Elements.GetName("/Subtype") == "/Widget")
                yield return a;
    }

    /// <summary>
    /// The AcroForm's field tree read top-down from /Fields, as Acrobat reads it: each widget's full name and its chain
    /// of field dictionaries (itself first). A widget missing its /Parent link is still named by the tree.
    /// </summary>
    internal sealed class FieldTree
    {
        private readonly Dictionary<PdfDictionary, List<PdfDictionary>> _chains = new(ReferenceEqualityComparer.Instance);

        public FieldTree(PdfDocument doc)
        {
            if (Resolve(doc.Internals.Catalog.Elements["/AcroForm"]) is PdfDictionary acro && Resolve(acro.Elements["/Fields"]) is PdfArray fields)
                foreach (var f in fields.Elements)
                    if (Resolve(f) is PdfDictionary d) Walk(d, []);
        }

        private void Walk(PdfDictionary d, List<PdfDictionary> above)
        {
            if (above.Count > 32 || _chains.ContainsKey(d) || above.Contains(d)) return;
            List<PdfDictionary> chain = [d, .. above];
            _chains[d] = chain;
            if (Resolve(d.Elements["/Kids"]) is PdfArray kids)
                foreach (var k in kids.Elements)
                    if (Resolve(k) is PdfDictionary kd) Walk(kd, chain);
        }

        /// <summary>The widget and its fields up to the root: from the tree, else by its /Parent links.</summary>
        public List<PdfDictionary> Chain(PdfDictionary widget)
        {
            if (_chains.TryGetValue(widget, out var chain)) return chain;
            var list = new List<PdfDictionary>();
            for (var d = widget; d is not null && list.Count < 64 && !list.Contains(d); d = Resolve(d.Elements["/Parent"]) as PdfDictionary) list.Add(d);
            return list;
        }

        /// <summary>A widget's full field name: the /T of it and its parents, joined by dots.</summary>
        public string FullName(PdfDictionary widget) =>
            string.Join('.', Chain(widget).AsEnumerable().Reverse().Select(d => Resolve(d.Elements["/T"])).OfType<PdfString>().Select(t => t.Value));
    }

    internal static PdfItem? Resolve(PdfItem? item) => item is PdfReference r ? r.Value : item;

    /// <summary>Traits worth grouping failures by: producer, NeedAppearances, XFA, object streams, incremental updates, JavaScript.</summary>
    private static List<string> Features(byte[] data)
    {
        var features = new List<string>();
        var text = Encoding.Latin1.GetString(data);
        var eofs = Regex.Matches(text, "%%EOF").Count;
        if (eofs > 1) features.Add($"incremental-updates:{eofs - 1}");
        if (text.Contains("/ObjStm", StringComparison.Ordinal)) features.Add("object-streams");
        try
        {
            using var doc = PdfReader.Open(new MemoryStream(data), PdfDocumentOpenMode.Import);
            if (Resolve(doc.Internals.Catalog.Elements["/AcroForm"]) is PdfDictionary acro)
            {
                if (Resolve(acro.Elements["/NeedAppearances"]) is PdfBoolean { Value: true }) features.Add("NeedAppearances");
                if (acro.Elements.ContainsKey("/XFA")) features.Add("XFA");
                if (acro.Elements.ContainsKey("/CO")) features.Add("calculation-order");
            }
            var producer = doc.Info.Producer;
            if (!string.IsNullOrWhiteSpace(producer)) features.Add("producer:" + producer.Trim());
            var creator = doc.Info.Creator;
            if (!string.IsNullOrWhiteSpace(creator)) features.Add("creator:" + creator.Trim());
        }
        catch (Exception ex)
        {
            features.Add("pdfsharp-cannot-read:" + ex.GetType().Name);
        }
        return features;
    }

    private static (bool, bool) SafeXfa(byte[] data)
    {
        try
        {
            return FormEditor.HasXfa(data, null);
        }
        catch
        {
            return (false, false);
        }
    }

    // ───────────────────────────── appearances ─────────────────────────────

    /// <summary>Every widget of a filled field has a normal appearance; a check box or radio shows the state it was
    /// set to; a text or combo field's appearance stream draws the value (as the format script shows it).</summary>
    private static void CheckAppearances(FormReport report, byte[] saved)
    {
        var plan = report.Plan.ToDictionary(p => p.Name);
        using var doc = PdfReader.Open(new MemoryStream(saved), PdfDocumentOpenMode.Import);
        var needs = Resolve(doc.Internals.Catalog.Elements["/AcroForm"]) is PdfDictionary acro && Resolve(acro.Elements["/NeedAppearances"]) is PdfBoolean { Value: true };
        if (needs) report.Notes.Add("saved with /NeedAppearances true");
        var seen = new HashSet<string>();
        var tree = new FieldTree(doc);
        foreach (var page in doc.Pages)
            foreach (var w in Widgets(page))
            {
                var name = tree.FullName(w);
                if (!plan.TryGetValue(name, out var p)) continue;
                seen.Add(name);
                var n = Resolve((Resolve(w.Elements["/AP"]) as PdfDictionary)?.Elements["/N"]);
                if (n is null)
                {
                    report.Fail("appearance-missing", name, $"{p.Kind}{(needs ? " (NeedAppearances set)" : "")}");
                    continue;
                }
                if (p.Kind is "CheckBox" or "Radio")
                {
                    var states = n is PdfDictionary { Stream: null } sd ? sd.Elements.Keys.Select(k => k.TrimStart('/')).Where(k => k != "Off").ToList() : [];
                    var shown = (w.Elements.GetName("/AS") ?? "").TrimStart('/');
                    if (states.Count == 0)
                    {
                        report.Fail("appearance-no-states", name, $"{p.Kind}: /AP /N is a single stream, /AS={shown}");
                        continue;
                    }
                    if (states.Contains(p.State!) && shown != p.State && p.Kind == "CheckBox")
                        report.Fail("appearance-wrong-state", name, $"{p.Kind}: /AS={shown}, set to {p.State}");
                    if (p.Kind == "Radio" && states.Contains(p.State!) && shown != p.State)
                        report.Fail("appearance-wrong-state", name, $"Radio: the chosen button shows /AS={shown}, set to {p.State}");
                    if (shown.Length > 0 && shown != "Off" && !states.Contains(shown))
                        report.Fail("appearance-state-undrawn", name, $"/AS={shown} has no face; faces: {string.Join(",", states)}");
                    continue;
                }
                if (n is not PdfDictionary { Stream: { } stream } form)
                {
                    report.Fail("appearance-missing", name, $"{p.Kind}: /AP /N is not a stream");
                    continue;
                }
                if (p.Password || p.Kind == "Choice" && p.Sent.Contains('\n')) continue;
                if (UsesTwoByteFont(form))
                {
                    report.Notes.Add($"{name}: appearance in a two-byte font, text not compared");
                    continue;
                }
                var drawn = Normalize(WinAnsi(string.Concat(Strings(stream.UnfilteredValue))));
                var expected = Normalize(p.Display.Length > 0 ? p.Display : p.Stored);
                if (expected.Length == 0) continue;
                if (!drawn.Contains(expected[..Math.Min(expected.Length, 24)], StringComparison.Ordinal))
                    report.Fail("appearance-text-mismatch", name, $"{p.Kind} {p.Format}: draws '{Esc(drawn, 60)}', value shows '{Esc(expected, 40)}'");
            }
        foreach (var p in report.Plan.Where(p => !seen.Contains(p.Name)))
            report.Notes.Add($"{p.Name}: no widget found by its full name in the saved file (name read differently)");
    }

    private static bool UsesTwoByteFont(PdfDictionary form)
    {
        if (Resolve(form.Elements["/Resources"]) is not PdfDictionary res || Resolve(res.Elements["/Font"]) is not PdfDictionary fonts) return false;
        foreach (var key in fonts.Elements.Keys)
            if (Resolve(fonts.Elements[key]) is PdfDictionary f && f.Elements.GetName("/Subtype") == "/Type0") return true;
        return false;
    }

    /// <summary>Bytes 0x80–0x9F as WinAnsiEncoding reads them (€, curly quotes, dashes...); the rest are Latin-1 already.</summary>
    private static string WinAnsi(string s)
    {
        const string High = "€\u0081‚ƒ„…†‡ˆ‰Š‹Œ\u008DŽ\u008F\u0090‘’“”•–—˜™š›œ\u009DžŸ";
        return string.Concat(s.Select(c => c is >= '\u0080' and <= '\u009F' ? High[c - 0x80] : c));
    }

    /// <summary>The string operands of a content stream, decoded byte for byte (simple fonts).</summary>
    internal static IEnumerable<string> Strings(byte[] content)
    {
        for (var i = 0; i < content.Length; i++)
        {
            var c = content[i];
            if (c == '%')
            {
                while (i < content.Length && content[i] is not ((byte)'\n' or (byte)'\r')) i++;
            }
            else if (c == '(')
            {
                var sb = new StringBuilder();
                var depth = 1;
                for (i++; i < content.Length && depth > 0; i++)
                {
                    var b = content[i];
                    if (b == '\\' && i + 1 < content.Length)
                    {
                        var e = content[++i];
                        if (e is >= (byte)'0' and <= (byte)'7')
                        {
                            var v = e - '0';
                            for (var k = 0; k < 2 && i + 1 < content.Length && content[i + 1] is >= (byte)'0' and <= (byte)'7'; k++) v = v * 8 + content[++i] - '0';
                            sb.Append((char)v);
                        }
                        else sb.Append(e switch { (byte)'n' => '\n', (byte)'r' => '\r', (byte)'t' => '\t', (byte)'b' => '\b', (byte)'f' => '\f', (byte)'\r' or (byte)'\n' => '\0', _ => (char)e });
                        continue;
                    }
                    if (b == '(') depth++;
                    else if (b == ')' && --depth == 0) break;
                    sb.Append((char)b);
                }
                yield return sb.ToString().Replace("\0", "");
            }
            else if (c == '<' && i + 1 < content.Length && content[i + 1] != '<')
            {
                var hex = new StringBuilder();
                for (i++; i < content.Length && content[i] != '>'; i++)
                    if (Uri.IsHexDigit((char)content[i])) hex.Append((char)content[i]);
                if (hex.Length % 2 == 1) hex.Append('0');
                var sb = new StringBuilder();
                for (var k = 0; k < hex.Length; k += 2) sb.Append((char)Convert.ToByte(hex.ToString(k, 2), 16));
                yield return sb.ToString();
            }
            else if (c == '<') i++;
        }
    }

    /// <summary>What MuPDF draws on the saved file's pages (annotations included) holds each filled text and combo
    /// value as its format shows it: MuPDF reads the appearance streams, independently of PDFsharp.</summary>
    private static void CheckMuPdf(FormReport report, byte[] saved, IReadOnlyList<FormWidget> afterWidgets)
    {
        var byPage = new Dictionary<int, string>();
        try
        {
            using var ctx = new MuPDFContext();
            using var doc = new MuPDFDocument(ctx, saved, InputFileTypes.PDF);
            foreach (var p in report.Plan)
            {
                if (p.Kind is not ("Text" or "Choice") || p.Password || p.Sent.Contains('\n') && p.Kind == "Choice") continue;
                var expected = Normalize(p.Display.Length > 0 ? p.Display : p.Stored);
                if (expected.Length == 0) continue;
                var pages = afterWidgets.Where(w => w.FieldName == p.Name && w.Rect.Width > 1 && w.Rect.Height > 1).Select(w => w.PageIndex).Distinct().ToList();
                if (pages.Count == 0) continue;
                var found = false;
                foreach (var page in pages)
                {
                    if (!byPage.TryGetValue(page, out var text))
                    {
                        using var st = doc.GetStructuredTextPage(page, true);
                        var sb = new StringBuilder();
                        foreach (var block in st)
                            if (block is MuPDFTextStructuredTextBlock tb)
                                foreach (var line in tb)
                                    foreach (var ch in line) sb.Append(ch.Character);
                        byPage[page] = text = Normalize(sb.ToString());
                    }
                    if (text.Contains(expected[..Math.Min(expected.Length, 24)], StringComparison.Ordinal)) found = true;
                }
                if (!found) report.Fail("mupdf-does-not-show-value", p.Name, $"{p.Kind} {p.Format}: '{Esc(expected, 40)}' not in MuPDF's text of page {pages[0] + 1}");
            }
        }
        catch (Exception ex)
        {
            report.Fail("mupdf-cannot-read-saved", "", Signature(ex));
        }
    }

    /// <summary>Calculated fields that kept their value although their inputs were filled: noted, not failed.</summary>
    private static void CheckCalculations(FormReport report, IReadOnlyList<FormWidget> before, IReadOnlyList<FormWidget> after)
    {
        var calc = before.Where(w => w.Calculated).Select(w => w.FieldName).Distinct().ToList();
        if (calc.Count == 0) return;
        var was = before.GroupBy(w => w.FieldName).ToDictionary(g => g.Key, g => g.First().Value);
        var now = after.GroupBy(w => w.FieldName).ToDictionary(g => g.Key, g => g.First().Value);
        var changed = calc.Count(n => now.TryGetValue(n, out var v) && was.TryGetValue(n, out var o) && v != o);
        report.Notes.Add($"calculated fields: {changed} of {calc.Count} changed after filling");
        if (changed == 0) report.Notes.Add("calc-not-updated: no calculated field changed");
    }

    // ───────────────────────────── pdf.js ─────────────────────────────

    public sealed record PdfJsWidget(int Page, string? Name, string? Type, JsonElement Value, bool HasAppearance, bool? CheckBox, bool? RadioButton,
        bool? PushButton, JsonElement ButtonValue, string? ExportValue, bool? ReadOnly, bool? Hidden);

    public sealed record PdfJsListing(string File, string? Error, List<PdfJsWidget> Widgets);

    /// <summary>Reads PDFs with pdf.js (pdfjs-fields.mjs), a few per Node process.</summary>
    public static Dictionary<string, PdfJsListing> ReadPdfJs(string node, string toolDir, IReadOnlyList<string> files)
    {
        var result = new Dictionary<string, PdfJsListing>(StringComparer.OrdinalIgnoreCase);
        var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        foreach (var chunk in files.Chunk(10))
        {
            var psi = new ProcessStartInfo(node) { WorkingDirectory = toolDir, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, StandardOutputEncoding = Encoding.UTF8 };
            psi.ArgumentList.Add(Path.Combine(toolDir, "pdfjs-fields.mjs"));
            foreach (var f in chunk) psi.ArgumentList.Add(f);
            using var p = Process.Start(psi)!;
            var stderr = p.StandardError.ReadToEndAsync();
            string? line;
            while ((line = p.StandardOutput.ReadLine()) is not null)
            {
                if (line.Length == 0) continue;
                var listing = JsonSerializer.Deserialize<PdfJsListing>(line, options)!;
                result[Path.GetFullPath(listing.File)] = listing with { Widgets = listing.Widgets ?? [] };
            }
            if (!p.WaitForExit(15 * 60_000)) p.Kill(true);
        }
        return result;
    }

    /// <summary>
    /// pdf.js's view: the fields it lists in the original (what other readers would offer to fill) are all among
    /// Inkvolt's; in the filled file every filled field reads the value Inkvolt stored, and every widget of it has an
    /// appearance.
    /// </summary>
    public static void ComparePdfJs(FormReport report, PdfJsListing? original, PdfJsListing? filled)
    {
        if (report.Status == "skip")
        {
            // "No form fields" is only true if pdf.js finds none to show either.
            if (report.Skip != "no form fields" || original?.Widgets.Any(w => w.Hidden != true && !string.IsNullOrEmpty(w.Name)) != true) return;
            report.Skip = null;
            report.Status = "fail";
        }
        if (original is null || original.Error is not null)
        {
            report.Notes.Add($"pdf.js can't read the original: {original?.Error ?? "not run"}");
        }
        else
        {
            var theirs = original.Widgets.Where(w => !string.IsNullOrEmpty(w.Name)).Select(w => w.Name!).Distinct().ToList();
            report.PdfJsFields = theirs.Count;
            var ours = new HashSet<string>(report.Names, StringComparer.Ordinal);
            foreach (var name in theirs.Where(n => !ours.Contains(n)))
            {
                var w = original.Widgets.First(x => x.Name == name);
                report.Fail("field-not-found", name, $"pdf.js lists a {w.Type} field (page {w.Page}) that Inkvolt doesn't");
            }
            // Each field's visible widgets: as many on Inkvolt's page view as pdf.js shows.
            foreach (var g in original.Widgets.Where(w => !string.IsNullOrEmpty(w.Name) && w.Hidden != true).GroupBy(w => w.Name!))
                if (ours.Contains(g.Key) && report.WidgetCounts.TryGetValue(g.Key, out var n) && n < g.Count())
                    report.Fail("widget-not-shown", g.Key, $"{g.First().Type}: pdf.js shows {g.Count()} widget(s), Inkvolt's page view {n}");
            var extra = report.Names.Where(n => !theirs.Contains(n)).ToList();
            if (extra.Count > 0) report.Notes.Add($"Inkvolt lists {extra.Count} field(s) pdf.js doesn't, e.g. {extra[0]}");
        }
        if (report.Plan.Count == 0 || report.Failures.Any(f => f.Kind is "fill-exception" or "reopen-exception" or "read-exception")) return;
        if (filled is null || filled.Error is not null)
        {
            report.Fail("pdfjs-cannot-read-filled", "", filled?.Error ?? "not run");
            return;
        }
        var byName = filled.Widgets.Where(w => w.Name is not null).GroupBy(w => w.Name!).ToDictionary(g => g.Key, g => g.ToList());
        foreach (var p in report.Plan)
        {
            if (!byName.TryGetValue(p.Name, out var ws))
            {
                report.Fail("pdfjs-field-missing-after-save", p.Name, p.Kind);
                continue;
            }
            // A button's off widgets may lack an "Off" face (nothing to draw): only the one turned on must show.
            var shown = p.Kind switch
            {
                // pdf.js names a button by its /Opt export value when there is one, else by its on state: what Inkvolt reads back.
                "Radio" => ws.Where(w => Str(w.ButtonValue) == p.Stored).ToList(),
                "CheckBox" => ws.Where(w => w.ExportValue == p.Stored).ToList(),
                _ => ws,
            };
            // Buttons sharing an export value (one choice repeated on several pages) turn on one at a time: one must show.
            if (p.Kind is "Radio" or "CheckBox" ? shown.Count > 0 && shown.All(w => !w.HasAppearance) : shown.Any(w => !w.HasAppearance)) report.Fail("pdfjs-no-appearance", p.Name, $"{p.Kind}: {shown.Count(w => !w.HasAppearance)} of {shown.Count} widget(s)");
            string? problem = p.Kind switch
            {
                "Text" => Str(ws[0].Value) is var v && Same(v, p.Stored) ? null : $"pdf.js reads '{Esc(Str(ws[0].Value))}', Inkvolt stored '{Esc(p.Stored)}'",
                "Choice" => ws[0].Value.ValueKind == JsonValueKind.Array
                    ? (ws[0].Value.EnumerateArray().Select(e => e.GetString()).Contains(p.Stored.Split('\n')[0]) ? null : $"pdf.js reads [{string.Join(",", ws[0].Value.EnumerateArray())}], stored '{Esc(p.Stored)}'")
                    : Same(Str(ws[0].Value), p.Stored.Split('\n')[0]) ? null : $"pdf.js reads '{Esc(Str(ws[0].Value))}', stored '{Esc(p.Stored)}'",
                "CheckBox" => ws.Any(w => Str(w.Value) is var v && v != "Off" && v.Length > 0) ? null : "pdf.js reads it unticked",
                "Radio" => ws.Any(w => Str(w.Value) is var v && v != "Off" && v.Length > 0) ? null : "pdf.js reads no button chosen",
                _ => null,
            };
            if (problem is not null) report.Fail("pdfjs-value-differs", p.Name, $"{p.Kind}: {problem}");
        }
        report.Status = report.Failures.Count == 0 ? "pass" : "fail";

        static bool Same(string a, string b) => a.ReplaceLineEndings("\n") == b.ReplaceLineEndings("\n");
    }

    private static string Str(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.String => e.GetString() ?? "",
        JsonValueKind.Number => e.GetRawText(),
        JsonValueKind.Array => string.Join("\n", e.EnumerateArray().Select(x => x.ToString())),
        JsonValueKind.Null or JsonValueKind.Undefined => "",
        _ => e.GetRawText(),
    };

    // ───────────────────────────── helpers ─────────────────────────────

    /// <summary>An exception's signature for grouping: type, its message with numbers blanked, and the first Inkvolt frame.</summary>
    public static string Signature(Exception ex)
    {
        while (ex is AggregateException { InnerException: { } inner }) ex = inner;
        var msg = Regex.Replace(ex.Message.Split('\n')[0], @"\d+", "#");
        var frame = (ex.StackTrace ?? "").Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.Contains("InkvoltPdf.Core", StringComparison.Ordinal)) ?? "";
        frame = Regex.Replace(frame, @" in .*$", "");
        return $"{ex.GetType().Name}: {msg} @ {frame}";
    }

    private static string Normalize(string s) => Regex.Replace(s, @"\s+", "");
    private static string Digits(string s) => new([.. s.Where(char.IsAsciiDigit)]);
    private static string Esc(string s, int max = 40) => (s.Length > max ? s[..max] + "…" : s).Replace("\n", "\\n").Replace("\r", "\\r");
}
