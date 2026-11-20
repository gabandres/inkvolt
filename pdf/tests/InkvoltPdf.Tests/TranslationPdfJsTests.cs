using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using Xunit;
using Xunit.Abstractions;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 3.1, pdf.js's half of "the copy reads as written": a translated copy opens in pdf.js (Mozilla's viewer, the one
/// in Firefox and most browser viewers) with each paragraph's new words in order. Opt-in with INKVOLTPDF_PDFJS (needs Node
/// and npm, <c>pdf/tools/pdfjs-check</c>); with INKVOLTPDF_CORPUS, the export corpus's first pages too. No model: each
/// text comes back with words of its own around it, its markup kept.
/// </summary>
public class TranslationPdfJsTests(ITestOutputHelper output)
{
    private const string Letters = "The quick brown fox jumps over a lazy dog, until the 0123456789 and THE QUICK BROWN FOX JUMPS OVER A LAZY DOG.!";

    private static string Solid(string s) => Regex.Replace(s, @"\s+", "");

    private static string Words(string s) => Regex.Replace(s.Normalize(NormalizationForm.FormKC), @"\s+", " ").Trim();

    /// <summary>The answer's words as a reader should find them: its tags taken out (a reply's tags never reach a page, ours or not).</summary>
    private static string Shown(string answer) => Words(TranslationMarkup.Plain(answer));

    /// <summary>Right-to-left copies pdf.js should read with the spaces between their right-to-left words: no stretch in two fonts.</summary>
    private static readonly HashSet<string> Spaced = ["arabic plain", "arabic red", "hebrew plain"];

    /// <summary>
    /// Right-to-left text as pdf.js reads a line written in stretches (<see cref="GlyphOrder.Stretches"/>): without the
    /// spaces between a right-to-left letter and a Latin letter or a figure.
    /// </summary>
    private static string Glued(string s)
    {
        static bool Is(char c, params Bidi.Cls[] classes) => classes.Contains(Bidi.Classify(c));
        var sb = new StringBuilder();
        for (var i = 0; i < s.Length; i++)
        {
            if (s[i] == ' ' && i > 0 && i + 1 < s.Length)
            {
                char a = s[i - 1], b = s[i + 1];
                if (Is(a, Bidi.Cls.R, Bidi.Cls.AL) && Is(b, Bidi.Cls.L, Bidi.Cls.EN) || Is(a, Bidi.Cls.L, Bidi.Cls.EN) && Is(b, Bidi.Cls.R, Bidi.Cls.AL)) continue;
            }
            sb.Append(s[i]);
        }
        return sb.ToString();
    }

    [Fact]
    public void Translated_copies_read_the_same_in_pdfjs()
    {
        var (node, skipped) = PdfJs.Ready();
        if (node is null)
        {
            if (skipped is not null) output.WriteLine(skipped);
            return;
        }
        static string Spanish(string t) => $"ñandú {t} y más";
        var cases = new List<(string Name, byte[] Pdf, int Page, string Language, Func<string, string> Answer)>
        {
            ("report", TranslationPdf.Report(1), 0, "es", Spanish),
            // Bold, a subscript, a red word and an underline, kept as looks.
            ("looks", ContentEditPdf.Make(
                "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (brown) Tj /FA 12 Tf ( fox jumps over d) Tj /FA 8 Tf -2 Ts (model) Tj 0 Ts /FA 12 Tf ( and the ) Tj " +
                "1 0 0 rg (red) Tj 0 g ( lazy dog.) Tj ET 0 0 0 rg 72 697 60 0.8 re f", faces: true, fontText: Letters), 0, "es",
                _ => "El <b>zorro</b> marrón salta sobre d<sub>model</sub> y el perro <span>rojo</span> perezoso."),
            ("arabic", ContentEditPdf.Make(
                "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (brown) Tj /FA 12 Tf ( fox is ) Tj 1 0 0 rg (red) Tj 0 g ( and jumps over the lazy dog.) Tj ET",
                faces: true, fontText: Letters), 0, "ar", _ => "الثعلب <b>البني</b> السريع <span>أحمر</span> ويقفز فوق الكلب الكسول."),
            ("arabic plain", ContentEditPdf.Make("BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog and the 2024 dog.) Tj ET", fontText: Letters), 0, "ar",
                _ => "الثعلب البني السريع يقفز فوق الكلب الكسول في عام 2024 والكلب (الكسول)."),
            // A red word is a color, not a font: its line is still written in stretches.
            ("arabic red", ContentEditPdf.Make(
                "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox is ) Tj 1 0 0 rg (red) Tj 0 g ( and jumps over the lazy dog.) Tj ET",
                faces: true, fontText: Letters), 0, "ar", _ => "قال ابن-سينا إن الثعلب <span>أحمر</span> ويقفز فوق fox الكلب."),
            ("hebrew", TranslationPdf.Report(1), 0, "he", _ => "השועל החום המהיר <b>קופץ</b> מעל הכלב העצלן."),
            ("hebrew plain", TranslationPdf.Report(1), 0, "he", _ => "השועל החום המהיר קופץ מעל הכלב [העצלן] בשנת 2025."),
            ("japanese", TranslationPdf.Report(1), 0, "ja", t => "素早い茶色の狐が怠惰な犬を飛び越えた。" + TranslationMarkup.Plain(t).Length),
        };
        var corpus = new HashSet<string>();
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_CORPUS") is { Length: > 0 } dir && Directory.Exists(dir))
            foreach (var file in Directory.GetFiles(dir, "*.pdf").Order())
            {
                var pdf = File.ReadAllBytes(file);
                int pages;
                using (var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null)) pages = engine.PageCount;
                for (var page = 0; page < Math.Min(2, pages); page++)
                {
                    cases.Add(($"{Path.GetFileName(file)} p{page + 1}", pdf, page, "es", Spanish));
                    corpus.Add(cases[^1].Name);
                }
            }

        var failures = new List<string>();
        foreach (var (name, pdf, page, language, answer) in cases)
        {
            var plan = Translation.MakePlan(pdf, null, [page]);
            var answers = new TranslationAnswers();
            foreach (var (text, _) in plan.Texts) answers.Done[text] = answer(text);
            var result = Translation.Apply(plan, answers, language);
            if (result.Data is not { } copy)
            {
                output.WriteLine($"{name}: nothing written");
                continue;
            }
            var got = Words(PdfJs.Text(node, copy, page));
            var solid = Solid(got);
            var before = Words(PdfJs.Text(node, pdf, page));
            int read = 0, missed = 0, own = 0;
            foreach (var (sent, _) in plan.Texts)
            {
                // A paragraph pdf.js doesn't read in order on the original page either (a form's fields beside its label on one
                // line, a drop capital, a word cut by a line-end hyphen) is the page's own order, not the copy's.
                var source = Words(plan.Marked.Contains(sent) ? TranslationMarkup.Plain(sent) : sent);
                if (PdfJs.FirstMiss(source, before) is not null && !Solid(before).Contains(Solid(source), StringComparison.Ordinal))
                {
                    own++;
                    continue;
                }
                var want = Shown(answers.Done[sent]);
                // Word by word in order; where only the spaces differ (a bold "risk—" drawn apart from "About"), letter by letter
                // (Japanese has no spaces to read by: its characters in order, whatever pdf.js puts between its items).
                // Right-to-left text word by word, each stretch's words with their spaces; pdf.js reads a stretch and the
                // number or Latin word beside it together (GlyphOrder.Stretches). A line with a stretch in two fonts (a bold
                // word) is written in reading order: its letters in order, without the spaces.
                var rtl = want.Any(c => c is >= '֐' and <= 'ࣿ');
                var miss = rtl && Spaced.Contains(name) ? PdfJs.FirstMiss(Glued(want), Glued(got)) // a line may end where pdf.js glues
                    : solid.Contains(Solid(want), StringComparison.Ordinal) ? null
                    : want.Contains(' ', StringComparison.Ordinal) && !rtl ? PdfJs.FirstMiss(want, got) : $"“{want}” not read whole";
                if (miss is null) read++;
                else
                {
                    missed++;
                    output.WriteLine($"  {name}: “{(want.Length > 80 ? want[..80] + "…" : want)}”: {miss}");
                }
            }
            output.WriteLine($"{name}: {plan.Texts.Count} texts, {result.Report.Translated} written; pdf.js reads {read} in order{(missed > 0 ? $", {missed} not" : "")}{(own > 0 ? $", {own} not in the original either" : "")}");
            // The test's own pages read whole; a real page may have a paragraph or so whose new lines land among a form row's
            // other fields, read in its content's order (f1040 p. 2's "b Routing number d Account number" beside "c Type").
            if (missed > (corpus.Contains(name) ? Math.Max(1, (read + missed) / 50) : 0)) failures.Add($"{name}: pdf.js doesn't read {missed} of {read + missed} texts in order");
        }
        foreach (var f in failures) output.WriteLine("FAIL " + f);
        Assert.Empty(failures);
    }
}
