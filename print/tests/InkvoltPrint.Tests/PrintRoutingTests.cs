using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Printing.Direct;

namespace InkvoltPrint.Tests;

/// <summary>
/// A printer's print routing (<see cref="PrintRouting"/>, print/GLOSSARY.md): whether it has a Windows queue, can be set up,
/// takes jobs straight and the person may choose that, the route and its note, and the one event the tabs that print hear.
/// Decided before in Inkvolt Print's printer view model, untested; here through the module with a fake PC: a queue lookup
/// that finds what <see cref="FakePc.Queue"/> says, and a connection that takes raster when <see cref="FakePc.Raster"/> is set.
/// </summary>
public class PrintRoutingTests
{
    private static readonly IppClient RasterClient = new(new DeviceHttp("192.0.2.11"));

    private sealed class FakePc
    {
        public string? Queue;
        public IppClient? Raster;
        public Exception? LookupFails;
        public TaskCompletionSource<string?>? Slow; // a lookup that answers when the test says
        public int Lookups;
        public readonly List<bool> Remembered = [];
        public readonly List<string> Logged = [];

        /// <summary>A printer on this PC: a network printer (<paramref name="hasAddress"/>) or one known by its queue alone.</summary>
        public PrintRouting Printer(bool hasAddress = true, bool choseDirect = false) => new(FindQueue, () => Raster, hasAddress, choseDirect,
            Remembered.Add, Logged.Add);

        private Task<string?> FindQueue()
        {
            Lookups++;
            return Slow is { } slow ? slow.Task : LookupFails is { } fails ? Task.FromException<string?>(fails) : Task.FromResult(Queue);
        }
    }

    /// <summary>Counts <see cref="PrintRouting.Changed"/>, as one of the tabs hears it.</summary>
    private sealed class Tab
    {
        public int Heard;

        public Tab(PrintRouting routing) => routing.Changed += () => Heard++;
    }

    [Fact]
    public void Before_anything_is_said_a_printer_has_its_queue_and_is_offered_no_setting_up()
    {
        var routing = new FakePc().Printer();
        Assert.True(routing.HasQueue);
        Assert.True(routing.HasRoute);
        Assert.False(routing.NeedsSetup);
        Assert.False(routing.CanChooseDirect);
        Assert.Equal(PrintRoute.None, routing.Route);
        Assert.Equal(PrintRouteNote.None, routing.Note);
    }

    [Fact]
    public async Task It_has_a_queue_when_discovery_saw_one_or_a_lookup_found_one()
    {
        var routing = new FakePc().Printer();
        await routing.DiscoveredAsync(queueInstalled: false, pairs: true);
        Assert.False(routing.HasQueue);
        await routing.QueueLookedUpAsync(found: true);
        Assert.True(routing.HasQueue);
        await routing.QueueLookedUpAsync(found: false);
        Assert.False(routing.HasQueue);
        await routing.DiscoveredAsync(queueInstalled: true, pairs: true);
        Assert.True(routing.HasQueue);
    }

    [Theory]
    [InlineData(true, false, true)] // a network printer: Windows adds it by address
    [InlineData(false, true, true)] // discovery can pair it
    [InlineData(false, false, false)] // known by its queue alone, or a scanner on its own
    public async Task It_needs_setting_up_without_a_queue_when_it_can_be_set_up(bool hasAddress, bool pairs, bool canSetUp)
    {
        var routing = new FakePc().Printer(hasAddress);
        await routing.DiscoveredAsync(queueInstalled: false, pairs);
        Assert.Equal(canSetUp, routing.CanSetUp);
        Assert.Equal(canSetUp, routing.NeedsSetup);
        await routing.QueueLookedUpAsync(found: true);
        Assert.Equal(canSetUp, routing.CanSetUp);
        Assert.False(routing.NeedsSetup);
    }

    [Fact]
    public async Task A_scanner_on_its_own_has_nowhere_to_print_and_nothing_to_set_up()
    {
        var routing = new FakePc().Printer(hasAddress: false);
        await routing.QueueLookedUpAsync(found: false);
        Assert.False(routing.HasQueue);
        Assert.False(routing.HasRoute);
        Assert.False(routing.NeedsSetup);
        Assert.Equal(PrintRoute.None, routing.Route);
    }

    [Fact]
    public async Task Without_a_queue_a_printer_taking_raster_prints_straight_and_the_note_says_so()
    {
        var pc = new FakePc { Raster = RasterClient };
        var routing = pc.Printer();
        await routing.DiscoveredAsync(queueInstalled: false, pairs: false);
        Assert.Equal(PrintRoute.Direct, routing.Route);
        Assert.Equal(PrintRouteNote.Direct, routing.Note);
        Assert.True(routing.HasRoute); // Copy has somewhere to print
        Assert.False(routing.CanChooseDirect); // nothing to choose between
        Assert.True(routing.NeedsSetup); // other apps still can't print to it

        pc.Raster = null; // disconnected, or a reconnect that no longer offers raster
        await routing.DecideAsync();
        Assert.Equal(PrintRoute.None, routing.Route);
        Assert.Equal(PrintRouteNote.None, routing.Note);
        Assert.False(routing.HasRoute);
    }

    [Fact]
    public async Task With_a_queue_too_the_person_may_choose_straight_and_the_choice_is_kept_and_followed()
    {
        var pc = new FakePc { Queue = "Office inkjet", Raster = RasterClient };
        var routing = pc.Printer();
        await routing.DecideAsync();
        Assert.Equal(PrintRoute.Queue, routing.Route);
        Assert.True(routing.CanChooseDirect);
        Assert.Equal(PrintRouteNote.None, routing.Note);

        await routing.ChooseDirectAsync(true);
        Assert.True(routing.ChoseDirect);
        Assert.Equal([true], pc.Remembered);
        Assert.Equal(PrintRoute.Direct, routing.Route);
        Assert.Equal(PrintRouteNote.DirectChosen, routing.Note);
        Assert.Equal(PrintRoute.Direct, (await routing.Router.ChooseAsync()).Route); // every print follows the choice

        await routing.ChooseDirectAsync(false);
        Assert.Equal([true, false], pc.Remembered);
        Assert.Equal(PrintRoute.Queue, routing.Route);
        Assert.Equal(PrintRouteNote.None, routing.Note);
    }

    [Fact]
    public async Task A_choice_remembered_from_before_is_followed_and_needs_raster()
    {
        var pc = new FakePc { Queue = "Office inkjet" };
        var routing = pc.Printer(choseDirect: true);
        Assert.True(routing.ChoseDirect);
        await routing.DecideAsync();
        Assert.Equal(PrintRoute.Queue, routing.Route); // the printer doesn't take raster: the queue, and no choice offered
        Assert.False(routing.CanChooseDirect);
        pc.Raster = RasterClient;
        await routing.DecideAsync();
        Assert.Equal(PrintRoute.Direct, routing.Route);
        Assert.Equal(PrintRouteNote.DirectChosen, routing.Note);
        Assert.Empty(pc.Remembered); // nothing new to keep
    }

    [Fact]
    public async Task Every_tab_hears_a_change_of_route_once()
    {
        var pc = new FakePc { Queue = "Office inkjet", Raster = RasterClient };
        var routing = pc.Printer();
        Tab print = new(routing), copy = new(routing), photos = new(routing), jobs = new(routing);
        Tab[] tabs = [print, copy, photos, jobs];

        await routing.DecideAsync(); // connected: through the queue, the choice offered
        Assert.All(tabs, t => Assert.Equal(1, t.Heard));
        await routing.ChooseDirectAsync(true); // the person: straight
        Assert.All(tabs, t => Assert.Equal(2, t.Heard));
        pc.Raster = null;
        await routing.DecideAsync(); // reconnected without raster: back to the queue
        Assert.All(tabs, t => Assert.Equal(3, t.Heard));
        pc.Queue = null;
        await routing.QueueLookedUpAsync(found: false); // the queue was removed: told at once, then the route (nowhere)
        Assert.Equal(PrintRoute.None, routing.Route);
        Assert.All(tabs, t => Assert.Equal(5, t.Heard));
    }

    [Fact]
    public async Task A_queue_set_up_is_told_at_once_and_the_route_when_it_is_decided()
    {
        var pc = new FakePc();
        var routing = pc.Printer();
        await routing.DiscoveredAsync(queueInstalled: false, pairs: true);
        var told = new List<(bool NeedsSetup, PrintRoute Route)>();
        routing.Changed += () => told.Add((routing.NeedsSetup, routing.Route));

        pc.Slow = new TaskCompletionSource<string?>();
        var setUp = routing.QueueSetUpAsync(made: true);
        Assert.False(setUp.IsCompleted); // the lookup takes its time...
        Assert.Equal([(false, PrintRoute.None)], told); // ...the setup banner doesn't wait for it
        pc.Slow.SetResult("Office inkjet");
        await setUp;
        Assert.Equal([(false, PrintRoute.None), (false, PrintRoute.Queue)], told);
    }

    [Fact]
    public async Task Whether_it_takes_jobs_straight_comes_from_the_decision_it_goes_with()
    {
        var pc = new FakePc();
        var routing = pc.Printer();
        await routing.DiscoveredAsync(queueInstalled: false, pairs: false);
        Assert.False(routing.HasRoute);

        pc.Slow = new TaskCompletionSource<string?>();
        var deciding = routing.DecideAsync(); // started before the connection...
        pc.Raster = RasterClient; // ...which offers raster before the lookup ends: the router sees it
        pc.Slow.SetResult(null);
        await deciding;
        Assert.Equal(PrintRoute.Direct, routing.Route);
        Assert.True(routing.HasRoute);
    }

    [Fact]
    public async Task A_tab_that_fails_to_follow_doesnt_stop_the_others_or_the_setup()
    {
        var pc = new FakePc { Queue = "Office inkjet" };
        var routing = pc.Printer();
        routing.Changed += () => throw new InvalidOperationException("A tab broke.");
        var other = new Tab(routing);
        await routing.QueueSetUpAsync(made: true); // completes: the queue was made whatever a tab does
        Assert.Equal(2, other.Heard); // the queue at once, then its route
        Assert.Contains(pc.Logged, line => line.Contains("A tab broke."));
    }

    [Fact]
    public async Task Nothing_changed_is_not_told_and_the_queue_is_looked_up_again_only_when_having_one_changed()
    {
        var pc = new FakePc { Queue = "Office inkjet" };
        var routing = pc.Printer(hasAddress: false);
        var tab = new Tab(routing);
        await routing.DecideAsync();
        Assert.Equal(1, tab.Heard);
        await routing.DecideAsync(); // a reconnect with the same route
        await routing.ChooseDirectAsync(false); // the choice it had
        Assert.Equal(1, tab.Heard);
        Assert.Empty(pc.Remembered);

        var lookups = pc.Lookups;
        await routing.QueueLookedUpAsync(found: true); // it had one
        await routing.DiscoveredAsync(queueInstalled: true, pairs: false);
        Assert.Equal(lookups, pc.Lookups);
        Assert.Equal(1, tab.Heard);

        await routing.DiscoveredAsync(queueInstalled: true, pairs: true); // now it can pair: told, nothing decided
        Assert.Equal(2, tab.Heard);
        Assert.Equal(lookups, pc.Lookups);
    }

    [Fact]
    public async Task A_queue_set_up_or_made_again_is_always_told_and_decided_again()
    {
        var pc = new FakePc();
        var routing = pc.Printer();
        var tab = new Tab(routing);
        await routing.DiscoveredAsync(queueInstalled: false, pairs: true);
        Assert.True(routing.NeedsSetup);
        Assert.Equal(1, tab.Heard); // no queue; the route stays nowhere

        pc.Queue = "Office inkjet";
        await routing.QueueSetUpAsync(made: true); // Set up: the queue, then its route
        Assert.False(routing.NeedsSetup);
        Assert.Equal(PrintRoute.Queue, routing.Route);
        Assert.Equal(3, tab.Heard);

        var lookups = pc.Lookups;
        await routing.QueueSetUpAsync(made: true); // re-created (the HP clean-up): the same facts, a new queue
        Assert.Equal(4, tab.Heard);
        Assert.Equal(lookups + 1, pc.Lookups);

        pc.Queue = null;
        await routing.QueueSetUpAsync(made: false); // removed and not made again: told, then the route (nowhere)
        Assert.True(routing.NeedsSetup);
        Assert.Equal(PrintRoute.None, routing.Route);
        Assert.Equal(6, tab.Heard);
    }

    [Fact]
    public async Task A_decision_that_fails_changes_nothing_until_one_succeeds()
    {
        var pc = new FakePc { Raster = RasterClient };
        var routing = pc.Printer();
        await routing.DiscoveredAsync(queueInstalled: false, pairs: false);
        Assert.Equal(PrintRoute.Direct, routing.Route);
        var tab = new Tab(routing);

        pc.LookupFails = new InvalidOperationException("The spooler stopped.");
        pc.Raster = null; // disconnected meanwhile
        await routing.DecideAsync();
        Assert.Contains("Print route: The spooler stopped.", pc.Logged);
        Assert.Equal(PrintRoute.Direct, routing.Route); // as the last decision left it, all of it
        Assert.Equal(PrintRouteNote.Direct, routing.Note);
        Assert.True(routing.HasRoute);
        Assert.Equal(0, tab.Heard);

        pc.LookupFails = null;
        await routing.DecideAsync(); // the next one decides: nowhere now
        Assert.Equal(PrintRoute.None, routing.Route);
        Assert.Equal(PrintRouteNote.None, routing.Note);
        Assert.False(routing.HasRoute);
        Assert.Equal(1, tab.Heard);
    }
}
