using System.Text;

namespace InkvoltPdf.Core;

/// <summary>
/// Comma-separated values (RFC 4180): fields with a comma, quote, line break or edge spaces are quoted, quotes doubled.
/// Written as UTF-8 with a byte order mark and CRLF line ends, so Excel opens accents and other scripts right. Read
/// leniently: a byte order mark, LF or CRLF, quoted line breaks, and a semicolon or tab separator (Excel's in many
/// locales) found from the header line.
/// </summary>
internal static class Csv
{
    /// <summary>Largest CSV read (rows of a form merge, comments).</summary>
    public const int MaxBytes = 64 * 1024 * 1024;

    public const int MaxRows = 1_000_000;

    public static byte[] Write(IEnumerable<IReadOnlyList<string>> rows)
    {
        var sb = new StringBuilder();
        foreach (var row in rows)
        {
            for (var i = 0; i < row.Count; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append(Quote(row[i]));
            }
            sb.Append("\r\n");
        }
        return [.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes(sb.ToString())];
    }

    public static string Quote(string value)
    {
        // A cell starting with =, + or @ would run as a formula in a spreadsheet, quoted or not (CSV injection): a tab goes
        // in front, which Read takes off again.
        if (value.Length > 0 && value[0] is '=' or '+' or '@' && !double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out _))
            value = "\t" + value;
        var needs = value.Length > 0 && (value[0] == ' ' || value[^1] == ' ' || value[0] == '\t')
            || value.AsSpan().IndexOfAny(",\"\r\n;") >= 0;
        return needs ? "\"" + value.Replace("\"", "\"\"") + "\"" : value;
    }

    /// <summary>The text of CSV bytes: UTF-8 (with or without a byte order mark), UTF-16 with one, else Windows-1252.</summary>
    public static string Decode(byte[] data)
    {
        if (data.Length >= 2 && data[0] == 0xFF && data[1] == 0xFE) return Encoding.Unicode.GetString(data, 2, data.Length - 2);
        if (data.Length >= 2 && data[0] == 0xFE && data[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(data, 2, data.Length - 2);
        var start = data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0;
        try
        {
            return new UTF8Encoding(false, true).GetString(data, start, data.Length - start);
        }
        catch (DecoderFallbackException)
        {
            return Encoding.Latin1.GetString(data);
        }
    }

    /// <summary>The rows of <paramref name="text"/>; empty lines are left out.</summary>
    /// <exception cref="InvalidDataException">Too many rows.</exception>
    public static List<List<string>> Read(string text)
    {
        var sep = Separator(text);
        var rows = new List<List<string>>();
        var row = new List<string>();
        var field = new StringBuilder();
        var quoted = false;
        var wasQuoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (quoted)
            {
                if (c == '"')
                {
                    if (i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                    else quoted = false;
                }
                else field.Append(c);
                continue;
            }
            if (c == '"' && field.Length == 0 && !wasQuoted) { quoted = wasQuoted = true; continue; }
            if (c == sep) { EndField(); continue; }
            if (c is '\r' or '\n')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                EndRow();
                continue;
            }
            field.Append(c);
        }
        if (field.Length > 0 || row.Count > 0 || wasQuoted) EndRow();
        return rows;

        void EndField()
        {
            var value = field.ToString();
            // The guard Write puts in front of formula-like values comes off again.
            if (value.Length > 1 && value[0] == '\t' && value[1] is '=' or '+' or '@') value = value[1..];
            row.Add(value);
            field.Clear();
            wasQuoted = false;
        }

        void EndRow()
        {
            EndField();
            if (row.Count > 1 || row[0].Length > 0)
            {
                if (rows.Count >= MaxRows) throw new InvalidDataException($"The file has more than {MaxRows:N0} rows.");
                rows.Add(row);
            }
            row = [];
        }
    }

    /// <summary>Comma, else a semicolon or a tab when the first line has more of those (outside quotes).</summary>
    private static char Separator(string text)
    {
        int commas = 0, semis = 0, tabs = 0;
        var quoted = false;
        foreach (var c in text)
        {
            if (c == '"') quoted = !quoted;
            else if (!quoted)
            {
                if (c is '\r' or '\n') break;
                if (c == ',') commas++;
                else if (c == ';') semis++;
                else if (c == '\t') tabs++;
            }
        }
        return semis > commas && semis >= tabs ? ';' : tabs > commas ? '\t' : ',';
    }
}
