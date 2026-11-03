using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>
/// Certifying with a choice of fields to lock (FieldMDP): the dictionaries as ISO 32000-1 has them (Tables 233, 253, 254,
/// 256), and the verifier holding a later change to them. In the Pro collection: ProTests turns <see cref="Pro.Enforced"/>
/// on meanwhile, and signing with a lock asks it.
/// </summary>
[Collection("Pro")]
public class FieldLockTests
{
    /// <summary>A form with text fields Name, City and Notes, filled in, and no signature yet.</summary>
    internal static byte[] Form() => FormEditor.SetValues(Core2Pdf.Form(
    [
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 600 300 630] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (City) /Rect [72 550 300 580] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Notes) /Rect [72 500 300 530] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
    ]), null, new Dictionary<string, string> { ["Name"] = "Ada", ["City"] = "Ponce", ["Notes"] = "none" });

    private static byte[] Certify(byte[] form, FieldLock? fieldLock)
    {
        using var cert = SigningTests.RsaCert();
        return Signing.Sign(form, null, new SignRequest { Certificate = cert, Certify = CertificationLevel.FormFilling, Lock = fieldLock });
    }

    /// <summary>The file with field <paramref name="name"/>'s value changed in a later incremental update, as another tool would.</summary>
    private static byte[] Change(byte[] pdf, string name, string value)
    {
        int n;
        using (var doc = Core2Pdf.Open(pdf))
            n = doc.Internals.GetAllObjects().OfType<PdfDictionary>().Last(d => d.Elements.GetString("/T") == name).Reference!.ObjectNumber;
        var body = Regex.Replace(SignatureChangeTests.Body(pdf, n), @"/V\s*(\([^)]*\)|<[^>]*>)", $"/V ({value})");
        return SignatureChangeTests.Append(pdf, new Dictionary<int, string> { [n] = body });
    }

    private static SignatureInfo Certification(byte[] pdf) => Signatures.Verify(pdf).Single(s => s.CertificationLevel is not null);

    [Fact]
    public void TheDictionariesAreAsIso32000HasThem()
    {
        var form = Form();
        var signed = Certify(form, new FieldLock(FieldLockAction.Include, ["Name", "City"]));
        var update = Encoding.Latin1.GetString(signed, form.Length, signed.Length - form.Length);

        // Table 253: a DocMDP reference first, then a FieldMDP one with /Data (the catalog: required for FieldMDP in PDF 1.x).
        using var doc = Core2Pdf.Open(signed);
        var catalog = doc.Internals.Catalog;
        var sig = PdfObj.Dict(PdfObj.Dict(catalog.Elements["/Perms"])!.Elements["/DocMDP"])!;
        var refs = PdfObj.Array(sig.Elements["/Reference"])!.Elements.Select(PdfObj.Dict).ToList();
        Assert.Equal(["/DocMDP", "/FieldMDP"], refs.Select(r => PdfObj.NameOf(r!, "/TransformMethod")));
        Assert.All(refs, r => Assert.Equal("/SigRef", PdfObj.NameOf(r!, "/Type")));
        Assert.Same(catalog, PdfObj.Dict(refs[1]!.Elements["/Data"]));
        Assert.Null(refs[0]!.Elements["/Data"]);
        // Table 254: DocMDP's parameters, P 2 and V /1.2.
        var docMdp = PdfObj.Dict(refs[0]!.Elements["/TransformParams"])!;
        Assert.Equal(("/TransformParams", (int?)2, "/1.2"), (PdfObj.NameOf(docMdp, "/Type"), PdfObj.Int(docMdp.Elements["/P"]), PdfObj.NameOf(docMdp, "/V")));
        // Table 256: FieldMDP's parameters, /Action, /Fields as text strings, V /1.2.
        var fieldMdp = PdfObj.Dict(refs[1]!.Elements["/TransformParams"])!;
        Assert.Equal(("/TransformParams", "/Include", "/1.2"), (PdfObj.NameOf(fieldMdp, "/Type"), PdfObj.NameOf(fieldMdp, "/Action"), PdfObj.NameOf(fieldMdp, "/V")));
        Assert.Equal(["Name", "City"], PdfObj.Array(fieldMdp.Elements["/Fields"])!.Elements.Select(e => PdfObj.Str(e)));
        // Table 233: the signature field's /Lock says the same, as a /SigFieldLock (indirect, as the table requires).
        var field = doc.Internals.GetAllObjects().OfType<PdfDictionary>().Single(d => PdfObj.NameOf(d, "/FT") == "/Sig");
        Assert.IsType<PdfSharp.Pdf.Advanced.PdfReference>(field.Elements["/Lock"]);
        var lockDict = PdfObj.Dict(field.Elements["/Lock"])!;
        Assert.Equal(("/SigFieldLock", "/Include"), (PdfObj.NameOf(lockDict, "/Type"), PdfObj.NameOf(lockDict, "/Action")));
        Assert.Equal(["Name", "City"], PdfObj.Array(lockDict.Elements["/Fields"])!.Elements.Select(e => PdfObj.Str(e)));
        // As bytes: the names as names (the strings are checked above, PDFsharp may write them in hex).
        Assert.Matches(@"/TransformMethod\s*/FieldMDP", update);
        Assert.Matches(@"/Action\s*/Include", update);
        Assert.Matches(@"/Type\s*/SigFieldLock", update);

        // All: no /Fields (Table 256: required only for Include and Exclude).
        using var all = Core2Pdf.Open(Certify(Form(), FieldLock.AllFields));
        var allRef = all.Internals.GetAllObjects().OfType<PdfDictionary>()
            .SelectMany(d => PdfObj.Array(d.Elements["/Reference"])?.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>() ?? [])
            .Single(r => PdfObj.NameOf(r, "/TransformMethod") == "/FieldMDP");
        var p = PdfObj.Dict(allRef.Elements["/TransformParams"])!;
        Assert.Equal("/All", PdfObj.NameOf(p, "/Action"));
        Assert.Null(p.Elements["/Fields"]);
    }

    [Fact]
    public void AChangeToALockedFieldIsNotAllowedAndToAnOpenOneItIs()
    {
        // These fields: Name locked, City open.
        var these = Certify(Form(), new FieldLock(FieldLockAction.Include, ["Name"]));
        Assert.Equal(SignatureStatus.Valid, Certification(these).Status);
        var widgets = FormEditor.Read(these, null);
        Assert.True(widgets.Single(w => w.FieldName == "Name").ReadOnly);
        Assert.False(widgets.Single(w => w.FieldName == "City").ReadOnly);
        Assert.Equal(SignatureStatus.ModifiedAfterSigning, Certification(Change(these, "City", "Mayaguez")).Status);
        var s = Certification(Change(these, "Name", "Eve"));
        Assert.Equal(SignatureStatus.DisallowedChanges, s.Status);
        Assert.Contains("locked field \"Name\"", s.Detail);

        // All but these: Notes open, the others locked.
        var allBut = Certify(Form(), new FieldLock(FieldLockAction.Exclude, ["Notes"]));
        Assert.Equal(SignatureStatus.ModifiedAfterSigning, Certification(Change(allBut, "Notes", "late")).Status);
        Assert.Contains("locked field \"City\"", Certification(Change(allBut, "City", "Mayaguez")).Detail);

        // All of them.
        var all = Certify(Form(), FieldLock.AllFields);
        Assert.All(FormEditor.Read(all, null).Where(w => w.Kind == FormFieldKind.Text), w => Assert.True(w.ReadOnly));
        Assert.Equal(SignatureStatus.DisallowedChanges, Certification(Change(all, "Notes", "late")).Status);

        // No lock: filling in after a form-filling certification stays allowed.
        Assert.Equal(SignatureStatus.ModifiedAfterSigning, Certification(Change(Certify(Form(), null), "Name", "Eve")).Status);
    }

    [Fact]
    public void ALockNeedsFieldsThatAreThere()
    {
        var form = Form();
        var none = Assert.Throws<SigningException>(() => Certify(form, new FieldLock(FieldLockAction.Include, [])));
        Assert.Contains("at least one field", none.Message);
        var missing = Assert.Throws<SigningException>(() => Certify(form, new FieldLock(FieldLockAction.Exclude, ["Nmae"])));
        Assert.Contains("\"Nmae\"", missing.Message);
    }

    [Fact]
    public void TheDialogsChoicesMakeTheLocks()
    {
        Assert.Equal(4, FieldLocks.Choices.Count);
        Assert.Null(FieldLocks.From(0, ["Name"]));
        Assert.Equal(FieldLockAction.All, FieldLocks.From(1, [])!.Action);
        Assert.Equal(new[] { "Name" }, FieldLocks.From(2, ["Name"])!.Fields);
        Assert.Equal(FieldLockAction.Exclude, FieldLocks.From(3, ["Notes"])!.Action);
        Assert.All(Enumerable.Range(0, 4), i => Assert.False(string.IsNullOrWhiteSpace(FieldLocks.Note(i))));
        Assert.Contains("lock", Pro.Locked(ProFeature.FieldLocking), StringComparison.OrdinalIgnoreCase);
        Assert.NotEmpty(Pro.Describe(ProFeature.FieldLocking));
        Assert.True(Pro.Allows(ProFeature.FieldLocking)); // the gate stays off, as for the other Pro features
    }
}
