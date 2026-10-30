using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;

namespace InkvoltPdf.Core;

/// <summary>
/// Text inside form XObjects (drawings a page reuses: stamped or flattened pages, some generators' every block) is
/// edited where it is drawn: the form's own content stream is rewritten. A form the page draws more than once, or that
/// other pages draw too, is copied for the Do that was clicked first, so only that one changes. A form drawn through
/// another form can't be copied that way: it is edited when nothing in its chain is shared, else left alone.
/// </summary>
public static partial class ContentEditor
{
    /// <summary>The content an edit rewrites: the page's own streams, or one form XObject's stream.</summary>
    private sealed class Target
    {
        public required List<COp> Ops;
        public required byte[] Bytes;
        /// <summary>The page's streams (null: a form).</summary>
        public PageStreams? Streams;
        public FormPlace? Form;
        /// <summary>The dictionary whose /Resources get the fonts an edit adds: the innermost form with resources of its own, else the page.</summary>
        public required PdfDictionary ResourceOwner;
        /// <summary>The resources the content's operators use.</summary>
        public required PdfDictionary? Resources;

        /// <summary>The operator a run is drawn by.</summary>
        public COp OpOf(TextRun run) => Ops[Form is null ? run.Id : run.Info!.Form!.Index];
    }

    /// <summary>Where <paramref name="run"/> is edited; a form shared with other drawings of it is copied for this page's Do first.</summary>
    private static Target TargetOf(PdfDocument doc, PdfPage page, PageStreams streams, List<COp> pageOps, Walked walk, TextRun run)
    {
        if (run.Info?.Form is not { } place)
            return new Target { Ops = pageOps, Bytes = streams.Bytes, Streams = streams, ResourceOwner = page, Resources = PdfObj.Dict(page.Elements["/Resources"]) };
        var form = place.Form;
        if (walk.FormUses.GetValueOrDefault(form) > 1 || SharedElsewhere(doc, page, place))
        {
            if (place.Outer is not null)
                throw new ContentEditException("This text can't be edited: it is inside a drawing (a form XObject) that other pages share, drawn through another drawing, and an edit would change every copy.");
            form = CopyForm(doc, page, streams, pageOps, place);
            place = place with { Form = form };
        }
        PdfDictionary owner = page;
        for (var f = place; f is not null; f = f.Outer)
            if (PdfObj.Dict(f.Form.Elements["/Resources"]) is not null)
            {
                owner = f.Form;
                break;
            }
        return new Target { Ops = place.Ops, Bytes = place.Bytes, Form = place, ResourceOwner = owner, Resources = place.Resources };
    }

    /// <summary>Whether another page draws any form of <paramref name="place"/>'s chain (through its XObject resources, at any depth).</summary>
    private static bool SharedElsewhere(PdfDocument doc, PdfPage page, FormPlace place)
    {
        var chain = new HashSet<PdfDictionary>(place.Chain(), ReferenceEqualityComparer.Instance);
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        bool Visit(PdfDictionary? xo, int depth)
        {
            if (xo is null || depth > MaxDepth) return false;
            foreach (var item in xo.Elements.Values)
            {
                if (PdfObj.Dict(item) is not { } form || PdfObj.NameOf(form, "/Subtype") != "/Form") continue;
                if (chain.Contains(form)) return true;
                if (!seen.Add(form)) continue;
                if (Visit(PdfObj.Dict(PdfObj.Dict(form.Elements["/Resources"])?.Elements["/XObject"]), depth + 1)) return true;
            }
            return false;
        }
        for (var i = 0; i < doc.PageCount; i++)
        {
            var other = doc.Pages[i];
            if (ReferenceEquals(other, page) || other.Reference is { } r && page.Reference is { } mine && r.ObjectNumber == mine.ObjectNumber) continue;
            if (Visit(PdfObj.Dict(PdfObj.Dict(other.Elements["/Resources"])?.Elements["/XObject"]), 0)) return true;
        }
        return false;
    }

    /// <summary>A copy of a form the page draws directly, under a name of its own, with the Do changed to draw the copy.</summary>
    private static PdfDictionary CopyForm(PdfDocument doc, PdfPage page, PageStreams streams, List<COp> pageOps, FormPlace place)
    {
        var copy = new PdfDictionary(doc);
        foreach (var key in place.Form.Elements.Keys)
            if (key is not ("/Filter" or "/DecodeParms" or "/Length")) copy.Elements[key] = place.Form.Elements[key];
        copy.CreateStream(place.Bytes);
        doc.Internals.AddObject(copy);
        var name = AddXObject(doc, page, copy, "InkFm");
        var op = pageOps[place.DoId];
        WriteContent(doc, page, streams, pageOps, [(op.Start, op.End, $"/{name} Do")]);
        return copy;
    }

    /// <summary>Writes the edits into the target's content: the page's streams, or the form's stream.</summary>
    private static void WriteTarget(PdfDocument doc, PdfPage page, Target target, List<(int Start, int End, string Text)> edits)
    {
        if (target.Form is null) WriteContent(doc, page, target.Streams!, target.Ops, edits);
        else PdfObj.SetStream(target.Form.Form, Splice(target.Bytes, edits));
    }

    /// <summary>Adds fonts to the page's or form's own font resources (copying shared dictionaries first).</summary>
    private static void AddFonts(PdfDocument doc, PdfDictionary owner, PdfDictionary fonts)
    {
        var res = owner.Elements["/Resources"] switch
        {
            PdfDictionary d => d,
            PdfReference r when r.Value is PdfDictionary shared => shared.Clone(),
            _ => new PdfDictionary(doc),
        };
        owner.Elements["/Resources"] = res;
        var fd = res.Elements["/Font"] switch
        {
            PdfDictionary d => d,
            PdfReference r when r.Value is PdfDictionary shared => shared.Clone(),
            _ => new PdfDictionary(doc),
        };
        res.Elements["/Font"] = fd;
        foreach (var (name, item) in fonts.Elements) fd.Elements[name] = item;
    }
}
