using System.Xml.Linq;

namespace InkvoltPrint.Tests;

internal static class Fixture
{
    public static XDocument Xml(string name) => XDocument.Load(Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name));
}
