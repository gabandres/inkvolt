using System.Buffers.Binary;
using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>PDF/A-2 levels: B keeps the look; A also keeps the structure (tags, language, Unicode text) for accessibility.</summary>
public enum PdfAConformance { B, A }

/// <summary>A document can't be made PDF/A-2b (or 2a); <see cref="Blockers"/> says why (nothing was changed).</summary>
public sealed class PdfAException(IReadOnlyList<string> blockers)
    : InvalidOperationException("This PDF can't be saved as PDF/A: " + string.Join(" ", blockers))
{
    public IReadOnlyList<string> Blockers { get; } = blockers;
}

/// <param name="Changes">What was changed to conform, in words (removed scripts, embedded fonts, ...).</param>
public sealed record PdfAResult(byte[] Data, IReadOnlyList<string> Changes);

/// <summary>
/// Save as PDF/A-2b (ISO 19005-2, level B: the look is preserved for archiving). A copy is made that:
/// is unencrypted; carries an sRGB output intent (<see cref="IccProfiles.Srgb"/>, a profile written here) and a new XMP
/// packet with pdfaid part 2, conformance B, matching the document properties; has no JavaScript, forbidden actions
/// (Launch, Sound, Movie, ResetForm, ImportData, Hide, SetOCGState, Rendition, Trans, GoTo3DView, named actions other
/// than page navigation), additional actions, XFA, multimedia or embedded files; whose annotations print and have a normal
/// appearance only (hidden ones and ones without an appearance are removed; form fields get appearances first); whose
/// images don't interpolate or carry alternates or OPI; with LZW streams re-encoded with Flate, transfer and halftone
/// functions dropped, optional-content configurations named, names over 127 bytes shortened; with XMP only in the catalog
/// (other packets, a picture's from Photoshop, hold properties outside PDF/A's schemas); and whose fonts are all embedded: the standard Helvetica,
/// Times and Courier faces (also named Arial, Times New Roman, Courier New) are embedded from Windows' metric-compatible
/// fonts (a subset, WinAnsi with differences), ZapfDingbats from Windows' Segoe UI Symbol (a symbolic subset, as its
/// symbols have no names a validator accepts), CIDSet and CharSet removed. What can't be fixed without changing the
/// look refuses the conversion (<see cref="PdfAException"/>): other fonts that aren't embedded, CMYK color without a
/// profile (the output intent is RGB), PostScript or external content, digital signatures (a rewrite would break them),
/// widgets without appearances. <see cref="Validate"/> checks the rules handled here; it is not a full validator.
/// </summary>
public static class PdfA
{
    private static readonly HashSet<string> ForbiddenActions =
        ["Launch", "Sound", "Movie", "ResetForm", "ImportData", "Hide", "SetOCGState", "Rendition", "Trans", "GoTo3DView", "JavaScript", "RichMediaExecute", "SetState", "NOP"];

    private static readonly HashSet<string> AllowedNamed = ["NextPage", "PrevPage", "FirstPage", "LastPage"];

    private static readonly HashSet<string> RemovedAnnotations = ["Sound", "Movie", "Screen", "3D", "RichMedia", "FileAttachment", "TrapNet"];

    private const int FlagInvisible = 1, FlagHidden = 2, FlagPrint = 4, FlagNoView = 32, FlagToggleNoView = 256;

    /// <summary>What stops <paramref name="data"/> from being made PDF/A-2b (empty: it can be). Nothing is changed.</summary>
    /// <exception cref="OwnerPasswordRequiredException">An encrypted document opened without its permissions password.</exception>
    public static IReadOnlyList<string> Check(byte[] data, string? password)
    {
        try
        {
            Convert(data, password);
            return [];
        }
        catch (PdfAException ex)
        {
            return ex.Blockers;
        }
    }

    /// <summary>
    /// Makes a PDF/A-2b copy of the document (see the class remarks). <see cref="PdfAConformance.A"/> (PDF/A-2a) needs a
    /// tagged document with a language (Make Accessible makes one); its tags are kept, and a document that says it is
    /// PDF/UA keeps saying so (with the extension schema PDF/A requires for that).
    /// </summary>
    /// <exception cref="PdfAException">Something can't be made conforming without changing the look, or (2a) it isn't tagged.</exception>
    /// <exception cref="OwnerPasswordRequiredException">An encrypted document opened without its permissions password.</exception>
    public static PdfAResult Convert(byte[] data, string? password, DateTime? now = null, PdfAConformance conformance = PdfAConformance.B)
    {
        var changes = new List<string>();
        if (Incremental.LooksSigned(data) && Signatures.Verify(data, password).Any(s => s.Status != SignatureStatus.Unsigned))
            throw new PdfAException(["It is digitally signed: a PDF/A copy is a rewrite, which would break the signatures. (Sanitize can remove them first.)"]);

        // No field is signed, yet a /ByteRange can still make the file look so: usage rights, whose signature no person
        // made, or what an earlier revision left behind. A rewrite breaks nothing of anybody's, so it is allowed below.
        if (PdfSecurity.ReadSecurity(data, password).IsEncrypted)
        {
            data = SignedEdits.Run(() => PdfSecurity.Unprotect(data, password), allowRewrite: true).Data;
            changes.Add("password protection removed (PDF/A files can't be encrypted)");
        }

        if (Incremental.LooksSigned(data))
        {
            using var read = PdfObj.Open(data, null, PdfDocumentOpenMode.Import, "This PDF can't be converted");
            var perms = PdfObj.Dict(read.Internals.Catalog.Elements["/Perms"]);
            if (perms?.Elements.ContainsKey("/DocMDP") == true)
                throw new PdfAException(["It is certified: a PDF/A copy is a rewrite, which would break the certification. (Sanitize can remove it first.)"]);
            if (perms?.Elements.ContainsKey("/UR3") == true || perms?.Elements.ContainsKey("/UR") == true)
                changes.Add("Reader usage rights removed (the form maker's seal, not a person's signature; a rewritten copy would void it)");
        }

        // Scripts, actions that run things, multimedia, XFA and attached files: what Sanitize removes.
        SanitizeResult sanitized = null!;
        SignedEdits.Run(() => (sanitized = Sanitizer.Sanitize(data, null, new HashSet<SanitizeItem> { SanitizeItem.ActiveContent, SanitizeItem.EmbeddedFiles })).Data, allowRewrite: true);
        if (sanitized.Removed[SanitizeItem.ActiveContent] > 0) changes.Add($"{Count(sanitized.Removed[SanitizeItem.ActiveContent], "script or active item", "scripts and active items")} removed");
        if (sanitized.Removed[SanitizeItem.EmbeddedFiles] > 0) changes.Add($"{Count(sanitized.Removed[SanitizeItem.EmbeddedFiles], "attached file", "attached files")} removed");
        data = sanitized.Data;

        using var doc = PdfObj.Open(data, null, PdfDocumentOpenMode.Modify, "This PDF can't be converted");
        var pdfUa = false;
        if (conformance == PdfAConformance.A)
        {
            var catalog = doc.Internals.Catalog;
            var blockers = new List<string>();
            if (!catalog.Elements.ContainsKey("/StructTreeRoot") || PdfObj.Resolve(PdfObj.Dict(catalog.Elements["/MarkInfo"])?.Elements["/Marked"]) is not PdfBoolean { Value: true })
                blockers.Add("It isn't tagged: PDF/A-2a keeps the document's structure, so tag it first (Review › Make Accessible).");
            if (!AccessibilityCheck.IsLanguage(PdfObj.Text(catalog.Elements["/Lang"])))
                blockers.Add("It doesn't say its language: PDF/A-2a needs one (Make Accessible sets it).");
            if (blockers.Count > 0) throw new PdfAException(blockers);
            pdfUa = Xmp.SaysPdfUa(Xmp.Read(doc));
            // Level A wants every character's Unicode value (6.2.11.7.2): TeX's math glyphs get theirs.
            if (FontUnicode.Complete(doc) is var fonts and > 0) changes.Add($"{Count(fonts, "font", "fonts")} given the Unicode values of their characters");
        }
        var pass = new Pass(doc, changes);
        pass.Run();
        if (pass.Blockers.Count > 0) throw new PdfAException([.. pass.Blockers.Distinct()]);

        if (doc.Version > 17 || doc.Version < 14) doc.Version = 17;
        doc.Info.ModificationDate = now ?? DateTime.Now;
        Xmp.CleanInfo(doc.Info); // the XMP packet carries the same values (6.6.2.3): trimmed, without control characters
        doc.Info.Elements.Remove("/Trapped"); // optional, and a wrong value would break conformance
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        var packet = Xmp.BuildPdfA(doc.Info, conformance.ToString(), pdfUa);
        var result = Xmp.ReplacePacket(ms.GetBuffer().AsSpan(0, (int)ms.Length), packet)
                     ?? throw new InvalidOperationException("The PDF/A metadata couldn't be written.");
        if (Validate(result, conformance) is { Count: > 0 } left) throw new PdfAException(left);
        return new PdfAResult(result, changes);
    }

    /// <summary>
    /// Embeds the standard Helvetica, Times and Courier faces the document draws with but doesn't embed, as the PDF/A copy
    /// does (Windows' metric-compatible fonts); other fonts are left as they are. How many were embedded.
    /// </summary>
    internal static int EmbedStandardFonts(PdfDocument doc)
    {
        var pass = new Pass(doc, []);
        pass.Fonts();
        return pass.Embedded;
    }

    private static string Count(int n, string one, string many) => n == 1 ? $"1 {one}" : $"{n} {many}";

    /// <summary>
    /// The base-14 Latin face a font name stands for, and so the Windows font with its metrics: the standard names
    /// (Helvetica-Bold, Times-Roman, Courier-Oblique ...) and the Windows twins as PDF writers name them (Arial,Bold;
    /// Arial-BoldMT; TimesNewRomanPS-ItalicMT; CourierNew,BoldItalic), with a subset prefix or not. Null for anything else:
    /// other designs of the family (Helvetica Neue, condensed, narrow, black) have other widths.
    /// </summary>
    internal static StdFont? StandardFace(string baseFont)
    {
        var n = baseFont.TrimStart('/');
        if (n.Length > 7 && n[6] == '+') n = n[7..];
        n = n.Replace(" ", "", StringComparison.Ordinal);
        string family, style;
        if (n.IndexOf(',') is >= 0 and var comma) (family, style) = (n[..comma], n[(comma + 1)..]);
        else if (n.IndexOf('-') is >= 0 and var dash) (family, style) = (n[..dash], n[(dash + 1)..]);
        else (family, style) = (n, "");
        foreach (var tail in new[] { "PSMT", "MT", "PS" })
            if (family.EndsWith(tail, StringComparison.Ordinal)) family = family[..^tail.Length];
        if (style.EndsWith("MT", StringComparison.Ordinal)) style = style[..^2];
        StdFamily? f = family switch
        {
            "Helvetica" or "Arial" => StdFamily.Helvetica,
            "Times" or "TimesNewRoman" => StdFamily.Times,
            "Courier" or "CourierNew" => StdFamily.Courier,
            _ => null,
        };
        (bool Bold, bool Italic)? s = style switch
        {
            "" or "Roman" or "Regular" or "Normal" => (false, false),
            "Bold" => (true, false),
            "Italic" or "Oblique" => (false, true),
            "BoldItalic" or "BoldOblique" => (true, true),
            _ => null,
        };
        return f is { } fam && s is { } st ? new StdFont(fam, st.Bold, st.Italic) : null;
    }

    // ───────────────────────────── the pass ─────────────────────────────

    private sealed class Pass(PdfDocument doc, List<string> changes)
    {
        public readonly List<string> Blockers = [];
        private int _removedAnnots, _hiddenAnnots, _actions, _aa, _images, _lzw, _tr, _embedded, _dingbats, _ocNames, _ownMetadata;
        private readonly Dictionary<PdfDictionary, PdfDictionary?> _substitutes = new(ReferenceEqualityComparer.Instance);

        public void Run()
        {
            var catalog = doc.Internals.Catalog;
            catalog.Elements.Remove("/AA");
            catalog.Elements.Remove("/NeedsRendering");
            catalog.Elements.Remove("/Perms");
            if (PdfObj.Dict(catalog.Elements["/AcroForm"]) is { } acro)
            {
                acro.Elements.Remove("/XFA");
                FormEditor.EnsureAppearances(doc, acro);
                acro.Elements.Remove("/NeedAppearances");
            }

            foreach (var page in doc.Pages)
            {
                page.Elements.Remove("/AA");
                page.Elements.Remove("/PresSteps");
                Annotations(page);
            }

            // Everything reachable from the catalog (what a validator reads), each object once.
            foreach (var d in Reachable(catalog)) Visit(d);
            Fonts();
            OptionalContent(catalog);
            OutputIntent(catalog);
            var longNames = ShortenLongNames(catalog);

            if (_removedAnnots > 0) changes.Add($"{Count(_removedAnnots, "comment or field", "comments and fields")} that PDF/A doesn't allow, or without an appearance, removed");
            if (_hiddenAnnots > 0) changes.Add($"{Count(_hiddenAnnots, "hidden comment", "hidden comments")} removed");
            if (_actions + _aa > 0) changes.Add($"{Count(_actions + _aa, "action", "actions")} PDF/A doesn't allow removed");
            if (_images > 0) changes.Add($"smoothing and alternate versions PDF/A doesn't allow taken off {Count(_images, "picture", "pictures")}");
            if (_lzw > 0) changes.Add($"{Count(_lzw, "LZW stream", "LZW streams")} re-compressed");
            if (_tr > 0) changes.Add("transfer and halftone functions removed");
            if (_embedded > 0) changes.Add($"{Count(_embedded, "standard font", "standard fonts")} embedded");
            if (_dingbats > 0) changes.Add("check marks and other ZapfDingbats symbols embedded from Segoe UI Symbol, whose shapes differ a little");
            if (_ocNames > 0) changes.Add("layer configurations named");
            if (_ownMetadata > 0) changes.Add($"{Count(_ownMetadata, "picture's or page's own metadata packet", "pictures' and pages' own metadata packets")} removed");
            if (longNames > 0) changes.Add($"{Count(longNames, "name", "names")} longer than PDF/A allows shortened");
            changes.Add("sRGB output intent and PDF/A metadata added");
        }

        /// <summary>Annotations PDF/A forbids or that wouldn't show are removed; the rest print, and keep only their normal appearance.</summary>
        private void Annotations(PdfPage page)
        {
            if (PdfObj.Array(page.Elements["/Annots"]) is not { } annots) return;
            for (var i = annots.Elements.Count - 1; i >= 0; i--)
            {
                if (PdfObj.Dict(annots.Elements[i]) is not { } a)
                {
                    annots.Elements.RemoveAt(i);
                    continue;
                }
                var subtype = PdfObj.Name(a.Elements["/Subtype"]) ?? "";
                var flags = PdfObj.Int(a.Elements["/F"]) ?? 0;
                if (RemovedAnnotations.Contains(subtype))
                {
                    annots.Elements.RemoveAt(i);
                    _removedAnnots++;
                    continue;
                }
                if (subtype != "Popup" && (flags & (FlagHidden | FlagNoView)) != 0)
                {
                    annots.Elements.RemoveAt(i);
                    _hiddenAnnots++;
                    continue;
                }
                var rect = PdfObj.Array(a.Elements["/Rect"]);
                var zero = rect is null || Math.Abs(PdfObj.Num(rect, 2) - PdfObj.Num(rect, 0)) < 1e-6 || Math.Abs(PdfObj.Num(rect, 3) - PdfObj.Num(rect, 1)) < 1e-6;
                var ap = PdfObj.Dict(a.Elements["/AP"]);
                if (ap is not null)
                {
                    ap.Elements.Remove("/R");
                    ap.Elements.Remove("/D");
                }
                var hasNormal = ap?.Elements["/N"] is not null;
                if (!hasNormal && subtype is not ("Popup" or "Link") && !zero)
                {
                    if (subtype == "Widget")
                    {
                        Blockers.Add("A form field has no appearance of its own, so it can't be shown the same everywhere.");
                        continue;
                    }
                    annots.Elements.RemoveAt(i);
                    _removedAnnots++;
                    continue;
                }
                if (!hasNormal && ap is not null) a.Elements.Remove("/AP");
                // Every annotation prints and shows (popups too: their flags are only for the pop-up window).
                a.Elements["/F"] = new PdfInteger((flags | FlagPrint) & ~(FlagInvisible | FlagHidden | FlagNoView | FlagToggleNoView));
            }
        }

        /// <summary>Checks and fixes one dictionary (or stream) by what it is.</summary>
        private void Visit(PdfDictionary d)
        {
            if (d.Elements.Remove("/AA")) _aa++;
            if (!ReferenceEquals(d, doc.Internals.Catalog) && d.Elements.Remove("/Metadata")) _ownMetadata++;
            foreach (var key in new[] { "/A", "/OpenAction", "/PA" })
                if (PdfObj.Dict(d.Elements[key]) is { } action && IsForbidden(action))
                {
                    d.Elements.Remove(key);
                    _actions++;
                }
            if (PdfObj.Resolve(d.Elements["/Next"]) is { } next)
            {
                if (next is PdfDictionary nd && IsForbidden(nd))
                {
                    d.Elements.Remove("/Next");
                    _actions++;
                }
                else if (next is PdfArray na)
                    for (var i = na.Elements.Count - 1; i >= 0; i--)
                        if (PdfObj.Dict(na.Elements[i]) is { } x && IsForbidden(x))
                        {
                            na.Elements.RemoveAt(i);
                            _actions++;
                        }
            }

            var subtype = PdfObj.Name(d.Elements["/Subtype"]);
            var type = PdfObj.Name(d.Elements["/Type"]);
            if (d.Stream is not null)
            {
                if (d.Elements.ContainsKey("/F") && (d.Elements.ContainsKey("/FFilter") || type is null && subtype is null && !d.Elements.ContainsKey("/Length")))
                    Blockers.Add("It refers to content in another file (an external stream).");
                ReencodeLzw(d);
            }
            switch (subtype)
            {
                case "Image":
                    var changed = d.Elements.Remove("/Alternates") | d.Elements.Remove("/OPI");
                    if (PdfObj.Resolve(d.Elements["/Interpolate"]) is PdfBoolean { Value: true })
                    {
                        d.Elements["/Interpolate"] = new PdfBoolean(false);
                        changed = true;
                    }
                    if (PdfObj.Name(d.Elements["/Intent"]) is { } intent && intent is not ("AbsoluteColorimetric" or "RelativeColorimetric" or "Saturation" or "Perceptual"))
                    {
                        d.Elements.Remove("/Intent");
                        changed = true;
                    }
                    if (changed) _images++;
                    break;
                case "PS":
                    Blockers.Add("It holds PostScript code (a PostScript XObject), which PDF/A doesn't allow.");
                    break;
                case "Form":
                    d.Elements.Remove("/OPI");
                    d.Elements.Remove("/Ref");
                    if (PdfObj.Name(d.Elements["/Subtype2"]) == "PS") Blockers.Add("It holds PostScript code (a PostScript XObject), which PDF/A doesn't allow.");
                    break;
            }
            if (type == "ExtGState" || d.Elements.ContainsKey("/TR") || d.Elements.ContainsKey("/HTP"))
            {
                var tr2 = PdfObj.Name(d.Elements["/TR2"]);
                if (d.Elements.Remove("/TR") | d.Elements.Remove("/HTP") | (tr2 is not null && tr2 != "Default" && d.Elements.Remove("/TR2"))
                    | (PdfObj.Resolve(d.Elements["/TR2"]) is not null and not PdfName && d.Elements.Remove("/TR2")))
                    _tr++;
            }
            if (type == "FontDescriptor")
            {
                d.Elements.Remove("/CIDSet");
                d.Elements.Remove("/CharSet");
            }
            CheckColor(d);
        }

        private static bool IsForbidden(PdfDictionary action)
        {
            if (PdfObj.Name(action.Elements["/S"]) is not { } s) return false;
            if (action.Elements.ContainsKey("/K") || action.Elements.ContainsKey("/P") && !action.Elements.ContainsKey("/Type")) return false; // a structure element
            return ForbiddenActions.Contains(s) || s == "Named" && !AllowedNamed.Contains(PdfObj.Name(action.Elements["/N"]) ?? "");
        }

        private void ReencodeLzw(PdfDictionary d)
        {
            var filter = PdfObj.Resolve(d.Elements["/Filter"]);
            var names = filter switch
            {
                PdfName n => [n.Value],
                PdfArray a => a.Elements.Select(e => (PdfObj.Resolve(e) as PdfName)?.Value ?? "").ToList(),
                _ => new List<string>(),
            };
            if (!names.Any(n => n is "/LZWDecode" or "/LZW")) return;
            var decoded = d.Stream!.UnfilteredValue;
            d.Elements.Remove("/DecodeParms");
            d.Elements.Remove("/DP");
            d.Stream.Value = PdfObj.Deflate(decoded);
            d.Elements["/Filter"] = new PdfName("/FlateDecode");
            d.Elements["/Length"] = new PdfInteger(d.Stream.Value.Length);
            _lzw++;
        }

        /// <summary>CMYK color can't be shown under an RGB output intent without a CMYK profile, which isn't at hand.</summary>
        private void CheckColor(PdfDictionary d)
        {
            foreach (var key in new[] { "/ColorSpace", "/CS" })
            {
                var cs = PdfObj.Resolve(d.Elements[key]);
                if (key == "/ColorSpace" && cs is PdfDictionary resources)
                {
                    foreach (var v in resources.Elements.Values)
                        if (UsesCmyk(PdfObj.Resolve(v))) CmykBlocker();
                }
                else if (UsesCmyk(cs)) CmykBlocker();
            }
            if (d.Stream is not null && IsContent(d)) ScanContent(d);
        }

        /// <summary>Page contents, form XObjects, tiling patterns and Type 3 glyphs (pages' /Contents are marked when walked).</summary>
        private bool IsContent(PdfDictionary d) =>
            _contents.Contains(d) || PdfObj.Name(d.Elements["/Subtype"]) == "Form" || PdfObj.Int(d.Elements["/PatternType"]) == 1;

        private readonly HashSet<PdfDictionary> _contents = new(ReferenceEqualityComparer.Instance);

        private void ScanContent(PdfDictionary d)
        {
            byte[] bytes;
            try
            {
                bytes = d.Stream!.UnfilteredValue;
            }
            catch (Exception ex) when (ex is InvalidOperationException or NotImplementedException or PdfSharp.PdfSharpException)
            {
                return;
            }
            foreach (var op in ContentLexer.Parse(bytes))
            {
                if (op.Operands.Any(o => o.Kind == CKind.Name && NameTooLong(o.Name)))
                {
                    Blockers.Add("Its page content uses a name longer than the 127 bytes PDF/A allows.");
                    return;
                }
                switch (op.Name)
                {
                    case "k" or "K":
                        CmykBlocker();
                        return;
                    case "cs" or "CS" when op.Operands.Count > 0 && op.Operands[^1].Kind == CKind.Name && op.Operands[^1].Name == "DeviceCMYK":
                        CmykBlocker();
                        return;
                    case "BI" when op.Operands.Any(o => o.Kind == CKind.Name && o.Name is "CMYK" or "DeviceCMYK"):
                        CmykBlocker();
                        return;
                    case "BI" when op.Operands.Any(o => o.Kind == CKind.Name && o.Name is "LZW" or "LZWDecode"):
                        Blockers.Add("An inline picture is LZW-compressed, which PDF/A doesn't allow.");
                        return;
                }
            }
        }

        private void CmykBlocker() => Blockers.Add("It uses CMYK color without a color profile; a PDF/A-2b copy here gets an RGB (sRGB) output intent, so that color can't be kept as it is.");

        private static bool UsesCmyk(PdfItem? cs) => cs switch
        {
            PdfName n => n.Value is "/DeviceCMYK" or "/CMYK",
            PdfArray a when a.Elements.Count > 0 => PdfObj.Name(a.Elements[0]) switch
            {
                "Indexed" or "I" => a.Elements.Count > 1 && UsesCmyk(PdfObj.Resolve(a.Elements[1])),
                "Separation" => a.Elements.Count > 2 && UsesCmyk(PdfObj.Resolve(a.Elements[2])),
                "DeviceN" => a.Elements.Count > 2 && UsesCmyk(PdfObj.Resolve(a.Elements[2])),
                "Pattern" => a.Elements.Count > 1 && UsesCmyk(PdfObj.Resolve(a.Elements[1])),
                _ => false,
            },
            _ => false,
        };

        /// <summary>Every dictionary reachable from <paramref name="root"/>, each once (pages' content streams marked as content).</summary>
        private IEnumerable<PdfDictionary> Reachable(PdfDictionary root)
        {
            var seen = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
            var stack = new Stack<PdfItem>();
            stack.Push(root);
            foreach (var page in doc.Pages)
                switch (PdfObj.Resolve(page.Elements["/Contents"]))
                {
                    case PdfDictionary c:
                        _contents.Add(c);
                        break;
                    case PdfArray a:
                        foreach (var c in a.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()) _contents.Add(c);
                        break;
                }
            while (stack.Count > 0)
            {
                var item = stack.Pop();
                var obj = PdfObj.Resolve(item);
                if (obj is not PdfObject o || !seen.Add(o)) continue;
                switch (obj)
                {
                    case PdfDictionary d:
                        yield return d;
                        if (PdfObj.Dict(d.Elements["/CharProcs"]) is { } procs)
                            foreach (var p in procs.Elements.Values.Select(PdfObj.Dict).OfType<PdfDictionary>()) _contents.Add(p);
                        foreach (var key in d.Elements.Keys.ToList())
                            if (key != "/Parent" && key != "/P" && d.Elements[key] is { } value) stack.Push(value);
                        break;
                    case PdfArray a:
                        foreach (var e in a.Elements) stack.Push(e);
                        break;
                }
            }
        }

        // ───────────── fonts ─────────────

        public int Embedded => _embedded + _dingbats;

        public void Fonts()
        {
            // The form's default resources only serve to draw fields anew: a font there that can't be embedded is dropped
            // (the fields keep their appearances), not a reason to refuse.
            var dr = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(doc.Internals.Catalog.Elements["/AcroForm"])?.Elements["/DR"])?.Elements["/Font"]);
            var used = AllFonts(dr);
            if (dr is not null)
                foreach (var key in dr.Elements.Keys.ToList())
                {
                    if (PdfObj.Dict(dr.Elements[key]) is not { } f || used.Contains(f)) continue;
                    var sub = PdfObj.Name(f.Elements["/Subtype"]) ?? "";
                    if (sub == "Type3" || IsEmbedded(PdfObj.Dict(f.Elements["/FontDescriptor"])) ||
                        sub == "Type0" && IsEmbedded(PdfObj.Dict(PdfObj.Dict(PdfObj.Array(f.Elements["/DescendantFonts"])?.Elements.FirstOrDefault())?.Elements["/FontDescriptor"])))
                        continue;
                    if (IsDingbats(FontName(f)) || Substitute(f) is not null) dr.Elements.Remove(key);
                }
            foreach (var font in used)
            {
                var subtype = PdfObj.Name(font.Elements["/Subtype"]) ?? "";
                if (subtype == "Type3") continue;
                if (subtype == "Type0")
                {
                    var descendant = PdfObj.Dict(PdfObj.Array(font.Elements["/DescendantFonts"])?.Elements.FirstOrDefault());
                    if (!IsEmbedded(PdfObj.Dict(descendant?.Elements["/FontDescriptor"])))
                        Blockers.Add($"The font {FontName(font)} isn't embedded, and only the standard fonts can be embedded here.");
                    continue;
                }
                if (IsEmbedded(PdfObj.Dict(font.Elements["/FontDescriptor"]))) continue;
                if (Substitute(font) is { } why) Blockers.Add(why);
            }
        }

        private static string FontName(PdfDictionary font) => PdfObj.Name(font.Elements["/BaseFont"]) ?? "(unnamed)";

        private static bool IsDingbats(string baseFont) => baseFont.Length > 7 && baseFont[6] == '+' ? baseFont[7..] == "ZapfDingbats" : baseFont == "ZapfDingbats";

        private static bool IsEmbedded(PdfDictionary? descriptor) =>
            descriptor is not null && (descriptor.Elements.ContainsKey("/FontFile") || descriptor.Elements.ContainsKey("/FontFile2") || descriptor.Elements.ContainsKey("/FontFile3"));

        /// <summary>
        /// Font dictionaries in the /Font resource dictionaries reachable from the catalog other than <paramref name="defaults"/>
        /// (the form's default resources), i.e. the fonts that content and appearances can draw with.
        /// </summary>
        private HashSet<PdfDictionary> AllFonts(PdfDictionary? defaults)
        {
            var fonts = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
            foreach (var d in Reachable(doc.Internals.Catalog))
                if (PdfObj.Dict(d.Elements["/Font"]) is { } resources && !ReferenceEquals(resources, defaults) && PdfObj.Name(d.Elements["/Type"]) is null or "Resources")
                    foreach (var f in resources.Elements.Values.Select(PdfObj.Dict).OfType<PdfDictionary>())
                        if (PdfObj.Name(f.Elements["/Subtype"]) is not ("CIDFontType0" or "CIDFontType2")) fonts.Add(f);
            return fonts;
        }

        /// <summary>
        /// Embeds a non-embedded standard Latin font (<see cref="StandardFace"/>: Helvetica, Times, Courier and their Windows
        /// twins, in their style) as a TrueType subset of the metric-compatible Windows face, encoded WinAnsi with
        /// differences for the codes the original encoding maps elsewhere. Null when done, else why it can't be: another
        /// font, the Windows face missing, or widths in the document that differ from that face's.
        /// </summary>
        private string? Substitute(PdfDictionary font)
        {
            var subtype = PdfObj.Name(font.Elements["/Subtype"]);
            var name = PdfObj.Name(font.Elements["/BaseFont"]) ?? "";
            if (IsDingbats(name)) return EmbedDingbats(font);
            var notEmbedded = $"The font {FontName(font)} isn't embedded, and only the standard Helvetica, Times, Courier and ZapfDingbats faces can be embedded here.";
            if (subtype is not ("Type1" or "TrueType" or "MMType1") || PdfA.StandardFace(name) is not { } std) return notEmbedded;
            if (std.Metrics is not { } ttf) return $"The font {FontName(font)} isn't embedded, and Windows' matching font isn't installed.";

            // The original code → glyph name map (its encoding, else StandardEncoding as the standard fonts have).
            var names = new string?[256];
            var enc = PdfObj.Resolve(font.Elements["/Encoding"]);
            var baseName = enc switch
            {
                PdfName n => n.Value.TrimStart('/'),
                PdfDictionary e => PdfObj.Name(e.Elements["/BaseEncoding"]) ?? "StandardEncoding",
                _ => "StandardEncoding",
            };
            if (!GlyphNames.IsKnownEncoding(baseName)) baseName = "StandardEncoding";
            for (var c = 0; c < 256; c++) names[c] = GlyphNames.InEncoding(baseName, c);
            if (enc is PdfDictionary ed && PdfObj.Array(ed.Elements["/Differences"]) is { } diffs)
            {
                var code = 0;
                foreach (var item in diffs.Elements.Select(PdfObj.Resolve))
                {
                    if (item is PdfInteger i) code = i.Value;
                    else if (item is PdfReal r) code = (int)r.Value;
                    else if (item is PdfName gn && code is >= 0 and < 256) names[code++] = gn.Value.TrimStart('/');
                }
            }

            // Unicode of each code, kept only when the Windows font has the glyph.
            var unicodes = new int[256];
            for (var c = 0; c < 256; c++)
            {
                if (names[c] is not { } gn || GlyphNames.ToUnicode(gn) is not { Length: > 0 } u) continue;
                var cp = char.ConvertToUtf32(u, 0);
                if (u.Length == (cp > 0xFFFF ? 2 : 1) && ttf.Has(cp)) unicodes[c] = cp;
            }
            var used = unicodes.Where(u => u > 0).Distinct().ToList();
            if (used.Count == 0) return notEmbedded;

            // The document's own widths (where it has them) must be the Windows face's, or the text would move.
            if (PdfObj.Array(font.Elements["/Widths"]) is { } own)
            {
                var firstOwn = PdfObj.Int(font.Elements["/FirstChar"]) ?? 0;
                for (var i = 0; i < own.Elements.Count; i++)
                {
                    var code = firstOwn + i;
                    var w = PdfObj.Num(own, i);
                    if (code is < 0 or > 255 || unicodes[code] == 0 || w <= 0) continue;
                    if (Math.Abs(w - ttf.Advance(unicodes[code]) * 1000) > 20)
                        return $"The font {FontName(font)} isn't embedded, and its letter widths differ from Windows' {std.Family switch { StdFamily.Times => "Times New Roman", StdFamily.Courier => "Courier New", _ => "Arial" }}{(std.Bold ? " Bold" : "")}{(std.Italic ? " Italic" : "")}, so the text would move.";
                }
            }
            if (HbSubset.SubsetUnicodes(ttf, used) is not { } program) return notEmbedded;

            var differences = new PdfArray(doc);
            for (var c = 0; c < 256; c++)
            {
                if (unicodes[c] == 0) continue;
                var win = GlyphNames.InEncoding("WinAnsiEncoding", c);
                if (win == names[c]) continue;
                differences.Elements.Add(new PdfInteger(c));
                differences.Elements.Add(new PdfName("/" + names[c]));
            }
            var first = Array.FindIndex(unicodes, u => u > 0);
            var last = Array.FindLastIndex(unicodes, u => u > 0);
            var widths = new PdfArray(doc);
            for (var c = first; c <= last; c++) widths.Elements.Add(new PdfInteger(unicodes[c] > 0 ? (int)Math.Round(ttf.Advance(unicodes[c]) * 1000) : 0));

            var tag = Tag(name + string.Join(",", used));
            var style = (std.Bold, std.Italic) switch { (true, true) => "-BoldItalic", (true, false) => "-Bold", (false, true) => "-Italic", _ => "" };
            var postScript = std.Family switch { StdFamily.Times => "TimesNewRoman", StdFamily.Courier => "CourierNew", _ => "Arial" } + style;
            var baseFont = $"/{tag}+{postScript}";
            var file = PdfObj.AddStream(doc, program);
            file.Elements["/Length1"] = new PdfInteger(program.Length);
            double Em(double units) => Math.Round(units * 1000 / ttf.UnitsPerEm);
            var descriptor = new PdfDictionary(doc);
            descriptor.Elements["/Type"] = new PdfName("/FontDescriptor");
            descriptor.Elements["/FontName"] = new PdfName(baseFont);
            descriptor.Elements["/Flags"] = new PdfInteger(32 | (std.Family == StdFamily.Courier ? 1 : 0) | (std.Family == StdFamily.Times ? 2 : 0) | (std.Italic ? 64 : 0));
            descriptor.Elements["/FontBBox"] = PdfObj.Reals(doc, Em(ttf.BBox[0]), Em(ttf.BBox[1]), Em(ttf.BBox[2]), Em(ttf.BBox[3]));
            descriptor.Elements["/ItalicAngle"] = new PdfInteger(std.Italic ? -12 : 0);
            descriptor.Elements["/Ascent"] = new PdfInteger((int)Math.Round(ttf.Ascent * 1000));
            descriptor.Elements["/Descent"] = new PdfInteger((int)Math.Round(ttf.Descent * 1000));
            descriptor.Elements["/CapHeight"] = new PdfInteger((int)Math.Round(ttf.Ascent * 1000 * 0.9));
            descriptor.Elements["/StemV"] = new PdfInteger(std.Bold ? 120 : 80);
            descriptor.Elements["/FontFile2"] = file.Reference!;
            doc.Internals.AddObject(descriptor);

            font.Elements["/Subtype"] = new PdfName("/TrueType");
            font.Elements["/BaseFont"] = new PdfName(baseFont);
            font.Elements["/FirstChar"] = new PdfInteger(first);
            font.Elements["/LastChar"] = new PdfInteger(last);
            font.Elements["/Widths"] = widths;
            font.Elements["/FontDescriptor"] = descriptor.Reference!;
            if (differences.Elements.Count == 0) font.Elements["/Encoding"] = new PdfName("/WinAnsiEncoding");
            else
            {
                var encoding = new PdfDictionary(doc);
                encoding.Elements["/Type"] = new PdfName("/Encoding");
                encoding.Elements["/BaseEncoding"] = new PdfName("/WinAnsiEncoding");
                encoding.Elements["/Differences"] = differences;
                font.Elements["/Encoding"] = encoding;
            }
            _embedded++;
            return null;
        }

        /// <summary>The Unicode value of a code in ZapfDingbats' built-in encoding (Adobe's zdingbat.txt), else 0.</summary>
        private static int DingbatUnicode(int code) => code switch
        {
            0x25 => 0x260E,
            0x2A => 0x261B,
            0x2B => 0x261E,
            0x48 => 0x2605,
            0x6C => 0x25CF,
            0x6E => 0x25A0,
            0x73 => 0x25B2,
            0x74 => 0x25BC,
            0x75 => 0x25C6,
            0x77 => 0x25D7,
            0xA8 => 0x2663,
            0xA9 => 0x2666,
            0xAA => 0x2665,
            0xAB => 0x2660,
            0xD5 => 0x2192,
            0xD6 => 0x2194,
            0xD7 => 0x2195,
            >= 0xAC and <= 0xB5 => 0x2460 + code - 0xAC,
            >= 0x21 and <= 0x7E => 0x2700 + code - 0x20,
            >= 0xA1 and <= 0xFE and not 0xF0 => 0x26C0 + code,
            _ => 0,
        };

        /// <summary>
        /// Embeds ZapfDingbats (a Fill &amp; Sign mark, an Acrobat form's check box) from Windows' Segoe UI Symbol, which the app
        /// already embeds for symbols in text and which has every symbol of the built-in encoding. PDF/A accepts only the
        /// Adobe Glyph List's names in a TrueType font's differences and these symbols aren't there, so the font is symbolic:
        /// no encoding, its codes in a (3,0) cmap, its text in a ToUnicode. Null when done, else why it can't be.
        /// </summary>
        private string? EmbedDingbats(PdfDictionary font)
        {
            var name = FontName(font);
            if (PdfObj.Name(font.Elements["/Subtype"]) is not ("Type1" or "TrueType" or "MMType1") || font.Elements.ContainsKey("/Encoding"))
                return $"The font {name} isn't embedded, and it has an encoding of its own, so its symbols can't be matched.";
            if (SystemFonts.Get("seguisym.ttf") is not { } ttf) return $"The font {name} isn't embedded, and Windows' Segoe UI Symbol, which has its symbols, isn't installed.";
            var unicodes = Enumerable.Range(0, 256).Select(c => DingbatUnicode(c) is var u && ttf.Has(u) ? u : 0).ToArray();
            unicodes[0x20] = 0x20;
            if (PdfObj.Array(font.Elements["/Widths"]) is { } own)
            {
                var firstOwn = PdfObj.Int(font.Elements["/FirstChar"]) ?? 0;
                for (var i = 0; i < own.Elements.Count; i++)
                    if (firstOwn + i is >= 0 and <= 255 && unicodes[firstOwn + i] > 0 && PdfObj.Num(own, i) is var w and > 0 && Math.Abs(w - ttf.Advance(unicodes[firstOwn + i]) * 1000) > 20)
                        return $"The font {name} isn't embedded, and its symbols' widths differ from Windows' Segoe UI Symbol, so they would move.";
            }
            var used = unicodes.Where(u => u > 0).Distinct().ToList();
            if (HbSubset.SubsetUnicodes(ttf, used) is not { } subset || TrueTypeFont.Load("", subset) is not { } cut)
                return $"The font {name} isn't embedded, and Windows' Segoe UI Symbol couldn't be cut down to its symbols.";
            var program = WithSymbolCmap(subset, [.. Enumerable.Range(0, 256).Where(c => unicodes[c] > 0).Select(c => (c, cut.GlyphOf(unicodes[c])))]);

            var file = PdfObj.AddStream(doc, program);
            file.Elements["/Length1"] = new PdfInteger(program.Length);
            var baseFont = $"/{Tag(name + string.Join(",", used))}+SegoeUISymbol";
            double Em(double units) => Math.Round(units * 1000 / ttf.UnitsPerEm);
            var descriptor = new PdfDictionary(doc);
            descriptor.Elements["/Type"] = new PdfName("/FontDescriptor");
            descriptor.Elements["/FontName"] = new PdfName(baseFont);
            descriptor.Elements["/Flags"] = new PdfInteger(4);
            descriptor.Elements["/FontBBox"] = PdfObj.Reals(doc, Em(ttf.BBox[0]), Em(ttf.BBox[1]), Em(ttf.BBox[2]), Em(ttf.BBox[3]));
            descriptor.Elements["/ItalicAngle"] = new PdfInteger(0);
            descriptor.Elements["/Ascent"] = new PdfInteger((int)Math.Round(ttf.Ascent * 1000));
            descriptor.Elements["/Descent"] = new PdfInteger((int)Math.Round(ttf.Descent * 1000));
            descriptor.Elements["/CapHeight"] = new PdfInteger((int)Math.Round(ttf.Ascent * 1000 * 0.9));
            descriptor.Elements["/StemV"] = new PdfInteger(80);
            descriptor.Elements["/FontFile2"] = file.Reference!;
            doc.Internals.AddObject(descriptor);

            var first = Array.FindIndex(unicodes, u => u > 0);
            var last = Array.FindLastIndex(unicodes, u => u > 0);
            var widths = new PdfArray(doc);
            for (var c = first; c <= last; c++) widths.Elements.Add(new PdfInteger(unicodes[c] > 0 ? (int)Math.Round(ttf.Advance(unicodes[c]) * 1000) : 0));
            var text = new SortedDictionary<int, string>();
            for (var c = first; c <= last; c++)
                if (unicodes[c] > 0) text[c] = char.ConvertFromUtf32(unicodes[c]);
            font.Elements["/Subtype"] = new PdfName("/TrueType");
            font.Elements["/BaseFont"] = new PdfName(baseFont);
            font.Elements["/FirstChar"] = new PdfInteger(first);
            font.Elements["/LastChar"] = new PdfInteger(last);
            font.Elements["/Widths"] = widths;
            font.Elements["/FontDescriptor"] = descriptor.Reference!;
            font.Elements["/ToUnicode"] = PdfObj.AddStream(doc, FontUnicode.CMap(text, 1)).Reference!;
            _dingbats++;
            return null;
        }

        /// <summary>
        /// <paramref name="program"/> with its cmap replaced by one (3,0) table (format 4, a segment per code at 0xF000 +
        /// code, where a symbolic font's codes are looked up: ISO 32000-1, 9.6.6.4). The new table goes at the end.
        /// </summary>
        private static byte[] WithSymbolCmap(byte[] program, IReadOnlyList<(int Code, int Glyph)> map)
        {
            var segments = map.Count + 1;
            var cmap = new byte[12 + 16 + 8 * segments];
            void Put(byte[] b, int at, int v) => BinaryPrimitives.WriteUInt16BigEndian(b.AsSpan(at), (ushort)v);
            Put(cmap, 2, 1); // one table
            Put(cmap, 4, 3); // platform 3, encoding 0
            BinaryPrimitives.WriteInt32BigEndian(cmap.AsSpan(8), 12);
            const int t = 12;
            Put(cmap, t, 4);
            Put(cmap, t + 2, cmap.Length - t);
            Put(cmap, t + 6, 2 * segments);
            var selector = (int)Math.Floor(Math.Log2(segments));
            Put(cmap, t + 8, 2 << selector);
            Put(cmap, t + 10, selector);
            Put(cmap, t + 12, 2 * segments - (2 << selector));
            for (var i = 0; i < segments; i++)
            {
                var code = i < map.Count ? 0xF000 + map[i].Code : 0xFFFF;
                var delta = i < map.Count ? map[i].Glyph - code : 1;
                Put(cmap, t + 14 + 2 * i, code); // end
                Put(cmap, t + 16 + 2 * segments + 2 * i, code); // start
                Put(cmap, t + 16 + 4 * segments + 2 * i, delta & 0xFFFF);
            }

            static uint Sum(ReadOnlySpan<byte> b)
            {
                uint sum = 0;
                for (var i = 0; i + 4 <= b.Length; i += 4) sum += BinaryPrimitives.ReadUInt32BigEndian(b[i..]);
                return sum;
            }
            var at = (program.Length + 3) & ~3;
            var font = new byte[at + cmap.Length];
            program.CopyTo(font, 0);
            cmap.CopyTo(font, at);
            int head = -1;
            for (var i = 0; i < BinaryPrimitives.ReadUInt16BigEndian(font.AsSpan(4)); i++)
            {
                var record = 12 + 16 * i;
                var tag = Encoding.ASCII.GetString(font, record, 4);
                if (tag == "head") head = BinaryPrimitives.ReadInt32BigEndian(font.AsSpan(record + 8));
                if (tag != "cmap") continue;
                BinaryPrimitives.WriteUInt32BigEndian(font.AsSpan(record + 4), Sum(cmap));
                BinaryPrimitives.WriteInt32BigEndian(font.AsSpan(record + 8), at);
                BinaryPrimitives.WriteInt32BigEndian(font.AsSpan(record + 12), cmap.Length);
            }
            if (head >= 0)
            {
                BinaryPrimitives.WriteUInt32BigEndian(font.AsSpan(head + 8), 0);
                BinaryPrimitives.WriteUInt32BigEndian(font.AsSpan(head + 8), 0xB1B0AFBA - Sum(font));
            }
            return font;
        }

        private static string Tag(string seed)
        {
            var hash = (uint)seed.Aggregate(17, (h, c) => h * 31 + c);
            var sb = new StringBuilder(6);
            for (var i = 0; i < 6; i++)
            {
                sb.Append((char)('A' + hash % 26));
                hash /= 26;
            }
            return sb.ToString();
        }

        // ───────────── optional content, output intent ─────────────

        private void OptionalContent(PdfDictionary catalog)
        {
            if (PdfObj.Dict(catalog.Elements["/OCProperties"]) is not { } oc) return;
            var configs = new List<PdfDictionary>();
            if (PdfObj.Dict(oc.Elements["/D"]) is { } d) configs.Add(d);
            if (PdfObj.Array(oc.Elements["/Configs"]) is { } more) configs.AddRange(more.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>());
            var names = new HashSet<string>(StringComparer.Ordinal);
            for (var i = 0; i < configs.Count; i++)
            {
                var c = configs[i];
                if (c.Elements.Remove("/AS")) _ocNames++;
                var name = PdfObj.Text(c.Elements["/Name"]);
                if (string.IsNullOrEmpty(name) || !names.Add(name))
                {
                    name = i == 0 ? "Default" : $"Configuration {i + 1}";
                    while (!names.Add(name)) name += " (2)";
                    c.Elements["/Name"] = PdfObj.MakeString(name);
                    _ocNames++;
                }
            }
        }

        /// <summary>
        /// Names over PDF/A's limit (a structure role from Word's styles): each is replaced everywhere by the same shorter,
        /// unique one, so role maps keep matching their elements (<see cref="ScanContent"/> refuses one in page content,
        /// which refers to its resources by name). How many different names.
        /// </summary>
        private static int ShortenLongNames(PdfDictionary catalog)
        {
            var renamed = new Dictionary<string, string>(StringComparer.Ordinal);
            string Shorter(string name)
            {
                if (renamed.TryGetValue(name, out var known)) return known;
                var sb = new StringBuilder("/");
                var bytes = 0;
                foreach (var rune in name.TrimStart('/').EnumerateRunes())
                {
                    if ((bytes += rune.Utf8SequenceLength) > 118) break;
                    sb.Append(rune.ToString());
                }
                sb.Append('~').Append(System.Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(name))), 0, 8);
                return renamed[name] = sb.ToString();
            }
            var seen = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
            var stack = new Stack<PdfItem>([catalog]);
            while (stack.Count > 0)
            {
                switch (PdfObj.Resolve(stack.Pop()))
                {
                    case PdfArray a when seen.Add(a):
                        for (var i = 0; i < a.Elements.Count; i++)
                        {
                            if (a.Elements[i] is PdfName n && NameTooLong(n.Value)) a.Elements[i] = new PdfName(Shorter(n.Value));
                            else stack.Push(a.Elements[i]);
                        }
                        break;
                    case PdfDictionary d when seen.Add(d):
                        foreach (var key in d.Elements.Keys.ToList())
                        {
                            if (d.Elements[key] is not { } value) continue;
                            var at = key;
                            if (NameTooLong(key))
                            {
                                d.Elements.Remove(key);
                                d.Elements[at = Shorter(key)] = value;
                            }
                            if (value is PdfName n && NameTooLong(n.Value)) d.Elements[at] = new PdfName(Shorter(n.Value));
                            else stack.Push(value);
                        }
                        break;
                }
            }
            return renamed.Count;
        }

        private void OutputIntent(PdfDictionary catalog)
        {
            var profile = PdfObj.AddStream(doc, IccProfiles.Srgb());
            profile.Elements["/N"] = new PdfInteger(3);
            var intent = new PdfDictionary(doc);
            intent.Elements["/Type"] = new PdfName("/OutputIntent");
            intent.Elements["/S"] = new PdfName("/GTS_PDFA1");
            intent.Elements["/OutputConditionIdentifier"] = new PdfString("sRGB IEC61966-2.1");
            intent.Elements["/RegistryName"] = new PdfString("http://www.color.org");
            intent.Elements["/Info"] = new PdfString("sRGB IEC61966-2.1");
            intent.Elements["/DestOutputProfile"] = profile.Reference!;
            doc.Internals.AddObject(intent);
            catalog.Elements["/OutputIntents"] = new PdfArray(doc, intent.Reference!);
        }
    }

    // ───────────────────────────── validation ─────────────────────────────

    /// <summary>A name over ISO 19005-2's limit (6.1.13): 127 bytes without the slash.</summary>
    private static bool NameTooLong(string? name) => name is not null && Encoding.UTF8.GetByteCount(name.TrimStart('/')) > 127;

    /// <summary>
    /// The PDF/A-2b rules this class handles, checked on a finished file (empty: none broken). Not a full validator:
    /// font program internals, color in shadings and inline images, and many other rules are not looked at.
    /// </summary>
    public static IReadOnlyList<string> Validate(byte[] pdf, PdfAConformance conformance = PdfAConformance.B)
    {
        var level = conformance.ToString();
        var problems = new List<string>();
        var head = Encoding.Latin1.GetString(pdf.AsSpan(0, Math.Min(pdf.Length, 64)));
        if (!System.Text.RegularExpressions.Regex.IsMatch(head, @"^%PDF-1\.[0-7]\r?\n%[\x80-\xFF]{4}"))
            problems.Add("The file header isn't a PDF 1.x header followed by a binary comment.");
        PdfDocument doc;
        try
        {
            doc = PdfReader.Open(new MemoryStream(pdf, writable: false), PdfDocumentOpenMode.Import);
        }
        catch (Exception ex) when (ex is PdfReaderException or InvalidOperationException)
        {
            return [.. problems, $"The file can't be read: {ex.Message}"];
        }
        using (doc)
        {
            if (doc.SecurityHandler.Elements.ContainsKey("/Filter")) problems.Add("It is encrypted.");
            if (doc.Internals.FirstDocumentID.Length == 0) problems.Add("The trailer has no file identifier (/ID).");
            var catalog = doc.Internals.Catalog;
            if (conformance == PdfAConformance.A)
            {
                if (!catalog.Elements.ContainsKey("/StructTreeRoot")) problems.Add("It isn't tagged (no structure tree).");
                if (PdfObj.Resolve(PdfObj.Dict(catalog.Elements["/MarkInfo"])?.Elements["/Marked"]) is not PdfBoolean { Value: true }) problems.Add("It doesn't say it is tagged (MarkInfo).");
                if (!AccessibilityCheck.IsLanguage(PdfObj.Text(catalog.Elements["/Lang"]))) problems.Add("It doesn't say its language.");
            }
            var intents = PdfObj.Array(catalog.Elements["/OutputIntents"]);
            var pdfa = intents?.Elements.Select(PdfObj.Dict).FirstOrDefault(i => PdfObj.Name(i?.Elements["/S"]) == "GTS_PDFA1");
            if (PdfObj.Dict(pdfa?.Elements["/DestOutputProfile"]) is not { Stream: { } icc } profile || PdfObj.Int(profile.Elements["/N"]) != 3 ||
                icc.UnfilteredValue is not { Length: > 128 } iccBytes || Encoding.ASCII.GetString(iccBytes, 36, 4) != "acsp")
                problems.Add("There is no RGB PDF/A output intent with an ICC profile.");
            if (PdfObj.Dict(catalog.Elements["/Metadata"]) is not { Stream: { } meta } metaDict)
                problems.Add("There is no XMP metadata.");
            else
            {
                if (metaDict.Elements.ContainsKey("/Filter")) problems.Add("The XMP metadata is compressed.");
                var xmp = Encoding.UTF8.GetString(meta.Value);
                if (!xmp.Contains("pdfaid:part=\"2\"", StringComparison.Ordinal) && !xmp.Contains("<pdfaid:part>2</pdfaid:part>", StringComparison.Ordinal))
                    problems.Add("The XMP metadata doesn't say PDF/A-2.");
                if (!xmp.Contains($"pdfaid:conformance=\"{level}\"", StringComparison.Ordinal) && !xmp.Contains($"<pdfaid:conformance>{level}</pdfaid:conformance>", StringComparison.Ordinal))
                    problems.Add($"The XMP metadata doesn't say conformance {level}.");
                if (conformance == PdfAConformance.A && xmp.Contains("pdfuaid", StringComparison.Ordinal) && !xmp.Contains("pdfaSchema:prefix>pdfuaid<", StringComparison.Ordinal))
                    problems.Add("The XMP metadata says PDF/UA without the extension schema PDF/A requires.");
            }
            if (catalog.Elements.ContainsKey("/AA")) problems.Add("The document has additional actions.");
            if (PdfObj.Dict(catalog.Elements["/Names"]) is { } names && (names.Elements.ContainsKey("/JavaScript") || names.Elements.ContainsKey("/EmbeddedFiles")))
                problems.Add("The document has scripts or attached files.");
            if (PdfObj.Dict(catalog.Elements["/AcroForm"]) is { } acro && (acro.Elements.ContainsKey("/XFA") || PdfObj.Resolve(acro.Elements["/NeedAppearances"]) is PdfBoolean { Value: true }))
                problems.Add("The form is an XFA form or needs the viewer to draw its fields.");

            var seen = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
            var stack = new Stack<PdfItem>([catalog]);
            while (stack.Count > 0)
            {
                var item = PdfObj.Resolve(stack.Pop());
                if (item is PdfName longName && NameTooLong(longName.Value)) problems.Add("A name is longer than the 127 bytes PDF/A allows.");
                if (item is not PdfObject o || !seen.Add(o)) continue;
                if (o is PdfArray arr)
                {
                    foreach (var e in arr.Elements) stack.Push(e);
                    continue;
                }
                if (o is not PdfDictionary d) continue;
                foreach (var key in d.Elements.Keys.ToList())
                {
                    if (NameTooLong(key)) problems.Add("A name is longer than the 127 bytes PDF/A allows.");
                    if (key != "/Parent" && key != "/P" && d.Elements[key] is { } value) stack.Push(value);
                }
                if (d.Elements.ContainsKey("/AA")) problems.Add("Something has additional actions.");
                if (!ReferenceEquals(d, catalog) && d.Elements.ContainsKey("/Metadata")) problems.Add("Something other than the document has metadata of its own.");
                var type = PdfObj.Name(d.Elements["/Type"]);
                var subtype = PdfObj.Name(d.Elements["/Subtype"]);
                var s = PdfObj.Name(d.Elements["/S"]);
                if (s is not null && !d.Elements.ContainsKey("/K") && (type == "Action" || ForbiddenActions.Contains(s)) &&
                    (ForbiddenActions.Contains(s) || s == "Named" && !AllowedNamed.Contains(PdfObj.Name(d.Elements["/N"]) ?? "")))
                    problems.Add($"It has a {s} action.");
                if (d.Stream is not null)
                {
                    var filter = PdfObj.Resolve(d.Elements["/Filter"]);
                    if (filter is PdfName { Value: "/LZWDecode" } || filter is PdfArray fa && fa.Elements.Any(e => (PdfObj.Resolve(e) as PdfName)?.Value == "/LZWDecode"))
                        problems.Add("A stream is LZW-compressed.");
                }
                if (subtype == "Image" && (PdfObj.Resolve(d.Elements["/Interpolate"]) is PdfBoolean { Value: true } || d.Elements.ContainsKey("/Alternates") || d.Elements.ContainsKey("/OPI")))
                    problems.Add("A picture has interpolation, alternates or OPI.");
                if (subtype == "PS") problems.Add("It has a PostScript XObject.");
                if (d.Elements.ContainsKey("/TR") || d.Elements.ContainsKey("/HTP")) problems.Add("A graphics state has a transfer function or halftone origin.");
                if (type == "Font" && subtype is "Type1" or "TrueType" or "MMType1" && PdfObj.Dict(d.Elements["/FontDescriptor"]) is var fd && !(fd is not null &&
                        (fd.Elements.ContainsKey("/FontFile") || fd.Elements.ContainsKey("/FontFile2") || fd.Elements.ContainsKey("/FontFile3"))))
                    problems.Add($"The font {PdfObj.Name(d.Elements["/BaseFont"])} isn't embedded.");
                if (subtype is "CIDFontType0" or "CIDFontType2" && PdfObj.Dict(d.Elements["/FontDescriptor"]) is var cfd &&
                    !(cfd is not null && (cfd.Elements.ContainsKey("/FontFile2") || cfd.Elements.ContainsKey("/FontFile3") || cfd.Elements.ContainsKey("/FontFile"))))
                    problems.Add($"The font {PdfObj.Name(d.Elements["/BaseFont"])} isn't embedded.");
            }
            foreach (var page in doc.Pages)
            {
                if (PdfObj.Array(page.Elements["/Annots"]) is not { } annots) continue;
                foreach (var a in annots.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>())
                {
                    var subtype = PdfObj.Name(a.Elements["/Subtype"]) ?? "";
                    var flags = PdfObj.Int(a.Elements["/F"]) ?? 0;
                    if (RemovedAnnotations.Contains(subtype)) problems.Add($"It has a {subtype} annotation.");
                    if ((flags & FlagPrint) == 0 || (flags & (FlagInvisible | FlagHidden | FlagNoView | FlagToggleNoView)) != 0)
                        problems.Add("An annotation doesn't print or is hidden.");
                    var ap = PdfObj.Dict(a.Elements["/AP"]);
                    if (ap is not null && (ap.Elements.ContainsKey("/R") || ap.Elements.ContainsKey("/D"))) problems.Add("An annotation has rollover or down appearances.");
                    var rect = PdfObj.Array(a.Elements["/Rect"]);
                    var zero = rect is null || Math.Abs(PdfObj.Num(rect, 2) - PdfObj.Num(rect, 0)) < 1e-6 || Math.Abs(PdfObj.Num(rect, 3) - PdfObj.Num(rect, 1)) < 1e-6;
                    if (ap?.Elements["/N"] is null && subtype is not ("Popup" or "Link") && !zero) problems.Add("An annotation has no appearance.");
                }
            }
        }
        return [.. problems.Distinct()];
    }
}

/// <summary>ICC color profiles written here (no third-party profile is shipped).</summary>
public static class IccProfiles
{
    private static readonly Lazy<byte[]> SrgbProfile = new(BuildSrgb);

    /// <summary>
    /// An sRGB (IEC 61966-2-1) display profile, ICC version 2.1: the sRGB primaries adapted to D50 (Bradford), D65 white
    /// point, and the sRGB tone curve as a 1024-entry table. About 2.6 KB.
    /// </summary>
    public static byte[] Srgb() => (byte[])SrgbProfile.Value.Clone();

    private static byte[] BuildSrgb()
    {
        var tags = new List<(string Sig, byte[] Data)>
        {
            ("desc", Desc("sRGB IEC61966-2.1 (Inkvolt PDF)")),
            ("cprt", Text("No copyright: the sRGB colorimetry of IEC 61966-2-1, written by Inkvolt PDF")),
            ("wtpt", Xyz(0.9505, 1.0, 1.0890)),
            ("rXYZ", Xyz(0.4361, 0.2225, 0.0139)),
            ("gXYZ", Xyz(0.3851, 0.7169, 0.0971)),
            ("bXYZ", Xyz(0.1431, 0.0606, 0.7141)),
            ("rTRC", Curve()),
        };
        var curve = tags[^1].Data;
        // gTRC and bTRC share rTRC's data (the same offset), as ICC allows.
        var count = tags.Count + 2;
        var offset = 128 + 4 + 12 * count;
        var table = new List<(string Sig, int Offset, int Size)>();
        var body = new MemoryStream();
        foreach (var (sig, data) in tags)
        {
            var at = offset + (int)body.Length;
            table.Add((sig, at, data.Length));
            body.Write(data);
            while (body.Length % 4 != 0) body.WriteByte(0);
        }
        var trc = table[^1];
        table.Add(("gTRC", trc.Offset, trc.Size));
        table.Add(("bTRC", trc.Offset, trc.Size));
        _ = curve;

        var size = offset + (int)body.Length;
        var p = new byte[size];
        BinaryPrimitives.WriteInt32BigEndian(p, size);
        BinaryPrimitives.WriteInt32BigEndian(p.AsSpan(8), 0x02100000); // version 2.1
        Encoding.ASCII.GetBytes("mntr").CopyTo(p, 12);
        Encoding.ASCII.GetBytes("RGB ").CopyTo(p, 16);
        Encoding.ASCII.GetBytes("XYZ ").CopyTo(p, 20);
        foreach (var (i, v) in new[] { (24, 2026), (26, 1), (28, 1) }) BinaryPrimitives.WriteUInt16BigEndian(p.AsSpan(i), (ushort)v);
        Encoding.ASCII.GetBytes("acsp").CopyTo(p, 36);
        Encoding.ASCII.GetBytes("MSFT").CopyTo(p, 40);
        BinaryPrimitives.WriteInt32BigEndian(p.AsSpan(64), 0); // perceptual
        S15(p, 68, 0.9642);
        S15(p, 72, 1.0);
        S15(p, 76, 0.8249);
        BinaryPrimitives.WriteInt32BigEndian(p.AsSpan(128), count);
        for (var i = 0; i < table.Count; i++)
        {
            var at = 132 + 12 * i;
            Encoding.ASCII.GetBytes(table[i].Sig).CopyTo(p, at);
            BinaryPrimitives.WriteInt32BigEndian(p.AsSpan(at + 4), table[i].Offset);
            BinaryPrimitives.WriteInt32BigEndian(p.AsSpan(at + 8), table[i].Size);
        }
        body.ToArray().CopyTo(p, offset);
        return p;
    }

    private static void S15(byte[] p, int at, double v) => BinaryPrimitives.WriteInt32BigEndian(p.AsSpan(at), (int)Math.Round(v * 65536));

    private static byte[] Xyz(double x, double y, double z)
    {
        var b = new byte[20];
        Encoding.ASCII.GetBytes("XYZ ").CopyTo(b, 0);
        S15(b, 8, x);
        S15(b, 12, y);
        S15(b, 16, z);
        return b;
    }

    private static byte[] Text(string s)
    {
        var b = new byte[8 + s.Length + 1];
        Encoding.ASCII.GetBytes("text").CopyTo(b, 0);
        Encoding.ASCII.GetBytes(s).CopyTo(b, 8);
        return b;
    }

    /// <summary>textDescriptionType: ASCII description, empty Unicode and ScriptCode parts.</summary>
    private static byte[] Desc(string s)
    {
        var b = new byte[8 + 4 + s.Length + 1 + 4 + 4 + 2 + 1 + 67];
        Encoding.ASCII.GetBytes("desc").CopyTo(b, 0);
        BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(8), s.Length + 1);
        Encoding.ASCII.GetBytes(s).CopyTo(b, 12);
        return b;
    }

    /// <summary>The sRGB transfer curve (linear below 0.04045, else the 2.4 power segment), 1024 entries.</summary>
    private static byte[] Curve()
    {
        const int n = 1024;
        var b = new byte[12 + 2 * n];
        Encoding.ASCII.GetBytes("curv").CopyTo(b, 0);
        BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(8), n);
        for (var i = 0; i < n; i++)
        {
            var v = i / (double)(n - 1);
            var linear = v <= 0.04045 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4);
            BinaryPrimitives.WriteUInt16BigEndian(b.AsSpan(12 + 2 * i), (ushort)Math.Round(linear * 65535));
        }
        return b;
    }
}
