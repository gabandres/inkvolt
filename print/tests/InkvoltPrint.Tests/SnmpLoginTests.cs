using System.Text.Json;
using InkvoltPrint.Core;
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

    [Fact]
    public void A_passphrase_too_long_for_Credential_Manager_is_refused_when_typed()
    {
        var fine = new string('p', SnmpV3User.MaxPassphrase);
        var pasted = new string('p', SnmpV3User.MaxPassphrase + 1);

        Assert.NotNull(SnmpLogin.ForUser("reader", fine, fine, out _));
        Assert.Null(SnmpLogin.ForUser("reader", pasted, fine, out var auth));
        Assert.Contains($"{SnmpV3User.MaxPassphrase}", auth);
        Assert.Null(SnmpLogin.ForUser("reader", fine, pasted, out var priv));
        Assert.Contains($"{SnmpV3User.MaxPassphrase}", priv);
        // The longest login it takes fits: 4,000 characters was fine in the vault on the PC this was tried on, 20,000 wasn't.
        var longest = SnmpLogin.ForUser(new string('é', SnmpV3User.MaxName / 2), new string('€', SnmpV3User.MaxPassphrase), new string('€', SnmpV3User.MaxPassphrase), out _)!;
        Assert.True(longest.ToSecret().Length < 2560, $"{longest.ToSecret().Length}");
    }

    [Fact]
    public void A_user_name_is_measured_as_the_agent_does_in_bytes()
    {
        Assert.NotNull(SnmpLogin.ForUser(new string('a', SnmpV3User.MaxName), "authpassphrase", "privpassphrase", out _));
        Assert.Null(SnmpLogin.ForUser(new string('é', SnmpV3User.MaxName), "authpassphrase", "privpassphrase", out var error)); // 64 bytes
        Assert.NotNull(error);
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

    // ------------------------------------------------------------------ SNMP access…'s check and the refused state (the Mac's first)

    /// <summary>SnmpV3Tests' passphrases (and wrong ones).</summary>
    private static readonly SnmpV3User User = new("reader", "authpass-2026", "privpass-2026");

    private static readonly byte[] Engine = "inkvolt-engine"u8.ToArray();

    private static SnmpAgent V3Agent() =>
        new(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", "workgroup-laser.txt"))), User, Engine);

    private static SnmpLogin V3Login(string? auth = null, string? priv = null) =>
        SnmpLogin.ForUser(User.Name, auth ?? User.AuthPassphrase, priv ?? User.PrivPassphrase, out _)!;

    private static PrinterMonitor Monitor(ISnmpTransport agent, SnmpDevice known, SnmpLogin login, List<MonitorEvent>? events = null) =>
        new(Printer, () => "Laser", new PrinterWhere(Host, Snmp: known),
            new PrinterRecipe(() => new HostRouter(new Dictionary<string, HttpMessageHandler>()), agent, SnmpLogin: () => login),
            () => [], _ => { }, e =>
            {
                if (events is null) return;
                lock (events) events.Add(e);
            });

    [Fact]
    public async Task A_refused_login_is_its_own_state_not_offline()
    {
        var agent = V3Agent();
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, Host, V3Login()))!.Identity);
        var events = new List<MonitorEvent>();
        using var monitor = Monitor(agent, known, V3Login(auth: "wrong-auth-pass"), events);

        Assert.False(await monitor.CheckAsync(false, default));
        Assert.True(monitor.View.IsRefused);
        Assert.False(monitor.View.IsOnline);
        Assert.NotEqual(CoreStrings.Monitor_CantReach, monitor.View.StatusMessage);
        Assert.Contains("authentication passphrase", monitor.View.StatusDetail);
        Assert.Equal(monitor.View.StatusMessage, monitor.View.ListLine);
        // Its alert is the refusal, not offline: nothing read, which part said.
        lock (events)
            Assert.All(events.OfType<MonitorEvent.Observed>(), o => Assert.Equal(SnmpRefusal.WrongAuthKey, o.Snapshot.LoginRefused));

        using var session = new PrinterSession(Printer, new PrinterRecipe(() => new HostRouter(new Dictionary<string, HttpMessageHandler>()), agent,
            SnmpLogin: () => V3Login(priv: "wrong-priv-pass")), () => [], _ => { });
        var refused = Assert.IsType<SessionStep.Refused>(await session.ConnectAsync(new PrinterWhere(Host, Snmp: known), default));
        Assert.Equal(SnmpRefusal.WrongPrivKey, refused.Reason);
        Assert.Null(session.Connection);
    }

    [Fact]
    public async Task A_login_refused_on_a_connection_reads_as_refused_not_offline()
    {
        var agent = new SnmpV3Tests.Spoofer(V3Agent());
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, Host, V3Login()))!.Identity);
        using var monitor = Monitor(agent, known, V3Login());
        Assert.True(await monitor.CheckAsync(false, default));

        (agent.Counter, agent.EngineId) = (Usm.WrongDigests, Engine); // the printer's administrator changed its key
        await Task.Delay(SnmpPrinterClient.Shared + TimeSpan.FromMilliseconds(100)); // past the read shared by status and supplies
        // Windows difference: a refusal on a connection whose login answered signed isn't trusted (anyone can send one), so that
        // read is offline; the next connection discovers the engine again and its refusal decides.
        Assert.False(await monitor.CheckAsync(false, default));
        Assert.False(monitor.View.IsRefused);
        Assert.False(await monitor.CheckAsync(false, default));
        Assert.True(monitor.View.IsRefused);
        Assert.Contains("authentication passphrase", monitor.View.StatusDetail);

        (agent.Counter, agent.EngineId) = (null, []); // SNMP access… set it right: the next check connects and reads again
        Assert.True(await monitor.CheckAsync(false, default));
        Assert.False(monitor.View.IsRefused);
        Assert.True(monitor.View.IsOnline);
    }

    [Fact]
    public async Task A_refusal_spoofed_on_a_connection_never_shows_the_printer_refused_or_silences_its_alerts()
    {
        var agent = new SnmpV3Tests.Spoofer(V3Agent());
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, Host, V3Login()))!.Identity);
        var events = new List<MonitorEvent>();
        using var monitor = Monitor(agent, known, V3Login(), events);
        Assert.True(await monitor.CheckAsync(false, default));

        (agent.Counter, agent.EngineId) = (Usm.UnknownUserNames, Engine); // unsigned, from the printer's own engine ID, by someone else
        await Task.Delay(SnmpPrinterClient.Shared + TimeSpan.FromMilliseconds(100));
        Assert.False(await monitor.CheckAsync(false, default));
        Assert.False(monitor.View.IsRefused); // offline: its offline alert follows as for any printer that stops answering
        lock (events) Assert.False(events.OfType<MonitorEvent.Observed>().Last().Snapshot.Reachable);

        (agent.Counter, agent.EngineId) = (null, []); // gone: connected again, read as itself
        Assert.True(await monitor.CheckAsync(false, default));
        lock (events) Assert.DoesNotContain(events.OfType<MonitorEvent.Observed>(), o => o.Snapshot.LoginRefused is not null);
    }

    [Fact]
    public async Task A_refusal_after_another_device_answered_keeps_it_elsewhere()
    {
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(V3Agent(), Host, V3Login()))!.Identity);
        var other = new SnmpV3Tests.Spoofer(new SnmpAgent(SnmpAgent.ParseWalk(File.ReadAllText(
            Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", "workgroup-laser.txt")).Replace("DEMO0005200", "OTHER0001")), User, Engine));
        using var monitor = Monitor(other, known, V3Login());
        Assert.False(await monitor.CheckAsync(false, default));
        Assert.True(monitor.View.IsElsewhere);
        Assert.True(monitor.CanAcceptDevice);

        (other.Counter, other.EngineId) = (Usm.WrongDigests, Engine); // it refuses now, without saying who it is
        Assert.False(await monitor.CheckAsync(false, default));
        Assert.True(monitor.View.IsRefused);
        Assert.True(monitor.View.IsElsewhere); // still the device that answered last: "This is my printer" stays offered
        Assert.True(monitor.CanAcceptDevice);
    }

    /// <summary>A switch with SNMPv3 at the address (DHCP gave it the printer's old one): it refuses a user it doesn't know.</summary>
    private static SnmpAgent Switch() =>
        new(SnmpAgent.ParseWalk(".1.3.6.1.2.1.1.5.0 = STRING: \"core-switch\""), new SnmpV3User("admin", "switch-auth-1", "switch-priv-1"), "switch-engine"u8.ToArray());

    [Fact]
    public async Task A_refusal_from_an_engine_not_known_as_the_printers_is_offline_not_refused()
    {
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(V3Agent(), Host, V3Login()))!.Identity);
        Assert.Equal(Convert.ToHexString(Engine), known.EngineId); // remembered from its signed answer

        // Another device's engine: offline, so Fix it… looks for the printer; no refused alert.
        var events = new List<MonitorEvent>();
        using (var monitor = Monitor(Switch(), known, V3Login(), events))
        {
            Assert.False(await monitor.CheckAsync(false, default));
            Assert.False(monitor.View.IsRefused);
            Assert.Equal(CoreStrings.Monitor_CantReach, monitor.View.StatusMessage);
            lock (events) Assert.All(events.OfType<MonitorEvent.Observed>(), o => Assert.Null(o.Snapshot.LoginRefused));
        }

        // No engine remembered (never read over SNMPv3): even the printer's own refusal can't be told from another device's.
        using var session = new PrinterSession(Printer, new PrinterRecipe(() => new HostRouter(new Dictionary<string, HttpMessageHandler>()), V3Agent(),
            SnmpLogin: () => V3Login(auth: "wrong-auth-pass")), () => [], _ => { });
        Assert.IsType<SessionStep.Offline>(await session.ConnectAsync(new PrinterWhere(Host, Snmp: known with { EngineId = null }), default));
        Assert.IsType<SessionStep.Offline>(await session.ConnectAsync(new PrinterWhere(Host, Snmp: known with { EngineId = "80001F8880AAAAAAAAAAAAAAAA" }), default));
        Assert.IsType<SessionStep.Refused>(await session.ConnectAsync(new PrinterWhere(Host, Snmp: known), default));
    }

    [Fact]
    public async Task A_signed_connection_remembers_the_printers_engine_so_its_refusal_counts_after()
    {
        var agent = new SnmpV3Tests.Spoofer(V3Agent());
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, Host, V3Login()))!.Identity) with { EngineId = null }; // read over v2c before, say
        using var monitor = Monitor(agent, known, V3Login());
        Assert.True(await monitor.CheckAsync(false, default));
        Assert.Equal(Convert.ToHexString(Engine), monitor.Target.Snmp!.EngineId); // kept in state.json when the app remembers it
        Assert.Equal(known.SerialNumber, monitor.Target.Snmp.SerialNumber);

        (agent.Counter, agent.EngineId) = (Usm.WrongDigests, Engine); // its administrator changed the key
        await Task.Delay(SnmpPrinterClient.Shared + TimeSpan.FromMilliseconds(100));
        Assert.False(await monitor.CheckAsync(false, default)); // on the open connection: offline (anyone can send one)
        Assert.False(await monitor.CheckAsync(false, default)); // a new connection, its own engine: refused
        Assert.True(monitor.View.IsRefused);

        // What state.json keeps of it: the engine ID (not a secret), never the login.
        var remembered = JsonSerializer.Serialize(monitor.Target.Snmp);
        Assert.Contains(Convert.ToHexString(Engine), remembered);
        Assert.DoesNotContain(User.AuthPassphrase, remembered);
        Assert.DoesNotContain(User.PrivPassphrase, remembered);
        Assert.DoesNotContain(User.Name, remembered);
    }

    [Fact]
    public async Task Checking_a_login_refused_by_an_engine_not_known_as_the_printers_may_be_saved_anyway()
    {
        var device = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(V3Agent(), Host, V3Login()))!.Identity);
        Assert.Equal(new SnmpLoginCheck.Refused(SnmpRefusal.UnknownUser, FromThisPrinter: false), await SnmpLoginCheck.CheckAsync(V3Login(), Host, device, Switch()));
        Assert.Equal(new SnmpLoginCheck.Refused(SnmpRefusal.WrongAuthKey, FromThisPrinter: false),
            await SnmpLoginCheck.CheckAsync(V3Login(auth: "wrong-auth-pass"), Host, device with { EngineId = null }, V3Agent()));
        Assert.Equal(new SnmpLoginCheck.Refused(SnmpRefusal.WrongAuthKey, FromThisPrinter: false), await SnmpLoginCheck.CheckAsync(V3Login(auth: "wrong-auth-pass"), Host, null, V3Agent()));

        var save = new SnmpLoginSave(SnmpLogin.Public, (_, _) => SnmpLoginCheck.CheckAsync(V3Login(), Host, device, Switch()));
        var (keep, problem) = await save.SaveAsync(V3Login());
        Assert.False(keep);
        Assert.Equal(string.Format(CoreStrings.SnmpCheck_RefusedUnknown, CoreStrings.Snmp_UnknownUser), problem);
        Assert.True(save.IsSaveAnyway(V3Login()));
        Assert.Equal((true, (string?)null), await save.SaveAsync(V3Login())); // Save anyway: kept as it is
    }

    [Fact]
    public void The_cards_own_offline_state_drops_the_refused_one()
    {
        // The view model's own offline (a check that failed, a queue or scanner path) says Can't reach: Fix it…, not SNMP access….
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        var source = File.ReadAllText(Path.Combine(dir!.FullName, "print", "src", "InkvoltPrint.App", "ViewModels", "PrinterViewModel.cs"));
        var setOffline = source[source.IndexOf("private void SetOffline(string message, string detail)", StringComparison.Ordinal)..];
        Assert.Contains("IsRefused = false;", setOffline[..setOffline.IndexOf("Observe(", StringComparison.Ordinal)]);
    }

    [Fact]
    public async Task Checking_a_login_says_whether_its_answered_or_which_part_is_refused()
    {
        var agent = V3Agent();
        var device = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, Host, V3Login()))!.Identity);
        Assert.IsType<SnmpLoginCheck.Answered>(await SnmpLoginCheck.CheckAsync(V3Login(), Host, device, agent));
        Assert.Equal(new SnmpLoginCheck.Refused(SnmpRefusal.WrongAuthKey), await SnmpLoginCheck.CheckAsync(V3Login(auth: "wrong-auth-pass"), Host, device, agent));
        Assert.Equal(new SnmpLoginCheck.Refused(SnmpRefusal.WrongPrivKey), await SnmpLoginCheck.CheckAsync(V3Login(priv: "wrong-priv-pass"), Host, device, agent));
        Assert.IsType<SnmpLoginCheck.NoAnswer>(await SnmpLoginCheck.CheckAsync(Login(Secret), Host, device, agent));

        var other = new SnmpAgent(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", "workgroup-laser.txt"))
            .Replace("DEMO0005200", "OTHER0001")), Secret);
        Assert.IsType<SnmpLoginCheck.AnotherDevice>(await SnmpLoginCheck.CheckAsync(Login(Secret), Host, device, other));
    }

    [Fact]
    public async Task A_refusal_spoofed_from_another_engine_is_no_answer_not_a_refusal()
    {
        // Anyone on the network can send an unsigned report: one from another engine says nothing about this printer's login.
        var agent = new SnmpV3Tests.Spoofer(V3Agent()) { Counter = Usm.WrongDigests, EngineId = "someone-else"u8.ToArray() };
        Assert.IsType<SnmpLoginCheck.NoAnswer>(await SnmpLoginCheck.CheckAsync(V3Login(), Host, null, agent));
    }

    [Fact]
    public async Task A_check_whose_network_fails_oddly_is_no_answer_and_only_cancelling_it_stops_it()
    {
        Assert.IsType<SnmpLoginCheck.NoAnswer>(await SnmpLoginCheck.CheckAsync(Login(Secret), Host, null, new Throwing(new IOException("unreachable"))));
        Assert.IsType<SnmpLoginCheck.NoAnswer>(await SnmpLoginCheck.CheckAsync(Login(Secret), Host, null, new Throwing(new OperationCanceledException())));
        Assert.IsType<SnmpLoginCheck.NoAnswer>(await SnmpLoginCheck.CheckAsync(V3Login(), Host, null, new Garbage()));
        using var cancelled = new CancellationTokenSource();
        await cancelled.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => SnmpLoginCheck.CheckAsync(Login(Secret), Host, null, Agent(), cancelled.Token));
    }

    [Fact]
    public async Task Saving_keeps_the_login_kept_now_unasked_and_any_other_only_once_answered_or_saved_anyway()
    {
        var asked = new List<SnmpLogin>();
        SnmpLoginCheck answer = new SnmpLoginCheck.NoAnswer();
        var save = new SnmpLoginSave(Login(Secret), (login, _) =>
        {
            asked.Add(login);
            return Task.FromResult(answer);
        });

        Assert.Equal((true, (string?)null), await save.SaveAsync(Login(Secret))); // unchanged: nothing to ask
        Assert.Empty(asked);

        var (keep, problem) = await save.SaveAsync(Login("new-one"));
        Assert.False(keep);
        Assert.Contains("didn't answer with this community", problem);
        Assert.True(save.IsSaveAnyway(Login("new-one")));
        Assert.False(save.IsSaveAnyway(Login("another")));
        Assert.Equal((true, (string?)null), await save.SaveAsync(Login("new-one"))); // Save anyway: kept as it is, not asked again
        Assert.Single(asked);

        Assert.Contains("SNMPv3", (await save.SaveAsync(V3Login())).Problem); // another login: asked, and Save anyway is for it only
        Assert.False(save.IsSaveAnyway(Login("new-one")));

        answer = new SnmpLoginCheck.Refused(SnmpRefusal.UnknownUser);
        (keep, problem) = await save.SaveAsync(V3Login(auth: "wrong-auth-pass"));
        Assert.False(keep);
        Assert.Equal(string.Format(CoreStrings.SnmpCheck_Refused, CoreStrings.Snmp_UnknownUser), problem);
        Assert.False(save.IsSaveAnyway(V3Login(auth: "wrong-auth-pass"))); // a refusal is never kept anyway
        Assert.False((await save.SaveAsync(V3Login(auth: "wrong-auth-pass"))).Keep);

        // No answer, then the fields edited and the same login typed back: asked again, never kept unasked.
        answer = new SnmpLoginCheck.NoAnswer();
        Assert.False((await save.SaveAsync(Login("typed-back"))).Keep);
        save.Edited();
        Assert.False(save.IsSaveAnyway(Login("typed-back")));
        var before = asked.Count;
        Assert.False((await save.SaveAsync(Login("typed-back"))).Keep);
        Assert.Equal(before + 1, asked.Count);

        answer = new SnmpLoginCheck.AnotherDevice();
        Assert.Equal((false, CoreStrings.SnmpCheck_AnotherDevice), await save.SaveAsync(Login("other-device")));
        answer = new SnmpLoginCheck.Answered();
        Assert.Equal((true, (string?)null), await save.SaveAsync(Login("other-device")));
        // What the dialog shows never holds the secret typed.
        Assert.All(new[] { CoreStrings.SnmpCheck_NoAnswerCommunity, CoreStrings.SnmpCheck_NoAnswerUser }, s => Assert.DoesNotContain("new-one", s));
    }

    /// <summary>A network that fails with <paramref name="error"/> on every request.</summary>
    private sealed class Throwing(Exception error) : ISnmpTransport
    {
        public Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct) => Task.FromException<byte[]?>(error);
    }

    /// <summary>An agent that answers every request with bytes that aren't SNMP.</summary>
    private sealed class Garbage : ISnmpTransport
    {
        public Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct) => Task.FromResult<byte[]?>([0x30, 0x84, 0xff, 0xff, 0xff, 0xff, 0x02]);
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
