using System.Net;
using System.Text;
using System.Xml.Linq;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Tests;

/// <summary>
/// The printer's own copier over HP LEDM (<see cref="LedmCopy"/>, <see cref="PrinterCopier"/>) and the way a copy goes
/// (<see cref="CopyRoute"/>). The M234dw's tree lists the copy documents; the documents themselves are the hand-written demo
/// ones (<c>Fixtures/hp-demo</c>), as none has been captured.
/// </summary>
public class PrinterCopyTests
{
    private const string Host = "192.0.2.10";

    private static readonly string[] DemoLaser = ["m234dw", "hp-demo"];

    private static byte[]? Fixture(string[] folders, string name) => folders
        .Select(folder => Path.Combine(AppContext.BaseDirectory, "Fixtures", folder, name)).Where(File.Exists).Select(File.ReadAllBytes).FirstOrDefault();

    private static XDocument Doc(string name) => XDocument.Parse(Encoding.UTF8.GetString(Fixture(DemoLaser, name)!));

    private sealed record Sent(HttpMethod Method, Uri Uri, string? ContentType, byte[] Body);

    /// <summary>A printer's web server from fixtures that records every request and answers writes with <paramref name="put"/>.</summary>
    private sealed class Recorder(string[] folders, HttpStatusCode put = HttpStatusCode.OK) : HttpMessageHandler
    {
        private readonly FixtureHandler _documents = new(name => Fixture(folders, name));
        public List<Sent> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct);
            Requests.Add(new Sent(request.Method, request.RequestUri!, request.Content?.Headers.ContentType?.MediaType, body));
            if (request.Method == HttpMethod.Put) return new HttpResponseMessage(put) { RequestMessage = request };
            using var invoker = new HttpMessageInvoker(_documents, disposeHandler: false);
            return await invoker.SendAsync(request, ct);
        }
    }

    private static async Task<(PrinterConnection, PrinterCopier?, Recorder)> ConnectAsync(string[] folders, HttpStatusCode put = HttpStatusCode.OK)
    {
        var printer = new Recorder(folders, put);
        var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        return (conn, await PrinterCopier.DetectAsync(conn), printer);
    }

    // ------------------------------------------------------------------ finding it

    [Fact]
    public void The_M234dws_tree_lists_both_copy_documents()
    {
        var tree = DiscoveryTree.Parse(Doc("DevMgmt_DiscoveryTree.xml"));

        Assert.True(LedmCopy.Listed(tree));
        Assert.Equal("/DevMgmt/CopyConfigCap.xml", tree.UriFor(LedmCopy.CapResource));
        Assert.Equal("/DevMgmt/CopyConfigDyn.xml", tree.UriFor(LedmCopy.DynResource));
    }

    [Fact]
    public async Task Without_its_copy_documents_the_M234dw_offers_no_printer_copy_and_only_reads()
    {
        var (conn, copier, printer) = await ConnectAsync(["m234dw"]); // the recorded fixtures: the tree lists them, nothing answers there
        using var _ = conn;

        Assert.Null(copier);
        Assert.All(printer.Requests, s => Assert.True(s.Method == HttpMethod.Get || s.ContentType == "application/ipp", $"{s.Method} {s.Uri}"));
        Assert.Contains(printer.Requests, s => s.Uri.AbsolutePath == "/DevMgmt/CopyConfigCap.xml");
    }

    [Fact]
    public async Task The_demo_laser_offers_copies_collate_and_two_sided_but_not_color_by_reading_only()
    {
        var (conn, copier, printer) = await ConnectAsync(DemoLaser);
        using var _ = conn;

        Assert.NotNull(copier);
        var offer = copier.Offer;
        Assert.True(offer.CanSetCopies);
        Assert.Equal(99, offer.MaxCopies);
        Assert.True(offer.CanCollate);
        Assert.True(offer.CanTwoSided);
        Assert.False(offer.CanColor); // its ColorModeSupport is readOnly, with mono only
        Assert.DoesNotContain(printer.Requests, s => s.Method != HttpMethod.Get && s.ContentType != "application/ipp");
    }

    // ------------------------------------------------------------------ the request

    [Fact]
    public async Task One_copy_request_is_one_PUT_over_HTTPS_byte_for_byte()
    {
        var (conn, copier, printer) = await ConnectAsync(DemoLaser);
        using var _ = conn;
        var before = printer.Requests.Count;

        var result = await copier!.CopyAsync(new PrinterCopyRequest(Copies: 3, Collate: false, TwoSided: true, Color: true));

        Assert.True(result.Ok, result.Problem);
        var writes = printer.Requests.Skip(before).Where(s => s.Method != HttpMethod.Get).ToList();
        var put = Assert.Single(writes);
        Assert.Equal(HttpMethod.Put, put.Method);
        Assert.Equal(new Uri($"https://{Host}/DevMgmt/CopyConfigDyn.xml"), put.Uri); // HTTPS: an admin password never crosses in clear text
        Assert.Equal("text/xml", put.ContentType);
        // The printer's own names and namespaces; the settings it offers, then the start; color left out (it can't be set).
        Assert.Equal(
            "<cpcfgdyn:CopyConfigDyn xmlns:cpcfgdyn=\"http://www.hp.com/schemas/imaging/con/ledm/cpcfgdyn/2008/05/05\" " +
            "xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\">" +
            "<cpcfgdyn:CopySettings><dd:Copies>3</dd:Copies><dd:Collate>uncollated</dd:Collate><dd:Duplex>simplexToDuplex</dd:Duplex></cpcfgdyn:CopySettings>" +
            "<cpcfgdyn:CopyState>start</cpcfgdyn:CopyState></cpcfgdyn:CopyConfigDyn>",
            Encoding.UTF8.GetString(put.Body));
    }

    [Fact]
    public void One_copy_one_sided_writes_collated_and_simplex_explicitly()
    {
        var offer = LedmCopy.Read(Doc("DevMgmt_CopyConfigDyn.xml"), Doc("DevMgmt_CopyConfigCap.xml"))!;

        var body = LedmClient.Serialize(LedmCopy.Build(Doc("DevMgmt_CopyConfigDyn.xml"), offer, new PrinterCopyRequest(1, Collate: false, TwoSided: false, Color: false)));

        // A default left on the printer's panel (two-sided, say) doesn't slip into this copy.
        Assert.Contains("<dd:Copies>1</dd:Copies><dd:Collate>collated</dd:Collate><dd:Duplex>simplexToSimplex</dd:Duplex>", body);
        Assert.EndsWith("<cpcfgdyn:CopyState>start</cpcfgdyn:CopyState></cpcfgdyn:CopyConfigDyn>", body);
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound, "doesn't take copy requests")]
    [InlineData(HttpStatusCode.MethodNotAllowed, "doesn't take copy requests")]
    [InlineData(HttpStatusCode.ServiceUnavailable, "busy")]
    [InlineData(HttpStatusCode.Conflict, "busy")]
    [InlineData(HttpStatusCode.InternalServerError, "turned the copy down")]
    public async Task A_refusal_is_told_in_words_and_never_sent_again(HttpStatusCode status, string says)
    {
        var (conn, copier, printer) = await ConnectAsync(DemoLaser, status);
        using var _ = conn;

        var result = await copier!.CopyAsync(new PrinterCopyRequest(1, true, false, false));

        Assert.False(result.Ok);
        Assert.Contains(says, result.Problem);
        Assert.DoesNotContain(((int)status).ToString(System.Globalization.CultureInfo.InvariantCulture), result.Problem);
        Assert.Single(printer.Requests, s => s.Method == HttpMethod.Put);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    public async Task A_printer_asking_for_its_password_throws_for_the_caller_to_ask(HttpStatusCode status)
    {
        var (conn, copier, _) = await ConnectAsync(DemoLaser, status);
        using var _c = conn;

        var ex = await Assert.ThrowsAsync<LedmAuthRequiredException>(() => copier!.CopyAsync(new PrinterCopyRequest(1, true, false, false)));
        Assert.False(ex.CredentialsWereSent);
    }

    // ------------------------------------------------------------------ hostile documents

    private const string Ns = "xmlns:c=\"urn:example:cap\" xmlns:d=\"urn:example:dyn\" xmlns:dd=\"urn:example:dd\"";

    private static string Dyn(string settings = "<dd:Copies>1</dd:Copies><dd:Duplex>simplex</dd:Duplex>", string state = "<d:CopyState>idle</d:CopyState>") =>
        $"<d:CopyConfigDyn {Ns}><d:CopySettings>{settings}</d:CopySettings>{state}</d:CopyConfigDyn>";

    private const string StartCap = "<c:CopyStateSupport elementXPath=\"d:CopyConfigDyn/d:CopyState\" access=\"readWrite\"><d:CopyState>start</d:CopyState></c:CopyStateSupport>";

    private static PrinterCopyOffer? Read(string dyn, string capEntries) =>
        LedmCopy.Read(XDocument.Parse(dyn), XDocument.Parse($"<c:CopyConfigCap {Ns}>{capEntries}</c:CopyConfigCap>"));

    [Fact]
    public void No_writable_start_means_no_offer_whatever_else_is_writable()
    {
        const string copies = "<c:Copies min=\"1\" max=\"99\" elementXPath=\"d:CopyConfigDyn/d:CopySettings/dd:Copies\" access=\"readWrite\" />";

        Assert.Null(Read(Dyn(), copies));
        Assert.Null(Read(Dyn(), copies + StartCap.Replace("readWrite", "readOnly")));
        Assert.Null(Read(Dyn(), copies + StartCap.Replace(">start<", ">idle<"))); // a value the app doesn't know as "start"
        Assert.Null(Read(Dyn(state: ""), copies + StartCap)); // the Cap names it, the Dyn hasn't got it
        Assert.Null(LedmCopy.Read(XDocument.Parse(Dyn()), null));
        Assert.NotNull(Read(Dyn(), copies + StartCap));
    }

    [Fact]
    public void Copies_are_bounded_by_the_printer_and_by_ninety_nine()
    {
        var huge = Read(Dyn(), StartCap + "<c:Copies min=\"1\" max=\"2147483647\" elementXPath=\"d:CopyConfigDyn/d:CopySettings/dd:Copies\" access=\"readWrite\" />")!;
        var five = Read(Dyn(), StartCap + "<c:Copies min=\"1\" max=\"5\" elementXPath=\"d:CopyConfigDyn/d:CopySettings/dd:Copies\" access=\"readWrite\" />")!;
        var garbage = Read(Dyn(), StartCap + "<c:Copies min=\"x\" max=\"-3\" elementXPath=\"d:CopyConfigDyn/d:CopySettings/dd:Copies\" access=\"readWrite\" />")!;
        var mustBeTwo = Read(Dyn(), StartCap + "<c:Copies min=\"2\" max=\"9\" elementXPath=\"d:CopyConfigDyn/d:CopySettings/dd:Copies\" access=\"readWrite\" />")!;

        Assert.Equal(LedmCopy.MaxCopies, huge.MaxCopies);
        Assert.Equal(5, five.MaxCopies);
        Assert.False(garbage.CanSetCopies);
        Assert.False(mustBeTwo.CanSetCopies); // one copy must stay possible
        Assert.Contains("<dd:Copies>5</dd:Copies>", Body(five, new PrinterCopyRequest(500, true, false, false)));
        Assert.Contains("<dd:Copies>1</dd:Copies>", Body(five, new PrinterCopyRequest(-4, true, false, false)));
        Assert.DoesNotContain("Copies", Body(garbage, new PrinterCopyRequest(3, true, false, false)));
    }

    private static string Body(PrinterCopyOffer offer, PrinterCopyRequest request) =>
        LedmClient.Serialize(LedmCopy.Build(XDocument.Parse(Dyn()), offer, request));

    [Fact]
    public void Only_choices_the_Cap_lists_are_written_and_long_lists_or_values_are_cut()
    {
        var many = string.Concat(Enumerable.Range(0, 40).Select(i => $"<dd:Duplex>junk{i}</dd:Duplex>"));
        var cut = Read(Dyn(), StartCap + $"<c:DuplexSupport access=\"readWrite\">{many}<dd:Duplex>simplex</dd:Duplex><dd:Duplex>duplex</dd:Duplex></c:DuplexSupport>")!;
        var longValue = Read(Dyn(), StartCap + $"<c:DuplexSupport access=\"readWrite\"><dd:Duplex>simplex</dd:Duplex><dd:Duplex>{new string('d', 100)}</dd:Duplex></c:DuplexSupport>")!;
        var oneWay = Read(Dyn(), StartCap + "<c:DuplexSupport access=\"readWrite\"><dd:Duplex>duplex</dd:Duplex></c:DuplexSupport>")!;
        var fine = Read(Dyn(), StartCap + "<c:DuplexSupport access=\"readWrite\"><dd:Duplex>SIMPLEX</dd:Duplex><dd:Duplex>Duplex</dd:Duplex></c:DuplexSupport>")!;

        Assert.False(cut.CanTwoSided); // past the 32 choices read
        Assert.False(longValue.CanTwoSided);
        Assert.False(oneWay.CanTwoSided); // no way to write one-sided
        Assert.True(fine.CanTwoSided);
        Assert.Contains("<dd:Duplex>Duplex</dd:Duplex>", Body(fine, new PrinterCopyRequest(1, true, true, false))); // the printer's own spelling
    }

    [Fact]
    public void A_setting_the_PUT_could_not_reach_is_not_offered()
    {
        // Two CopySettings: BuildPut follows the first of each name, so the Duplex in the second can't be written.
        var dyn = $"<d:CopyConfigDyn {Ns}><d:CopySettings><dd:Copies>1</dd:Copies></d:CopySettings><d:CopySettings><dd:Duplex>simplex</dd:Duplex></d:CopySettings><d:CopyState>idle</d:CopyState></d:CopyConfigDyn>";
        var offer = Read(dyn, StartCap + "<c:DuplexSupport elementXPath=\"d:CopyConfigDyn/d:CopySettings[2]/dd:Duplex\" access=\"readWrite\"><dd:Duplex>simplex</dd:Duplex><dd:Duplex>duplex</dd:Duplex></c:DuplexSupport>")!;

        Assert.False(offer.CanTwoSided);
    }

    [Theory]
    [InlineData("d:CopyConfigDyn/d:CopySettings/dd:Duplex", "Duplex")]
    [InlineData("d:CopyConfigDyn/d:CopySettings[1]/dd:Duplex[1]", "Duplex")]
    [InlineData("Duplex/", "Duplex")]
    [InlineData("/", null)]
    [InlineData("a/b:", null)]
    public void The_target_is_the_last_step_of_the_elementXPath(string xpath, string? expected)
    {
        var entry = new XElement("DuplexSupport", new XAttribute("elementXPath", xpath));
        Assert.Equal(expected, LedmCopy.Target(entry));
    }

    [Fact]
    public void Without_an_elementXPath_the_target_is_the_Cap_name_less_Support()
    {
        Assert.Equal("Duplex", LedmCopy.Target(new XElement("DuplexSupport")));
        Assert.Equal("Copies", LedmCopy.Target(new XElement("Copies")));
        Assert.Equal("Support", LedmCopy.Target(new XElement("Support")));
    }

    // ------------------------------------------------------------------ which way a copy goes

    [Theory]
    [InlineData(true, true, false, true)]
    [InlineData(true, false, false, false)] // Through this PC chosen
    [InlineData(true, true, true, false)] // an ID card is laid out by the PC
    [InlineData(false, true, false, false)] // the printer doesn't offer it
    public void The_printer_copies_by_itself_only_when_it_offers_it_for_a_page_copy_left_chosen(bool offers, bool chosen, bool idCard, bool expected) =>
        Assert.Equal(expected, CopyRoute.OnPrinter(offers, chosen, idCard));

    [Fact]
    public void The_printers_own_copier_needs_neither_the_scanner_nor_a_queue()
    {
        Assert.Equal(CopyBlocker.None, CopyRoute.Blocker(onPrinter: true, scannerChecked: false, hasScanner: false, canPrint: false));
        Assert.Equal(CopyBlocker.Connecting, CopyRoute.Blocker(false, false, false, false));
        Assert.Equal(CopyBlocker.NoScanner, CopyRoute.Blocker(false, true, false, true));
        Assert.Equal(CopyBlocker.NoQueue, CopyRoute.Blocker(false, true, true, false));
        Assert.Equal(CopyBlocker.None, CopyRoute.Blocker(false, true, true, true));
    }
}
