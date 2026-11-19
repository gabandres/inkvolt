using System.Net;
using System.Text;
using System.Xml.Linq;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Tests;

/// <summary>
/// The printer's own copier over HP LEDM (<see cref="LedmCopy"/>, <see cref="PrinterCopier"/>) and the Copy tab's choices
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

    private sealed record Sent(HttpMethod Method, Uri Uri, string? ContentType, byte[] Body, bool ConnectionClose);

    /// <summary>A printer's web server from fixtures that records every request and answers writes with <paramref name="put"/>.</summary>
    private sealed class Recorder(string[] folders, HttpStatusCode put = HttpStatusCode.OK, Func<HttpRequestMessage, Exception?>? fail = null) : HttpMessageHandler
    {
        private readonly FixtureHandler _documents = new(name => Fixture(folders, name));
        public List<Sent> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct);
            Requests.Add(new Sent(request.Method, request.RequestUri!, request.Content?.Headers.ContentType?.MediaType, body, request.Headers.ConnectionClose == true));
            if (fail?.Invoke(request) is { } ex) throw ex;
            if (request.Method == HttpMethod.Put) return new HttpResponseMessage(put) { RequestMessage = request };
            using var invoker = new HttpMessageInvoker(_documents, disposeHandler: false);
            return await invoker.SendAsync(request, ct);
        }
    }

    private static async Task<(PrinterConnection, PrinterCopier?, Recorder)> ConnectAsync(string[] folders, HttpStatusCode put = HttpStatusCode.OK,
        Func<HttpRequestMessage, Exception?>? fail = null)
    {
        var printer = new Recorder(folders, put, fail);
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
    public async Task The_demo_laser_offers_its_start_by_reading_only()
    {
        var (conn, copier, printer) = await ConnectAsync(DemoLaser);
        using var _ = conn;

        Assert.NotNull(copier);
        Assert.Equal(["CopyState"], copier.Start.Path);
        Assert.Equal("start", copier.Start.Value);
        Assert.DoesNotContain(printer.Requests, s => s.Method != HttpMethod.Get && s.ContentType != "application/ipp");
    }

    // ------------------------------------------------------------------ the request

    [Fact]
    public async Task One_copy_is_one_PUT_of_the_start_alone_over_HTTPS_byte_for_byte()
    {
        var (conn, copier, printer) = await ConnectAsync(DemoLaser);
        using var _ = conn;
        var before = printer.Requests.Count;

        var result = await copier!.CopyAsync();

        Assert.True(result.Ok, result.Problem);
        var put = Assert.Single(printer.Requests.Skip(before), s => s.Method != HttpMethod.Get);
        Assert.Equal(HttpMethod.Put, put.Method);
        Assert.Equal(new Uri($"https://{Host}/DevMgmt/CopyConfigDyn.xml"), put.Uri); // HTTPS: an admin password never crosses in clear text
        Assert.Equal("text/xml", put.ContentType);
        Assert.True(put.ConnectionClose); // sent once, on a connection of its own (SendOnceAsync)
        // The printer's own names and namespaces, and only the start: its copies, two-sided and the rest stay as its panel has them.
        Assert.Equal(
            "<cpcfgdyn:CopyConfigDyn xmlns:cpcfgdyn=\"http://www.hp.com/schemas/imaging/con/ledm/cpcfgdyn/2008/05/05\" " +
            "xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\">" +
            "<cpcfgdyn:CopyState>start</cpcfgdyn:CopyState></cpcfgdyn:CopyConfigDyn>",
            Encoding.UTF8.GetString(put.Body));
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

        var result = await copier!.CopyAsync();

        Assert.False(result.Ok);
        Assert.Contains(says, result.Problem);
        Assert.DoesNotContain(((int)status).ToString(System.Globalization.CultureInfo.InvariantCulture), result.Problem);
        Assert.Single(printer.Requests, s => s.Method == HttpMethod.Put);
    }

    [Fact]
    public async Task No_answer_to_the_PUT_says_it_may_already_be_copying_not_try_again()
    {
        var (conn, copier, printer) = await ConnectAsync(DemoLaser, fail: r => r.Method == HttpMethod.Put ? new HttpRequestException("reset") : null);
        using var _ = conn;

        var result = await copier!.CopyAsync();

        Assert.False(result.Ok);
        Assert.Contains("may already be copying", result.Problem);
        Assert.DoesNotContain("Try again", result.Problem);
        Assert.Single(printer.Requests, s => s.Method == HttpMethod.Put);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    public async Task A_printer_asking_for_its_password_throws_for_the_caller_to_ask(HttpStatusCode status)
    {
        var (conn, copier, _) = await ConnectAsync(DemoLaser, status);
        using var _c = conn;

        var ex = await Assert.ThrowsAsync<LedmAuthRequiredException>(() => copier!.CopyAsync());
        Assert.False(ex.CredentialsWereSent);
    }

    // ------------------------------------------------------------------ hostile documents

    private const string Ns = "xmlns:c=\"urn:example:cap\" xmlns:d=\"urn:example:dyn\" xmlns:dd=\"urn:example:dd\"";

    private static string Dyn(string body = "<d:CopySettings><dd:Copies>1</dd:Copies></d:CopySettings><d:CopyState>idle</d:CopyState>") =>
        $"<d:CopyConfigDyn {Ns}>{body}</d:CopyConfigDyn>";

    private static string StartCap(string xpath = "d:CopyConfigDyn/d:CopyState", string access = "readWrite", string values = "<d:CopyState>start</d:CopyState>") =>
        $"<c:CopyStateSupport elementXPath=\"{xpath}\" access=\"{access}\">{values}</c:CopyStateSupport>";

    private static CopyStart? Read(string dyn, string capEntries) =>
        LedmCopy.Read(XDocument.Parse(dyn), XDocument.Parse($"<c:CopyConfigCap {Ns}>{capEntries}</c:CopyConfigCap>"));

    [Fact]
    public void Only_a_writable_explicit_start_command_counts()
    {
        Assert.NotNull(Read(Dyn(), StartCap()));
        Assert.Equal("startCopy", Read(Dyn(), StartCap(values: "<d:CopyState>idle</d:CopyState><d:CopyState>startCopy</d:CopyState>"))?.Value);
        Assert.Equal("Start", Read(Dyn(), StartCap(values: "<d:CopyState>Start</d:CopyState>"))?.Value); // the printer's own spelling

        Assert.Null(Read(Dyn(), StartCap(access: "readOnly")));
        Assert.Null(Read(Dyn(), StartCap(values: "<d:CopyState>processing</d:CopyState>"))); // a state, not a command
        Assert.Null(Read(Dyn(), StartCap(values: "<d:CopyState>idle</d:CopyState><d:CopyState>copying</d:CopyState>")));
        Assert.Null(Read(Dyn("<d:CopySettings />"), StartCap())); // the Cap names it, the Dyn hasn't got it
        Assert.Null(LedmCopy.Read(XDocument.Parse(Dyn()), null));
        // A writable copy setting that isn't a start (copies, say) never makes an offer.
        Assert.Null(Read(Dyn(), "<c:Copies min=\"1\" max=\"99\" elementXPath=\"d:CopyConfigDyn/d:CopySettings/dd:Copies\" access=\"readWrite\" />"));
    }

    [Fact]
    public void Long_choice_lists_and_long_values_are_cut()
    {
        var many = string.Concat(Enumerable.Range(0, 40).Select(i => $"<d:CopyState>junk{i}</d:CopyState>"));
        Assert.Null(Read(Dyn(), StartCap(values: many + "<d:CopyState>start</d:CopyState>"))); // past the 32 choices read
        Assert.Null(Read(Dyn(), StartCap(values: $"<d:CopyState>start{new string(' ', 100)}x</d:CopyState>")));
    }

    [Fact]
    public void The_whole_elementXPath_is_followed_not_just_its_last_step()
    {
        // A CopyState under CopySettings isn't the root's CopyState the Cap names.
        var nested = Dyn("<d:CopySettings><d:CopyState>idle</d:CopyState></d:CopySettings>");
        Assert.Null(Read(nested, StartCap()));
        Assert.Equal(["CopySettings", "CopyState"], Read(nested, StartCap("d:CopyConfigDyn/d:CopySettings/d:CopyState"))?.Path);
        Assert.Equal(["CopySettings", "CopyState"], Read(nested, StartCap("/d:CopySettings[1]/d:CopyState"))?.Path); // without the root, a leading slash, [1]
        // The second of a name: a PUT built from the first of each name couldn't reach it.
        var twice = Dyn("<d:CopySettings /><d:CopySettings><d:CopyState>idle</d:CopyState></d:CopySettings>");
        Assert.Null(Read(twice, StartCap("d:CopyConfigDyn/d:CopySettings[2]/d:CopyState")));
        Assert.Null(Read(twice, StartCap("d:CopyConfigDyn/d:CopySettings/d:CopyState")));
        // An element holding elements, not a value.
        Assert.Null(Read(Dyn("<d:CopyState><d:Inner>idle</d:Inner></d:CopyState>"), StartCap()));
    }

    [Theory]
    [InlineData("")]
    [InlineData("/")]
    [InlineData("d:CopyConfigDyn/d:CopyState[@x='1']")]
    [InlineData("d:CopyConfigDyn/d:CopyState[0]")]
    [InlineData("d:CopyConfigDyn/d:CopyState[")]
    [InlineData("d:CopyConfigDyn//d:CopyState")]
    [InlineData("d:CopyConfigDyn/*")]
    [InlineData("d:CopyConfigDyn/b:")]
    public void An_elementXPath_it_doesnt_understand_offers_nothing(string xpath) =>
        Assert.Null(Read(Dyn(), StartCap(xpath)));

    [Fact]
    public void A_very_long_or_deep_elementXPath_offers_nothing()
    {
        Assert.Null(Read(Dyn(), StartCap(string.Concat(Enumerable.Repeat("d:A/", 20)) + "d:CopyState")));
        Assert.Null(Read(Dyn(), StartCap("d:CopyConfigDyn/" + new string('a', 600) + "/d:CopyState")));
    }

    [Fact]
    public void Without_an_elementXPath_the_start_is_the_roots_child_named_like_the_entry()
    {
        var cap = "<c:CopyStateSupport access=\"readWrite\"><d:CopyState>start</d:CopyState></c:CopyStateSupport>";
        Assert.Equal(["CopyState"], Read(Dyn(), cap)?.Path);
        Assert.Null(Read(Dyn("<d:CopySettings><d:CopyState>idle</d:CopyState></d:CopySettings>"), cap)); // not anywhere below
    }

    // ------------------------------------------------------------------ which way a copy goes, and what the tab shows

    [Theory]
    [InlineData(true, true, false, true)]
    [InlineData(true, false, false, false)] // Through this PC, the default
    [InlineData(true, true, true, false)] // an ID card is laid out by the PC
    [InlineData(false, true, false, false)] // the printer doesn't offer it
    public void The_printer_copies_by_itself_only_when_it_offers_it_for_a_page_copy_and_it_was_chosen(bool offers, bool chosen, bool idCard, bool expected) =>
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

    [Fact]
    public void On_the_printer_no_option_is_shown_its_panel_decides()
    {
        Assert.Equal(new CopyControls(false, false, false, false, false), CopyRoute.Controls(onPrinter: true, idCard: false, copies: 5, queueTwoSided: true));
    }

    [Theory]
    [InlineData(false, 1, true, true, false, true, true, true)]
    [InlineData(false, 2, true, true, true, true, true, true)] // collate once there's more than one copy
    [InlineData(false, 2, false, true, true, true, false, true)] // two-sided only when the queue can
    [InlineData(true, 2, true, true, false, true, false, false)] // an ID card: one sheet, no collate, no page options
    public void Through_the_PC_the_options_follow_the_copy(bool idCard, int copies, bool queueTwoSided,
        bool showCopies, bool collate, bool color, bool twoSided, bool pcOptions) =>
        Assert.Equal(new CopyControls(showCopies, collate, color, twoSided, pcOptions), CopyRoute.Controls(onPrinter: false, idCard, copies, queueTwoSided));

    [Theory]
    [InlineData(0, 1)]
    [InlineData(-5, 1)]
    [InlineData(1, 1)]
    [InlineData(42, 42)]
    [InlineData(99, 99)]
    [InlineData(100, 99)]
    [InlineData(int.MaxValue, 99)]
    [InlineData(int.MinValue, 1)]
    public void Copies_stay_between_one_and_ninety_nine(int typed, int kept) => Assert.Equal(kept, CopyRoute.ClampCopies(typed));
}
