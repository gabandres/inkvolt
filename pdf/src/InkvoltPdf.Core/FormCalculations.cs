using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>What a field's value is computed as: nothing, one of Acrobat's simple calculations of chosen fields,
/// simplified field notation, or a script of the form's own (kept as it is).</summary>
public enum CalcKind { None, Sum, Product, Average, Minimum, Maximum, Notation, Custom }

/// <summary>
/// A field's calculation as Prepare Form shows and writes it (the field's /AA /C, in the form's /CO order).
/// <see cref="Fields"/>: the fields a simple calculation reads; <see cref="Notation"/>: the simplified field notation
/// ("Price * Qty"); <see cref="Script"/>: a custom script, kept.
/// </summary>
public sealed record FieldCalc(CalcKind Kind, IReadOnlyList<string> Fields, string Notation = "", string Script = "")
{
    public bool Equals(FieldCalc? other) =>
        other is not null && Kind == other.Kind && Fields.SequenceEqual(other.Fields) && Notation == other.Notation && Script == other.Script;

    public override int GetHashCode() => HashCode.Combine(Kind, Fields.Count, Notation, Script);
}

/// <summary>
/// Calculated form fields, written the way Acrobat writes them so Acrobat's Calculate tab reads them back:
/// <c>AFSimple_Calculate("SUM", new Array ("a", "b"));</c> for a sum, product, average, minimum or maximum, and
/// <c>/** BVCALC Price * Qty EVCALC **/ event.value = …</c> for simplified field notation (the notation in the comment,
/// the JavaScript it stands for after it). Any other calculate script is a custom one and stays untouched. The
/// calculations run when the form is filled (<see cref="FormEditor"/>, through the JavaScript sandbox, in /CO order).
/// </summary>
public static class FormCalculations
{
    /// <summary>The longest script read as one of ours; a longer one is kept as a custom script.</summary>
    private const int MaxScript = 64 * 1024;

    /// <summary>The longest notation accepted, and the most field names in a calculation.</summary>
    public const int MaxNotation = 4000, MaxFields = 500;

    private static readonly TimeSpan RegexLimit = TimeSpan.FromSeconds(1);

    private static readonly Regex SimpleCall = new(
        @"^\s*AFSimple_Calculate\s*\(\s*(?<q>[""'])(?<op>SUM|PRD|AVG|MIN|MAX)\k<q>\s*,\s*(?:new\s+Array\s*\((?<list>.*)\)|\[(?<list>.*)\])\s*\)\s*;?\s*$",
        RegexOptions.Singleline | RegexOptions.CultureInvariant, RegexLimit);

    private static readonly Regex StringLiteral = new(@"""((?:[^""\\]|\\.)*)""|'((?:[^'\\]|\\.)*)'", RegexOptions.Singleline | RegexOptions.CultureInvariant, RegexLimit);

    private static readonly Regex NotationComment = new(@"^\s*/\*\*\s*BVCALC(?<sfn>.*?)EVCALC\s*\*\*/", RegexOptions.Singleline | RegexOptions.CultureInvariant, RegexLimit);

    private static readonly string[] Ops = ["SUM", "PRD", "AVG", "MIN", "MAX"];

    /// <summary>The calculation a field's calculate script is (null: none).</summary>
    public static FieldCalc? Read(string? script)
    {
        if (string.IsNullOrWhiteSpace(script)) return null;
        if (script.Length > MaxScript) return new FieldCalc(CalcKind.Custom, [], Script: script);
        try
        {
            if (SimpleCall.Match(script) is { Success: true } m && Names(m.Groups["list"].Value) is { } names)
                return new FieldCalc(KindOf(m.Groups["op"].Value), names);
            if (NotationComment.Match(script) is { Success: true } n)
            {
                var sfn = n.Groups["sfn"].Value.Trim();
                // Only ours when the script after the comment is what the notation stands for (else someone edited it).
                if (TryCompile(sfn, out var js, out _) && Normalize(script[(n.Index + n.Length)..]) == Normalize(js))
                    return new FieldCalc(CalcKind.Notation, NotationFields(sfn), sfn);
            }
        }
        catch (RegexMatchTimeoutException)
        {
        }
        return new FieldCalc(CalcKind.Custom, [], Script: script);
    }

    private static string Normalize(string js) => new([.. js.Where(c => !char.IsWhiteSpace(c) && c != ';')]);

    private static CalcKind KindOf(string op) => op switch
    {
        "SUM" => CalcKind.Sum,
        "PRD" => CalcKind.Product,
        "AVG" => CalcKind.Average,
        "MIN" => CalcKind.Minimum,
        _ => CalcKind.Maximum,
    };

    /// <summary>The field names of <c>new Array("a", 'b')</c>'s list, or null when it holds anything but string literals.</summary>
    private static List<string>? Names(string list)
    {
        var names = new List<string>();
        var rest = StringLiteral.Replace(list, m =>
        {
            names.Add(Unescape(m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value));
            return "";
        });
        return rest.All(c => c == ',' || char.IsWhiteSpace(c)) && names.Count <= MaxFields ? names : null;
    }

    private static string Unescape(string s)
    {
        if (!s.Contains('\\')) return s;
        var sb = new StringBuilder();
        for (var i = 0; i < s.Length; i++)
        {
            if (s[i] == '\\' && i + 1 < s.Length) i++;
            sb.Append(s[i]);
        }
        return sb.ToString();
    }

    private static string Quote(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n") + "\"";

    /// <summary>The calculate script for <paramref name="calc"/> (a custom one: its own script).</summary>
    public static string ScriptOf(FieldCalc calc) => calc.Kind switch
    {
        CalcKind.Notation => $"/** BVCALC {calc.Notation} EVCALC **/ {Compile(calc.Notation)}",
        CalcKind.Custom => calc.Script,
        CalcKind.None => "",
        _ => $"AFSimple_Calculate({Quote(Ops[(int)calc.Kind - 1])}, new Array ({string.Join(", ", calc.Fields.Select(Quote))}));",
    };

    // ───────────────────────────── Simplified field notation ─────────────────────────────

    private enum TokenKind { Name, Number, Op }

    private readonly record struct Token(TokenKind Kind, string Text);

    /// <summary>
    /// The JavaScript simplified field notation stands for: each field name read as a number
    /// (<c>AFMakeNumber(getField("Price").value)</c>), with numbers, + - * / and brackets as written. Names are as in
    /// Acrobat: letters, digits, '_' and '.', a backslash before any other character ("Unit\ price").
    /// Throws <see cref="DesignRefusal"/> for anything else.
    /// </summary>
    public static string Compile(string notation) =>
        TryCompile(notation, out var js, out var problem) ? js : throw new DesignRefusal(problem!);

    /// <summary>The field names a notation reads, in order of first use.</summary>
    public static IReadOnlyList<string> NotationFields(string notation) =>
        TryTokens(notation, out var tokens, out _) ? [.. tokens.Where(t => t.Kind == TokenKind.Name).Select(t => t.Text).Distinct()] : [];

    private static bool TryCompile(string notation, out string js, out string? problem)
    {
        js = "";
        if (!TryTokens(notation, out var tokens, out problem)) return false;
        // The notation is kept in a comment: nothing in it may end the comment, or hide the marker.
        if (notation.Contains("*/", StringComparison.Ordinal) || notation.Contains("EVCALC", StringComparison.Ordinal)) return Bad(PdfStrings.Form_CalcSyntax, out problem);
        if (tokens.Count == 0)
        {
            problem = PdfStrings.Form_CalcEmpty;
            return false;
        }
        // Checked as an expression: operands and operators alternate, brackets match.
        var depth = 0;
        var expectOperand = true;
        foreach (var t in tokens)
        {
            if (expectOperand)
            {
                if (t.Kind is TokenKind.Name or TokenKind.Number) expectOperand = false;
                else if (t.Text == "(") depth++;
                else if (t.Text is not ("-" or "+")) return Bad(PdfStrings.Form_CalcSyntax, out problem);
            }
            else if (t.Text == ")")
            {
                if (--depth < 0) return Bad(PdfStrings.Form_CalcBrackets, out problem);
            }
            else if (t.Text is "+" or "-" or "*" or "/") expectOperand = true;
            else return Bad(PdfStrings.Form_CalcSyntax, out problem);
            if (depth > 32) return Bad(PdfStrings.Form_CalcSyntax, out problem);
        }
        if (expectOperand) return Bad(PdfStrings.Form_CalcSyntax, out problem);
        if (depth != 0) return Bad(PdfStrings.Form_CalcBrackets, out problem);
        var sb = new StringBuilder("event.value = ");
        foreach (var t in tokens)
        {
            sb.Append(t.Kind switch
            {
                TokenKind.Name => $"AFMakeNumber(getField({Quote(t.Text)}).value)",
                _ => t.Text,
            });
            if (t.Text != "(") sb.Append(' ');
        }
        js = sb.ToString().Replace(" )", ")").TrimEnd() + ";";
        return true;
    }

    private static bool Bad(string message, out string? problem)
    {
        problem = message;
        return false;
    }

    private static bool TryTokens(string notation, out List<Token> tokens, out string? problem)
    {
        tokens = [];
        problem = null;
        if (notation.Length > MaxNotation) return Bad(PdfStrings.Form_CalcTooLong, out problem);
        var i = 0;
        while (i < notation.Length)
        {
            var c = notation[i];
            if (char.IsWhiteSpace(c))
            {
                i++;
                continue;
            }
            if (c is '+' or '-' or '*' or '/' or '(' or ')')
            {
                tokens.Add(new Token(TokenKind.Op, c.ToString()));
                i++;
                continue;
            }
            if (char.IsDigit(c) || c == '.' && i + 1 < notation.Length && char.IsDigit(notation[i + 1]))
            {
                var start = i;
                while (i < notation.Length && (char.IsDigit(notation[i]) || notation[i] == '.')) i++;
                var text = notation[start..i];
                if (!double.TryParse(text, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out _)) return Bad(PdfStrings.Form_CalcSyntax, out problem);
                tokens.Add(new Token(TokenKind.Number, text));
                continue;
            }
            if (char.IsLetter(c) || c is '_' or '\\')
            {
                var sb = new StringBuilder();
                while (i < notation.Length && (char.IsLetterOrDigit(notation[i]) || notation[i] is '_' or '.' or '\\'))
                {
                    if (notation[i] == '\\')
                    {
                        if (i + 1 >= notation.Length) return Bad(PdfStrings.Form_CalcSyntax, out problem);
                        i++;
                    }
                    sb.Append(notation[i++]);
                }
                tokens.Add(new Token(TokenKind.Name, sb.ToString()));
                if (tokens.Count(t => t.Kind == TokenKind.Name) > MaxFields) return Bad(PdfStrings.Form_CalcTooLong, out problem);
                continue;
            }
            problem = Loc.Format(PdfStrings.Form_CalcCharacter, c);
            return false;
        }
        return true;
    }

    /// <summary>A notation written the Acrobat way: names with spaces or symbols get a backslash before those characters.</summary>
    public static string NameInNotation(string name)
    {
        var sb = new StringBuilder();
        foreach (var c in name)
        {
            if (!(char.IsLetterOrDigit(c) || c is '_' or '.')) sb.Append('\\');
            sb.Append(c);
        }
        if (sb.Length > 0 && char.IsDigit(sb[0])) sb.Insert(0, '\\');
        return sb.ToString();
    }
}
