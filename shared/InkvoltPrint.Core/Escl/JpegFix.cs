using System.Buffers.Binary;

namespace InkvoltPrint.Core.Escl;

/// <summary>
/// HP ADF scans stream JPEGs before the page length is known: the SOF header says height 0 and the real
/// height arrives in a DNL marker after the scan data. Most decoders (WIC included) reject that, so we
/// copy the DNL height into the SOF header.
/// </summary>
public static class JpegFix
{
    public static byte[] PatchZeroHeight(byte[] jpeg)
    {
        var sof = FindSofHeightOffset(jpeg);
        if (sof < 0 || BinaryPrimitives.ReadUInt16BigEndian(jpeg.AsSpan(sof)) != 0) return jpeg;
        var dnl = FindDnlHeight(jpeg);
        if (dnl <= 0) return jpeg;
        var copy = (byte[])jpeg.Clone();
        BinaryPrimitives.WriteUInt16BigEndian(copy.AsSpan(sof), (ushort)dnl);
        return copy;
    }

    /// <summary>Offset of the 16-bit height field in the first SOFn segment, or -1.</summary>
    internal static int FindSofHeightOffset(ReadOnlySpan<byte> j)
    {
        if (j.Length < 4 || j[0] != 0xFF || j[1] != 0xD8) return -1;
        var i = 2;
        while (i + 4 <= j.Length)
        {
            if (j[i] != 0xFF) return -1;
            var marker = j[i + 1];
            if (marker == 0xFF) { i++; continue; }
            if (marker is 0xD8 or 0x01 or >= 0xD0 and <= 0xD7) { i += 2; continue; }
            var len = BinaryPrimitives.ReadUInt16BigEndian(j[(i + 2)..]);
            // SOF0..SOF15 except DHT (C4), JPG (C8), DAC (CC)
            if (marker is >= 0xC0 and <= 0xCF and not 0xC4 and not 0xC8 and not 0xCC)
                return i + 9 < j.Length ? i + 5 : -1; // height(2) width(2) components(1) must all be present
            if (marker == 0xDA) return -1; // start of scan before any SOF
            i += 2 + len;
        }
        return -1;
    }

    /// <summary>Height from the DNL (FFDC) marker, scanning entropy-coded data, or -1.</summary>
    internal static int FindDnlHeight(ReadOnlySpan<byte> j)
    {
        for (var i = j.Length - 6; i >= 2; i--)
            if (j[i] == 0xFF && j[i + 1] == 0xDC && BinaryPrimitives.ReadUInt16BigEndian(j[(i + 2)..]) == 4)
                return BinaryPrimitives.ReadUInt16BigEndian(j[(i + 4)..]);
        return -1;
    }
}
