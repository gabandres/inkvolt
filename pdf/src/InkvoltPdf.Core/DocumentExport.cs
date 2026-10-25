using System.Text;

namespace InkvoltPdf.Core;

/// <summary>
/// Export to Word, Excel and plain text. Pages come in one at a time (read from the PDF, or recognized by OCR); each
/// format lays the whole document out once all pages are in (body size and heading levels are document-wide).
/// </summary>
public static class DocumentExport
{
    /// <summary>Writes a .docx. Pictures are stored as each page arrives; only the text is kept until the end.</summary>
    public static void WriteDocx(Stream output, IEnumerable<ExportPage> pages, string? title)
    {
        using var writer = new DocxWriter(output);
        var kept = new List<ExportPage>();
        foreach (var page in pages)
            kept.Add(page.Images.Count == 0 ? page : page with
            {
                Images = [.. page.Images.Where(i => DocLayout.Keeps(page, i)).Select(i => i with { Data = [], Ref = writer.AddImage(i.Data, i.Extension) })],
            });
        writer.Finish(DocLayout.AnalyzeDocument(kept), title);
    }

    /// <summary>The tables found on the pages, named after their page ("Page 3", "Page 3 (2)"); page numbers are 1-based.</summary>
    public static List<(string Name, DocTable Table)> Tables(IEnumerable<(int PageNumber, ExportPage Page)> pages)
    {
        var list = pages.Select(p => (p.PageNumber, Page: p.Page.WithoutImages())).ToList();
        var laid = DocLayout.Analyze([.. list.Select(p => p.Page)]);
        var tables = new List<(string, DocTable)>();
        for (var i = 0; i < laid.Count; i++)
        {
            var onPage = laid[i].Blocks.OfType<DocTable>().ToList();
            for (var k = 0; k < onPage.Count; k++)
                tables.Add((k == 0 ? $"Page {list[i].PageNumber}" : $"Page {list[i].PageNumber} ({k + 1})", onPage[k]));
        }
        return tables;
    }

    /// <summary>
    /// Plain text in reading order: one paragraph per line with a blank line between paragraphs, table rows as
    /// tab-separated cells, list items with a bullet ("• ").
    /// </summary>
    public static string PlainText(IEnumerable<ExportPage> pages)
    {
        var laid = DocLayout.Analyze([.. pages.Select(p => p.WithoutImages())]);
        var sb = new StringBuilder();
        foreach (var page in laid)
        {
            foreach (var block in page.Blocks)
            {
                switch (block)
                {
                    case DocParagraph p:
                        if (p.List == ListKind.Bullet) sb.Append("• ");
                        sb.Append(OneLine(p.Text)).Append("\r\n\r\n");
                        break;
                    case DocTable t:
                        foreach (var row in t.Rows)
                        {
                            var cells = new List<string>();
                            foreach (var cell in row)
                            {
                                cells.Add(OneLine(cell.Text));
                                for (var k = 1; k < cell.ColSpan; k++) cells.Add("");
                            }
                            sb.Append(string.Join('\t', cells).TrimEnd('\t')).Append("\r\n");
                        }
                        sb.Append("\r\n");
                        break;
                }
            }
        }
        return sb.ToString().TrimEnd() + "\r\n";

        static string OneLine(string s) => s.Replace("\r", " ").Replace('\n', ' ').Replace('\t', ' ');
    }
}
