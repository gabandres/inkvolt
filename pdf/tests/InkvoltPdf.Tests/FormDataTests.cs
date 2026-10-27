using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Form data in and out (roadmap 1.4): XFDF, FDF, CSV and JSON round trips, CSV merges, validation.</summary>
public class FormDataTests
{
    private const string W = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R";

    /// <summary>
    /// A form with every field type: text (max 30), several lines, a check box, a radio group, a combo box, a multi-select
    /// list, a required text, a number whose validate script refuses more than 120, and address.city under a parent.
    /// </summary>
    internal static byte[] Form() => Core2Pdf.Form(
    [
        $"<< {W} /FT /Tx /T (name) /MaxLen 30 /Rect [72 740 300 760] /DA (/Helv 10 Tf 0 g) >>",
        $"<< {W} /FT /Tx /Ff 4096 /T (notes) /Rect [72 660 300 730] /DA (/Helv 10 Tf 0 g) >>",
        $"<< {W} /FT /Btn /T (agree) /V /Off /AS /Off /Rect [72 630 90 648] /AP << /N << /Yes 16 0 R /Off 17 0 R >> >> >>",
        "<< /FT /Btn /Ff 49152 /T (color) /Kids [14 0 R 15 0 R] /V /Off >>",
        $"<< {W} /FT /Ch /Ff 131072 /T (size) /Opt [(S) (M) (L)] /V (M) /Rect [72 560 200 580] /DA (/Helv 10 Tf 0 g) >>",
        $"<< {W} /FT /Ch /Ff 2097152 /T (toppings) /Opt [[(ham) (Ham)] [(egg) (Egg)] [(kale) (Kale)]] /Rect [72 480 200 540] /DA (/Helv 10 Tf 0 g) >>",
        $"<< {W} /FT /Tx /Ff 2 /T (email) /Rect [72 450 300 470] /DA (/Helv 10 Tf 0 g) >>",
        $"<< {W} /FT /Tx /T (age) /Rect [72 420 140 440] /DA (/Helv 10 Tf 0 g) /AA << /V << /S /JavaScript /JS (if \\(Number\\(event.value\\) > 120\\) event.rc = false;) >> >> >>",
        "<< /T (address) /Kids [18 0 R] >>",
    ], more:
    [
        $"<< {W} /Parent 8 0 R /Rect [72 600 90 618] /AS /Off /AP << /N << /Red 16 0 R /Off 17 0 R >> >> >>",
        $"<< {W} /Parent 8 0 R /Rect [120 600 138 618] /AS /Off /AP << /N << /Blue 16 0 R /Off 17 0 R >> >> >>",
        Core2Pdf.Stream("q 0 g 2 2 14 14 re f Q", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
        Core2Pdf.Stream("", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
        $"<< {W} /FT /Tx /Parent 13 0 R /T (city) /Rect [72 390 300 410] /DA (/Helv 10 Tf 0 g) >>",
    ], extraAnnots: "14 0 R 15 0 R 18 0 R");

    private static readonly Dictionary<string, string> Values = new()
    {
        ["name"] = "José, \"Pepe\" Núñez",
        ["notes"] = "Line one\nLine two, with a comma\n= not a formula",
        ["agree"] = "Yes",
        ["color"] = "Blue",
        ["size"] = "L",
        ["toppings"] = "ham\nkale",
        ["email"] = "pepe@example.com",
        ["age"] = "42",
        ["address.city"] = "San Juan 🌴",
    };

    private static Dictionary<string, string> Read(byte[] pdf) => FormEditor.DataFields(pdf, null).ToDictionary(f => f.Name, f => f.Value);

    [Fact]
    public void FormHasEveryFieldType()
    {
        var fields = FormEditor.DataFields(Form(), null);
        Assert.Equal(Values.Keys.Order(), fields.Select(f => f.Name).Order());
        Assert.Contains(fields, f => f.Kind == FormFieldKind.CheckBox);
        Assert.Contains(fields, f => f.Kind == FormFieldKind.Radio);
        Assert.Contains(fields, f => f.MultiSelect);
        Assert.True(fields.Single(f => f.Name == "email").Required);
    }

    [Theory]
    [InlineData(FormDataFormat.Xfdf)]
    [InlineData(FormDataFormat.Fdf)]
    [InlineData(FormDataFormat.Csv)]
    [InlineData(FormDataFormat.Json)]
    public void RoundTripsEveryFieldType(FormDataFormat format)
    {
        var filled = FormEditor.Fill(Form(), null, Values);
        Assert.Empty(filled.Rejected);
        var expected = Read(filled.Data);
        Assert.Equal("Yes", expected["agree"]);
        Assert.Equal("ham\nkale", expected["toppings"]);

        var file = FormDataFiles.Export(filled.Data, null, format, "form.pdf");
        Assert.Equal(format, FormDataFiles.Sniff(file));
        var back = FormDataFiles.Import(Form(), null, file);
        Assert.Empty(back.Rejected);
        Assert.Empty(back.Unknown);
        Assert.Equal(expected, Read(back.Data));
    }

    [Fact]
    public void CsvQuotesCommasQuotesLineBreaksAndUnicode()
    {
        var rows = new List<IReadOnlyList<string>>
        {
            new[] { "plain", "comma", "quote", "lines", "unicode", "formula", "spaces", "" },
            new[] { "a", "1,5", "say \"hi\"", "x\r\ny\nz", "日本語 — ñ 🌴", "=SUM(A1)", " padded ", "" },
        };
        var bytes = Csv.Write(rows);
        Assert.True(bytes.AsSpan().StartsWith(Encoding.UTF8.GetPreamble()));
        var text = Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
        Assert.Contains("\"1,5\"", text);
        Assert.Contains("\"say \"\"hi\"\"\"", text);
        Assert.Contains("\t=SUM(A1)", text); // a spreadsheet won't run it
        var read = Csv.Read(Csv.Decode(bytes));
        Assert.Equal(2, read.Count);
        Assert.Equal(rows[0], read[0]);
        Assert.Equal(["a", "1,5", "say \"hi\"", "x\r\ny\nz", "日本語 — ñ 🌴", "=SUM(A1)", " padded ", ""], read[1]);

        // Excel's semicolon CSV, Windows-1252 without a byte order mark, a missing last cell.
        var semi = Encoding.Latin1.GetBytes("name;notes;size\r\nJosé;\"a;b\";S\r\nAna;x\r\n");
        var t = Csv.Read(Csv.Decode(semi));
        Assert.Equal(["José", "a;b", "S"], t[1]);
        Assert.Equal(["Ana", "x"], t[2]);
    }

    [Fact]
    public void JsonTakesNestedObjectsNumbersAndBooleans()
    {
        var json = """{ "fields": { "name": "Ana", "age": 37, "agree": true, "toppings": ["egg"], "address": { "city": "Ponce" } } }""";
        var r = FormDataFiles.Import(Form(), null, Encoding.UTF8.GetBytes(json));
        Assert.Empty(r.Rejected);
        var v = Read(r.Data);
        Assert.Equal("Ana", v["name"]);
        Assert.Equal("37", v["age"]);
        Assert.Equal("Yes", v["agree"]);
        Assert.Equal("egg", v["toppings"]);
        Assert.Equal("Ponce", v["address.city"]);
    }

    [Fact]
    public void ImportReportsUnknownNamesAndRefusedValues()
    {
        var csv = Encoding.UTF8.GetBytes("name,size,ghost,age\r\nAna,XL,boo,200\r\nBo,S,,1\r\n");
        var r = FormDataFiles.Import(Form(), null, csv);
        Assert.Equal(["ghost"], r.Unknown);
        Assert.Contains(r.Rejected, x => x.FieldName == "size" && x.Message.Contains("isn't one of its choices"));
        Assert.Contains(r.Rejected, x => x.FieldName == "age"); // the form's validate script
        Assert.Single(r.Notes); // only the first row was used
        Assert.Equal("Ana", Read(r.Data)["name"]);
    }

    [Fact]
    public void MergeMakesOneFilledFormPerRow()
    {
        var folder = Path.Combine(Path.GetTempPath(), "inkvolt-merge-" + Guid.NewGuid().ToString("N"));
        try
        {
            var csv = new StringBuilder("name,notes,agree,color,size,toppings,email,age,address.city,last\r\n");
            for (var i = 1; i <= 200; i++)
                csv.Append($"\"Person {i}, Jr.\",\"note {i}\nsecond line\",{(i % 2 == 0 ? "TRUE" : "no")},{(i % 3 == 0 ? "Red" : "Blue")},{"SML"[i % 3]},\"ham\negg\",p{i}@example.com,{i % 100},Città {i},Núñez{i}\r\n");
            var form = Form();
            var formPath = Path.Combine(folder, "intake.pdf");
            var report = FormMerge.Run(form, null, Encoding.UTF8.GetBytes(csv.ToString()), formPath,
                new FormMergeOptions { OutputFolder = folder, NameTemplate = "<<last>> <<n:3>>" });

            Assert.Equal(200, report.Made.Count);
            Assert.Empty(report.Failed);
            Assert.Equal(["last"], report.UnknownColumns);
            Assert.Equal(200, Directory.GetFiles(folder, "*.pdf").Length);
            foreach (var row in report.Made)
            {
                var i = row.Row;
                Assert.Equal(Path.Combine(folder, $"Núñez{i} {i:D3}.pdf"), row.File);
                var v = Read(File.ReadAllBytes(row.File!));
                Assert.Equal($"Person {i}, Jr.", v["name"]);
                Assert.Equal($"note {i}\nsecond line", v["notes"].Replace("\r", ""));
                Assert.Equal(i % 2 == 0 ? "Yes" : "Off", v["agree"]);
                Assert.Equal(i % 3 == 0 ? "Red" : "Blue", v["color"]);
                Assert.Equal("SML"[i % 3].ToString(), v["size"]);
                Assert.Equal("ham\negg", v["toppings"]);
                Assert.Equal($"p{i}@example.com", v["email"]);
                Assert.Equal((i % 100).ToString(), v["age"]);
                Assert.Equal($"Città {i}", v["address.city"]);
            }
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, true);
        }
    }

    [Fact]
    public void MergeReportsEachRowThatFailsValidation()
    {
        var folder = Path.Combine(Path.GetTempPath(), "inkvolt-merge-" + Guid.NewGuid().ToString("N"));
        try
        {
            var csv = "name,size,email,age,agree\r\n" +
                      "Good,S,a@x.com,30,yes\r\n" +
                      "Bad size,XL,b@x.com,30,yes\r\n" +
                      "This name is far longer than thirty characters,M,c@x.com,30,no\r\n" +
                      "No email,M,,30,no\r\n" +
                      "Too old,M,d@x.com,130,no\r\n" +
                      "Odd box,M,e@x.com,30,maybe\r\n" +
                      "Two problems,XXL,,30,no\r\n" +
                      "Also good,L,f@x.com,99,TRUE\r\n";
            var report = FormMerge.Run(Form(), null, Encoding.UTF8.GetBytes(csv), Path.Combine(folder, "f.pdf"), new FormMergeOptions { OutputFolder = folder });
            Assert.Equal([1, 8], report.Made.Select(r => r.Row));
            Assert.Equal([2, 3, 4, 5, 6, 7], report.Failed.Select(r => r.Row));
            Assert.Contains("isn't one of its choices", report.Failed[0].Problems.Single());
            Assert.Contains("at most 30 characters", report.Failed[1].Problems.Single());
            Assert.Contains("required", report.Failed[2].Problems.Single());
            Assert.StartsWith("age", report.Failed[3].Problems.Single());
            Assert.Contains("isn't one of its states", report.Failed[4].Problems.Single());
            Assert.Equal(2, report.Failed[5].Problems.Count);
            Assert.Equal(2, Directory.GetFiles(folder, "*.pdf").Length);
            Assert.Equal("2 forms made, 6 rows failed.", report.Text);

            var lines = Csv.Read(Csv.Decode(report.Csv()));
            Assert.Equal(9, lines.Count);
            Assert.Equal(["2", "Failed", ""], lines[2].Take(3));
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, true);
        }
    }

    [Fact]
    public void MergeNamePatternMustNameRealColumns()
    {
        Assert.Null(FormMerge.ValidateTemplate("<<name>> <<Last name>> <<n:3>>", ["Last name"]));
        Assert.Contains("<<surname>>", FormMerge.ValidateTemplate("<<surname>>", ["Last name"]));
        Assert.Equal("a_b 7", FormMerge.FileName("<<x>> <<n>>", ["x"], ["a/b"], @"C:\f.pdf", 7, DateTime.Today));
    }

    [Fact]
    public async Task CommandLineFillsFormsFromACsv()
    {
        var folder = Path.Combine(Path.GetTempPath(), "inkvolt-fill-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var form = Path.Combine(folder, "form.pdf");
            var csv = Path.Combine(folder, "rows.csv");
            File.WriteAllBytes(form, Form());
            File.WriteAllText(csv, "name,email,size\r\nAna,a@x.com,S\r\nBo,b@x.com,Q\r\n");
            var output = new StringWriter();
            var error = new StringWriter();
            var code = await BatchCommandLine.RunAsync(["--fill", form, csv, "--name", "<<email>> filled"], output, error, new BatchHost(), CancellationToken.None);
            Assert.Equal(BatchCommandLine.SomeFailed, code);
            Assert.True(File.Exists(Path.Combine(folder, "form forms", "a@x.com filled.pdf")));
            Assert.True(File.Exists(Path.Combine(folder, "form forms", "form merge report.csv")));
            Assert.Contains("failed   row 2", error.ToString());
            Assert.Contains("1 form made, 1 row failed.", output.ToString());
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }
}
