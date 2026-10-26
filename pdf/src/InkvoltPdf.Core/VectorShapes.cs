using PdfSharp.Pdf;
using PdfSharp.Pdf.Content;
using PdfSharp.Pdf.Content.Objects;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>A visible straight line or rectangle drawn on a page (page space), as <see cref="VectorShapes"/> finds them.</summary>
/// <param name="IsLine">A horizontal rule (a stroked segment, or a filled rectangle no thicker than 3 pt); otherwise a box.</param>
public readonly record struct PageShape(RectD Box, bool IsLine);

/// <summary>
/// Reads the rectangles and horizontal rules a page's content draws (including inside form XObjects), for
/// <see cref="FieldDetection"/>: `re` rectangles and closed four-sided axis-aligned paths, stroked horizontal segments,
/// and thin filled bars. Curves, clipping paths, invisible (unpainted or white-on-nothing) paths and turned shapes are
/// left out. Coordinates follow the current transformation matrix, so shapes drawn under `cm` or in a scaled form land
/// where they show.
/// </summary>
public static class VectorShapes
{
    private const int MaxOperators = 400_000;
    private const int MaxShapes = 20_000;
    private const int MaxDepth = 8;

    public static IReadOnlyList<PageShape> Read(byte[] data, string? password, int pageIndex, CancellationToken cancel = default)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, "This PDF's pages can't be read");
        return Read(doc, pageIndex, cancel);
    }

    internal static IReadOnlyList<PageShape> Read(PdfDocument doc, int pageIndex, CancellationToken cancel = default)
    {
        if (pageIndex < 0 || pageIndex >= doc.PageCount) throw new ArgumentOutOfRangeException(nameof(pageIndex));
        var page = doc.Pages[pageIndex];
        var walker = new Walker(page, cancel);
        try
        {
            walker.Run(ContentReader.ReadContent(page), PdfObj.Dict(page.Elements["/Resources"]), new Walker.State { Ctm = Matrix.Identity }, 0);
        }
        catch (Exception ex) when (ex is ContentReaderException or InvalidOperationException or ArgumentException or InvalidCastException or IndexOutOfRangeException)
        {
            // Malformed content: keep what was found up to there.
        }
        return walker.Shapes;
    }

    private readonly record struct Matrix(double A, double B, double C, double D, double E, double F)
    {
        public static readonly Matrix Identity = new(1, 0, 0, 1, 0, 0);

        /// <summary>This transform followed by <paramref name="m"/> (PDF: CTM' = this × CTM when this is the cm operand).</summary>
        public Matrix Then(Matrix m) => new(
            A * m.A + B * m.C, A * m.B + B * m.D,
            C * m.A + D * m.C, C * m.B + D * m.D,
            E * m.A + F * m.C + m.E, E * m.B + F * m.D + m.F);

        public (double X, double Y) Apply(double x, double y) => (A * x + C * y + E, B * x + D * y + F);

        /// <summary>How much lengths grow (the geometric mean of the axes' scales).</summary>
        public double Scale => Math.Sqrt(Math.Abs(A * D - B * C));
    }

    private sealed class Walker(PdfPage page, CancellationToken cancel)
    {
        public readonly List<PageShape> Shapes = [];
        private readonly Dictionary<PdfDictionary, CSequence?> _forms = new(ReferenceEqualityComparer.Instance);
        private int _ops;

        public sealed class State
        {
            public Matrix Ctm;
            public double LineWidth = 1;
            public bool StrokeWhite, FillWhite;
            public State Clone() => (State)MemberwiseClone();
        }

        private sealed class SubPath
        {
            public readonly List<(double X, double Y)> Points = [];
            public bool Closed, Curved, IsRect;
        }

        /// <summary>Walks a content stream starting from <paramref name="state"/> (a form XObject inherits its caller's).</summary>
        public void Run(CSequence content, PdfDictionary? resources, State state, int depth)
        {
            state = state.Clone();
            var stack = new Stack<State>();
            var path = new List<SubPath>();
            SubPath? current = null;

            foreach (var op in Operators(content))
            {
                if (++_ops > MaxOperators || Shapes.Count >= MaxShapes) return;
                if ((_ops & 1023) == 0) cancel.ThrowIfCancellationRequested();
                var n = Numbers(op);
                switch (op.Name)
                {
                    case "q":
                        stack.Push(state.Clone());
                        break;
                    case "Q":
                        if (stack.Count > 0) state = stack.Pop();
                        break;
                    case "cm" when n.Count >= 6:
                        state.Ctm = new Matrix(n[0], n[1], n[2], n[3], n[4], n[5]).Then(state.Ctm);
                        break;
                    case "w" when n.Count >= 1:
                        state.LineWidth = n[0];
                        break;
                    case "G" or "g" when n.Count >= 1:
                        SetWhite(state, op.Name == "G", n[0] >= 0.98);
                        break;
                    case "RG" or "rg" when n.Count >= 3:
                        SetWhite(state, op.Name == "RG", n[0] >= 0.98 && n[1] >= 0.98 && n[2] >= 0.98);
                        break;
                    case "K" or "k" when n.Count >= 4:
                        SetWhite(state, op.Name == "K", n[0] <= 0.02 && n[1] <= 0.02 && n[2] <= 0.02 && n[3] <= 0.02);
                        break;
                    case "SC" or "SCN" or "CS":
                        state.StrokeWhite = false; // a color we don't read: count it as visible
                        break;
                    case "sc" or "scn" or "cs":
                        state.FillWhite = false;
                        break;
                    case "m" when n.Count >= 2:
                        current = new SubPath();
                        current.Points.Add((n[0], n[1]));
                        path.Add(current);
                        break;
                    case "l" when n.Count >= 2 && current is not null:
                        current.Points.Add((n[0], n[1]));
                        break;
                    case "c" when n.Count >= 6 && current is not null:
                        current.Curved = true;
                        current.Points.Add((n[4], n[5]));
                        break;
                    case "v" or "y" when n.Count >= 4 && current is not null:
                        current.Curved = true;
                        current.Points.Add((n[2], n[3]));
                        break;
                    case "h" when current is not null:
                        current.Closed = true;
                        break;
                    case "re" when n.Count >= 4:
                    {
                        var r = new SubPath { Closed = true, IsRect = true };
                        r.Points.AddRange([(n[0], n[1]), (n[0] + n[2], n[1]), (n[0] + n[2], n[1] + n[3]), (n[0], n[1] + n[3])]);
                        path.Add(r);
                        current = null;
                        break;
                    }
                    case "S" or "s" or "f" or "F" or "f*" or "B" or "B*" or "b" or "b*" or "n":
                    {
                        var stroke = op.Name is "S" or "s" or "B" or "B*" or "b" or "b*";
                        var fill = op.Name is "f" or "F" or "f*" or "B" or "B*" or "b" or "b*";
                        if (op.Name is "s" or "b" or "b*" && current is not null) current.Closed = true;
                        stroke &= !state.StrokeWhite;
                        fill &= !state.FillWhite;
                        if (stroke || fill)
                            foreach (var sub in path) Emit(sub, state, stroke, fill);
                        path.Clear();
                        current = null;
                        break;
                    }
                    case "Do" when depth < MaxDepth && op.Operands.Count > 0 && op.Operands[0] is CName name:
                        RunForm(resources, name.Name, state, depth);
                        break;
                }
            }
        }

        private static void SetWhite(State s, bool stroke, bool white)
        {
            if (stroke) s.StrokeWhite = white;
            else s.FillWhite = white;
        }

        private void RunForm(PdfDictionary? resources, string name, State state, int depth)
        {
            if (PdfObj.Dict(PdfObj.Dict(resources?.Elements["/XObject"])?.Elements[name]) is not { } form) return;
            if (PdfObj.NameOf(form, "/Subtype") != "/Form") return;
            var m = PdfObj.Array(form.Elements["/Matrix"]) is { Elements.Count: 6 } a
                ? new Matrix(PdfObj.Num(a, 0), PdfObj.Num(a, 1), PdfObj.Num(a, 2), PdfObj.Num(a, 3), PdfObj.Num(a, 4), PdfObj.Num(a, 5))
                : Matrix.Identity;
            // Read once: a form can be drawn many times, and its content (comments, say) cost more than its operators.
            if (!_forms.TryGetValue(form, out var content))
            {
                var bytes = PdfObj.StreamBytes(form);
                _forms[form] = content = bytes.Length == 0 ? null : ContentReader.ReadContent(bytes);
            }
            if (content is null) return;
            var inner = state.Clone();
            inner.Ctm = m.Then(state.Ctm);
            Run(content, PdfObj.Dict(form.Elements["/Resources"]) ?? resources, inner, depth + 1);
        }

        private static IEnumerable<COperator> Operators(CSequence seq)
        {
            foreach (var item in seq)
            {
                if (item is COperator op) yield return op;
                else if (item is CSequence inner)
                    foreach (var o in Operators(inner)) yield return o;
            }
        }

        private static List<double> Numbers(COperator op)
        {
            var list = new List<double>(op.Operands.Count);
            foreach (var o in op.Operands)
            {
                switch (o)
                {
                    case CInteger i: list.Add(i.Value); break;
                    case CReal r: list.Add(r.Value); break;
                }
            }
            return list;
        }

        private void Emit(SubPath sub, State state, bool stroke, bool fill)
        {
            if (sub.Curved || sub.Points.Count < 2) return;
            var pts = sub.Points.Select(p => ToPage(state.Ctm, p.X, p.Y)).ToList();
            var thickness = Math.Max(0.5, state.LineWidth * state.Ctm.Scale);

            // A closed four-sided path (or `re`) whose corners line up with the axes: a box (or a bar, when thin).
            var corners = pts.Count == 5 && Near(pts[0], pts[4]) ? pts.Take(4).ToList() : pts;
            if ((sub.IsRect || sub.Closed || pts.Count == 5) && corners.Count == 4 && AxisAligned(corners))
            {
                var box = RectD.FromEdges(corners.Min(p => p.X), corners.Min(p => p.Y), corners.Max(p => p.X), corners.Max(p => p.Y));
                if (box.Width < 0.5 && box.Height < 0.5) return;
                if (box.Height <= 3 && box.Width >= 6 && (fill || box.Height < 0.5)) Add(new PageShape(box.Height < thickness ? box with { Height = Math.Max(box.Height, 0.5) } : box, true));
                else if (box.Width >= 3 && box.Height > 3) Add(new PageShape(box, false));
                return;
            }
            if (!stroke) return;
            // Open (or other) paths: each horizontal segment is a rule.
            for (var i = 1; i < pts.Count + (sub.Closed ? 1 : 0); i++)
            {
                var a = pts[i - 1];
                var b = pts[i % pts.Count];
                if (Math.Abs(a.Y - b.Y) > 0.5 || Math.Abs(a.X - b.X) < 6) continue;
                Add(new PageShape(new RectD(Math.Min(a.X, b.X), (a.Y + b.Y) / 2 - thickness / 2, Math.Abs(a.X - b.X), thickness), true));
            }
        }

        private void Add(PageShape s)
        {
            if (Shapes.Count < MaxShapes) Shapes.Add(s);
        }

        private (double X, double Y) ToPage(Matrix ctm, double x, double y)
        {
            var (ux, uy) = ctm.Apply(x, y);
            return PdfObj.ToPage(page, ux, uy);
        }

        private static bool Near((double X, double Y) a, (double X, double Y) b) => Math.Abs(a.X - b.X) < 0.5 && Math.Abs(a.Y - b.Y) < 0.5;

        /// <summary>Four corners in order, each edge horizontal or vertical.</summary>
        private static bool AxisAligned(List<(double X, double Y)> c)
        {
            for (var i = 0; i < 4; i++)
            {
                var a = c[i];
                var b = c[(i + 1) % 4];
                if (Math.Abs(a.X - b.X) > 0.5 && Math.Abs(a.Y - b.Y) > 0.5) return false;
            }
            return true;
        }
    }
}
