using System.Buffers.Binary;
using System.Text;

namespace InkvoltPrint.Core.Pdf;

/// <summary>
/// ICC color profiles written here (no third-party profile is shipped). Moved from Inkvolt PDF's PDF/A so that Inkvolt Print's
/// PDF/A scans (<see cref="PdfWriter"/>) carry the same profile; only the application named in its description differs.
/// </summary>
public static class IccProfiles
{
    private static readonly Lazy<byte[]> SrgbPdf = new(() => BuildSrgb("Inkvolt PDF"));
    private static readonly Lazy<byte[]> SrgbPrint = new(() => BuildSrgb("Inkvolt Print"));

    /// <summary>
    /// An sRGB (IEC 61966-2-1) display profile, ICC version 2.1: the sRGB primaries adapted to D50 (Bradford), D65 white
    /// point, and the sRGB tone curve as a 1024-entry table. About 2.6 KB. Inkvolt PDF's, named so in its description and copyright.
    /// </summary>
    public static byte[] Srgb() => (byte[])SrgbPdf.Value.Clone();

    /// <summary>The same profile, named after Inkvolt Print.</summary>
    internal static byte[] SrgbForPrint() => (byte[])SrgbPrint.Value.Clone();

    private static byte[] BuildSrgb(string application)
    {
        var tags = new List<(string Sig, byte[] Data)>
        {
            ("desc", Desc($"sRGB IEC61966-2.1 ({application})")),
            ("cprt", Text($"No copyright: the sRGB colorimetry of IEC 61966-2-1, written by {application}")),
            ("wtpt", Xyz(0.9505, 1.0, 1.0890)),
            ("rXYZ", Xyz(0.4361, 0.2225, 0.0139)),
            ("gXYZ", Xyz(0.3851, 0.7169, 0.0971)),
            ("bXYZ", Xyz(0.1431, 0.0606, 0.7141)),
            ("rTRC", Curve()),
        };
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
