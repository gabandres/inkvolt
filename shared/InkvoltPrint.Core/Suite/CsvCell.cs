namespace InkvoltPrint.Core.Suite;

/// <summary>
/// One CSV cell (RFC 4180) of text that came from outside (a printer's name, a status string). A cell a spreadsheet would run as a
/// formula gets a leading apostrophe: one starting with =, +, - or @ (OWASP's list), or their fullwidth forms, after any spaces,
/// tabs, line breaks or invisible characters in front of them, which spreadsheets skip when they trim a cell on import.
/// </summary>
public static class CsvCell
{
    public static string Of(string text)
    {
        var start = 0;
        while (start < text.Length && (char.IsWhiteSpace(text[start]) || char.IsControl(text[start])
                                       || char.GetUnicodeCategory(text[start]) == System.Globalization.UnicodeCategory.Format))
            start++;
        if (start < text.Length && text[start] is '=' or '+' or '-' or '@' or '\uFF1D' or '\uFF0B' or '\uFF0D' or '\uFF20') text = "'" + text;
        else if (start > 0 && start == text.Length) text = "";
        return text.AsSpan().IndexOfAny(",\"\r\n") >= 0 ? $"\"{text.Replace("\"", "\"\"", StringComparison.Ordinal)}\"" : text;
    }
}
