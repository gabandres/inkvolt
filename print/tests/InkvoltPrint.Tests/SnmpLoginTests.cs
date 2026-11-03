using System.Text.Json;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// A community per printer (roadmap 3.2): the login kept through its store's seam (memory here; Credential Manager in the app),
/// the made-up agent answering only to the right community, every read of the printer using it, and none of it reaching
/// state.json or a log line.
/// </summary>
public class SnmpLoginTests
{
    private const string Printer = "12345678-1234-4abc-8def-123456789abc", Host = "192.0.2.14", Secret = "kx9-office ro";

    private static SnmpAgent Agent(string community = Secret) =>
        new(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", "workgroup-laser.txt"))), community);

    private static SnmpLogin Login(string community) => SnmpLogin.ForCommunity(community, out _)!;

    [Fact]
    public void A_community_round_trips_as_its_kept_secret()
    {
        var login = Login(Secret);
        Assert.Equal(Secret, login.Community);
        Assert.False(login.IsDefault);
        Assert.Equal(login, SnmpLogin.FromSecret(login.ToSecret()));
        Assert.Equal(" spaced ", SnmpLogin.FromSecret(Login(" spaced ").ToSecret())!.Community); // an agent compares bytes: kept as typed
        Assert.Null(SnmpLogin.FromSecret("v9:something"));
        Assert.Null(SnmpLogin.FromSecret(null));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("public")]
    public void Blank_or_public_is_the_default_and_nothing_is_kept(string? typed)
    {
        var login = SnmpLogin.ForCommunity(typed, out var error);
        Assert.Null(error);
        Assert.Equal(SnmpLogin.Public.Community, login!.Community);
        Assert.True(login.IsDefault);
    }

    [Fact]
    public void A_community_that_cant_be_sent_is_refused_with_why()
    {
        Assert.Null(SnmpLogin.ForCommunity("line\nbreak", out var control));
        Assert.Contains("control characters", control);
        Assert.Null(SnmpLogin.ForCommunity(new string('c', SnmpLogin.MaxCommunity + 1), out var tooLong));
        Assert.Contains("255", tooLong);
        Assert.NotNull(SnmpLogin.ForCommunity(new string('c', SnmpLogin.MaxCommunity), out _));
    }

    [Fact]
    public void The_store_keeps_renames_and_deletes_a_printers_login()
    {
        var store = new MemorySnmpLogins();
        ISnmpLogins logins = store;
        Assert.Null(logins.Get(Printer));
        logins.Save(Printer, Login(Secret));
        Assert.Equal(Secret, logins.Get(Printer.ToUpperInvariant())!.Community);

        logins.Rename(Printer, Host);
        Assert.Null(logins.Get(Printer));
        Assert.Equal(Secret, logins.Get(Host)!.Community);

        logins.Save(Host, SnmpLogin.Public); // public: what was kept goes, nothing takes its place
        Assert.Null(logins.Get(Host));
        Assert.Equal(0, store.Count);
    }

    [Fact]
    public void Renaming_never_overwrites_a_login_kept_under_the_new_id()
    {
        ISnmpLogins logins = new MemorySnmpLogins();
        logins.Save("a", Login("first"));
        logins.Save("b", Login("second"));
        logins.Rename("a", "b");
        Assert.Equal("second", logins.Get("b")!.Community);
        Assert.Null(logins.Get("a"));
    }

    [Fact]
    public async Task The_agent_answers_only_to_its_community_and_every_read_uses_it()
    {
        var agent = Agent();
        Assert.Null(await SnmpPrinterClient.ProbeAsync(agent, Host)); // public: silence, as from a real agent
        Assert.Null(await SnmpPrinterClient.ProbeAsync(agent, Host, Login("wrong")));
        var before = agent.Received.Count;

        var printer = await SnmpPrinterClient.ProbeAsync(agent, Host, Login(Secret));
        Assert.NotNull(printer);
        Assert.Equal("DEMO0005200", printer.Identity.SerialNumber);
        Assert.Equal(3, (await printer.GetSuppliesAsync()).Count);
        Assert.NotNull(await printer.ReadIdentityAsync());
        Assert.All(agent.Received.Skip(before), m => Assert.Equal(Secret, m.Community));
    }

    [Fact]
    public async Task A_session_connects_with_the_login_kept_now_and_without_it_the_printer_is_offline()
    {
        var agent = Agent();
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, Host, Login(Secret)))!.Identity);
        var where = new PrinterWhere(Host, Snmp: known);
        ISnmpLogins logins = new MemorySnmpLogins();
        var recipe = new PrinterRecipe(() => new HostRouter(new Dictionary<string, HttpMessageHandler>()), agent, SnmpLogin: () => logins.Get(Printer));

        using (var session = new PrinterSession(Printer, recipe, () => [], _ => { }))
            Assert.IsType<SessionStep.Offline>(await session.ConnectAsync(where, default)); // nothing kept: public, which it ignores

        logins.Save(Printer, Login(Secret)); // the printer's menu › SNMP access…, then a new connection
        using (var session = new PrinterSession(Printer, recipe, () => [], _ => { }))
        {
            Assert.IsType<SessionStep.Connected>(await session.ConnectAsync(where, default));
            var read = Assert.IsType<SessionStep.Read>(await session.ReadAsync(where, default));
            Assert.Equal(3, read.Reading.Supplies!.Count);
            Assert.True(session.Connection!.OverSnmp);
        }
        Assert.Contains(agent.Received, m => m.Community == Secret);
    }

    [Fact]
    public async Task Neither_what_is_remembered_nor_a_log_line_holds_the_community()
    {
        var identity = (await SnmpPrinterClient.ProbeAsync(Agent(), Host, Login(Secret)))!.Identity;
        Assert.Equal(Secret, identity.LoginOrPublic.Community); // the identity knows it, for this run's reads only

        // state.json keeps a printer read over SNMP as its SnmpDevice: what the printer said, never the login.
        var remembered = JsonSerializer.Serialize(new { Printers = new[] { new { Uuid = Host, Host, Snmp = SnmpDevice.From(identity) } } });
        Assert.DoesNotContain(Secret, remembered);
        Assert.DoesNotContain("community", remembered, StringComparison.OrdinalIgnoreCase);

        // What the log may show of either.
        Assert.DoesNotContain(Secret, identity.ToString());
        Assert.DoesNotContain(Secret, identity.LoginOrPublic.ToString());
        Assert.DoesNotContain(Secret, new PrinterWhere(Host, Snmp: SnmpDevice.From(identity)).ToString());
    }

    [Fact]
    public void The_apps_state_file_has_no_place_for_a_login()
    {
        // The app's state (Inkvolt Print's state.json) is written from AppState and KnownPrinter: neither may name a login or a community.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var source = File.ReadAllText(Path.Combine(dir.FullName, "print", "src", "InkvoltPrint.App", "AppState.cs"));
        Assert.DoesNotContain("SnmpLogin", source);
        Assert.DoesNotContain("Community", source);
    }
}
