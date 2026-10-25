using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Tests;

/// <summary>The printer list module (<see cref="PrinterList"/>): queue printers, Windows' scanners, the hidden list and the selection.</summary>
public class PrinterListTests
{
    private const string Laser = "12345678-1234-4abc-8def-123456789abc";

    private static readonly SpoolerQueue Usb = new("Demo USB laser", "USB001", "Demo Laser 2100 PCL6", 0, SpoolerFlags.AttributeLocal, 0) { PortMonitor = "USB Monitor" };
    private static readonly SpoolerQueue Tcp = new("Office color MFP", "Office color", "Demo Color MFP 4400 PCL6", 0, SpoolerFlags.AttributeLocal, 0)
        { PortMonitor = "Standard TCP/IP Port", PortAddress = "192.0.2.15" };
    private static readonly SpoolerQueue Pdf = new("Microsoft Print to PDF", "PORTPROMPT:", "Microsoft Print To PDF", 0, SpoolerFlags.AttributeLocal, 0);
    private static readonly SpoolerQueue LaserWsd = new("HP LaserJet MFP M234dw (WSD)", "WSD-00000000-0000-4000-8000-000000000000", "Microsoft IPP Class Driver",
        0, SpoolerFlags.AttributeLocal, 0) { PortMonitor = "WSD Port Monitor", ContainerId = Laser };

    private static readonly WiaDeviceInfo UsbScanner = new(@"{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\0000", "Demo Laser 2100", "Demo", "Demo Laser 2100 scanner");
    private static readonly WiaDeviceInfo Flatbed = new(@"{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\0001", "Demo Photo Scanner 40", "Demo", "Demo Photo Scanner 40");

    private static readonly ListedPrinter Network = new(Laser, ListedKind.Network, "HP LaserJet MFP M234dw", "HP LaserJet MFP M234dw", "192.0.2.10");

    private static PrinterListInput Input(IReadOnlyList<ListedPrinter> listed, string? selected = null, IReadOnlyList<SpoolerQueue>? queues = null,
        bool sweepDone = true, IReadOnlyList<WiaDeviceInfo>? scanners = null, params string[] forgotten) =>
        new(listed, selected, queues, sweepDone, scanners, forgotten);

    /// <summary>The list after the change, as the caller makes it.</summary>
    private static List<ListedPrinter> Apply(IReadOnlyList<ListedPrinter> listed, PrinterListChange change) =>
        [.. listed.Where(p => !change.Removed.Contains(p.Id)), .. change.AddedQueues.Select(ListedPrinter.ForQueue), .. change.AddedScanners.Select(ListedPrinter.ForScanner)];

    [Fact]
    public void Real_queues_no_network_printer_stands_for_are_listed()
    {
        var change = PrinterList.Reconcile(Input([Network], Laser, [Usb, Tcp, Pdf, LaserWsd]));

        Assert.Equal([Usb, Tcp], change.AddedQueues); // not the PDF printer, not the laser's own WSD queue
        Assert.Empty(change.Removed);
        Assert.Equal(Laser, change.Selected);
        Assert.Null(change.WindowsScanners); // scanners not read yet
    }

    [Fact]
    public void Network_queues_wait_for_discovery_s_first_sweep()
    {
        var change = PrinterList.Reconcile(Input([], null, [Usb, Tcp], sweepDone: false));

        Assert.Equal([Usb], change.AddedQueues);
        Assert.Equal(QueueKinds.IdFor(Usb.Name), change.Selected); // nothing was selected
    }

    [Fact]
    public void A_queue_the_user_removed_stays_hidden_until_Windows_no_longer_has_it()
    {
        var hidden = QueueKinds.IdFor(Usb.Name);
        var change = PrinterList.Reconcile(Input([], null, [Usb, Tcp], forgotten: hidden));
        Assert.Equal([Tcp], change.AddedQueues);
        Assert.Empty(change.Unforget);

        Assert.Equal([hidden], PrinterList.Reconcile(Input([], null, [Tcp], forgotten: hidden)).Unforget);
        Assert.Empty(PrinterList.Reconcile(Input([], null, [], forgotten: hidden)).Unforget); // no queues read: nothing to go by
    }

    [Fact]
    public void A_queue_a_network_printer_now_stands_for_goes_and_the_selection_moves_to_that_printer()
    {
        var wsd = ListedPrinter.ForQueue(LaserWsd);

        var change = PrinterList.Reconcile(Input([Network, wsd], wsd.Id, [LaserWsd]));

        Assert.Equal([wsd.Id], change.Removed);
        Assert.Equal(Laser, change.Selected);
    }

    [Fact]
    public void A_queue_renamed_in_Windows_keeps_the_selection_and_stays_hidden_if_it_was()
    {
        var renamed = Usb with { Name = "Front office laser" };
        var old = ListedPrinter.ForQueue(Usb);
        var renames = new Dictionary<string, SpoolerQueue> { [old.Id] = renamed };

        var change = PrinterList.Reconcile(Input([Network, old], old.Id, [renamed]) with { Renamed = renames });
        Assert.Equal([old.Id], change.Removed);
        Assert.Equal(QueueKinds.IdFor(renamed.Name), change.Selected);

        var hiddenChange = PrinterList.Reconcile(Input([Network], Laser, [renamed], forgotten: old.Id) with { Renamed = renames });
        Assert.Equal([QueueKinds.IdFor(renamed.Name)], hiddenChange.Forget);
        Assert.Empty(hiddenChange.AddedQueues);
        Assert.Equal([old.Id], hiddenChange.Unforget); // the old name is gone from Windows
    }

    [Fact]
    public void A_queue_chosen_last_time_is_selected_when_it_is_listed()
    {
        var change = PrinterList.Reconcile(Input([Network], Laser, [Usb, Tcp]) with { WantedQueue = QueueKinds.IdFor(Tcp.Name) });

        Assert.Equal(QueueKinds.IdFor(Tcp.Name), change.Selected);
        Assert.Null(change.WantedQueue); // the sweep is done: not waited for any more
    }

    [Fact]
    public void A_scanner_goes_to_the_queue_printer_it_belongs_to_and_one_no_printer_claims_is_listed_on_its_own()
    {
        var usb = ListedPrinter.ForQueue(Usb);

        var change = PrinterList.Reconcile(Input([Network, usb], Laser, null, scanners: [UsbScanner, Flatbed]));

        Assert.Equal(UsbScanner, change.WindowsScanners![usb.Id]);
        Assert.Null(change.WindowsScanners[Laser]); // it scans over eSCL: it doesn't want one
        Assert.Equal([Flatbed], change.AddedScanners);
        Assert.Equal(Laser, change.Selected);
    }

    [Fact]
    public void Queues_and_scanners_in_one_pass_give_a_new_queue_printer_its_scanner()
    {
        var change = PrinterList.Reconcile(Input([Network], Laser, [Usb], scanners: [UsbScanner]));

        Assert.Equal([Usb], change.AddedQueues);
        Assert.Equal(UsbScanner, change.WindowsScanners![QueueKinds.IdFor(Usb.Name)]);
        Assert.Empty(change.AddedScanners);
    }

    [Fact]
    public void A_scanner_on_its_own_goes_when_Windows_drops_it_unless_it_holds_unsaved_scans()
    {
        var flatbed = ListedPrinter.ForScanner(Flatbed);

        var change = PrinterList.Reconcile(Input([Network, flatbed], flatbed.Id, null, scanners: []));
        Assert.Equal([flatbed.Id], change.Removed);
        Assert.Equal(Laser, change.Selected);

        var keeping = PrinterList.Reconcile(Input([Network, flatbed with { HasUnsavedScans = true }], flatbed.Id, null, scanners: []));
        Assert.Empty(keeping.Removed);
        Assert.Equal(flatbed.Id, keeping.Selected);
    }

    [Fact]
    public void A_hidden_scanner_stays_hidden_until_Windows_no_longer_has_it()
    {
        var id = PrinterList.ScannerIdFor(Flatbed.Id);

        Assert.Empty(PrinterList.Reconcile(Input([], null, null, scanners: [Flatbed], forgotten: id)).AddedScanners);
        Assert.Equal([id], PrinterList.Reconcile(Input([], null, null, scanners: [], forgotten: id)).Unforget);
    }

    [Fact]
    public void Removing_a_network_printer_hides_its_queues_and_its_Windows_scanner_with_it()
    {
        var withoutEscl = Network with { WantsWindowsScanner = true, Model = "Demo Laser 2100" };

        var hidden = PrinterList.HiddenWith(withoutEscl, [withoutEscl], [Usb, LaserWsd, Pdf], [UsbScanner, Flatbed]);

        Assert.Equal([Laser, QueueKinds.IdFor(LaserWsd.Name), PrinterList.ScannerIdFor(UsbScanner.Id)], hidden);
        Assert.Equal([QueueKinds.IdFor(Usb.Name)], PrinterList.HiddenWith(ListedPrinter.ForQueue(Usb), [], [Usb], []));
    }

    [Fact]
    public void Applying_a_change_twice_changes_nothing_more()
    {
        IReadOnlyList<ListedPrinter> listed = [Network];
        var first = PrinterList.Reconcile(Input(listed, Laser, [Usb, Tcp, LaserWsd], scanners: [UsbScanner, Flatbed]));
        var second = PrinterList.Reconcile(Input(Apply(listed, first), first.Selected, [Usb, Tcp, LaserWsd], scanners: [UsbScanner, Flatbed]));

        Assert.False(second.Changes);
        Assert.Equal(first.Selected, second.Selected);
    }
}
