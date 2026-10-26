using System.Xml;
using System.Xml.Linq;

namespace InkvoltPrint.Core.Net;

/// <summary>
/// Reads XML a device sent (LEDM, eSCL): no DTD (no entities to expand, nothing fetched) and no deeper than
/// <see cref="MaxDepth"/>, since LINQ to XML walks elements recursively and a reply nested a few hundred thousand deep would
/// overflow the stack, which no catch stops. Malformed or refused XML throws <see cref="XmlException"/>.
/// </summary>
public static class DeviceXml
{
    /// <summary>The printers' own documents nest a dozen levels at most.</summary>
    public const int MaxDepth = 64;

    private static readonly XmlReaderSettings Settings = new() { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null };

    public static XDocument Load(byte[] bytes)
    {
        using (var check = XmlReader.Create(new MemoryStream(bytes), Settings))
            while (check.Read())
                if (check.Depth > MaxDepth) throw new XmlException($"The document nests deeper than {MaxDepth} levels.");
        using var reader = XmlReader.Create(new MemoryStream(bytes), Settings);
        return XDocument.Load(reader);
    }
}
