using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Long-term validation's "what is sent, where" windows: before anything goes online the person sees every address that
/// would be asked, what it gets, and what won't be asked and why. What was done is told in the Signatures pane afterwards.
/// </summary>
internal static class LtvDialogs
{
    private const string NothingElse = "Nothing else leaves this PC, and the document itself is never sent. Addresses on this PC or a local network are never contacted, however a file names them.";

    /// <summary>Add Verification Information: the addresses, and the choice of a document timestamp. The timestamp server's address, or "" for none; null when cancelled.</summary>
    public static string? ConfirmAdd(Window owner, LtvPlan plan, LtvClient client)
    {
        var s = AppSettings.Current;
        var dlg = new FormDialog(owner, "Add Verification Information", "Contact and add", 620);
        dlg.AddNote("Stores in the file what it takes to check its signatures years from now, as an update after the signatures: they stay as they are. The file is saved as a new copy afterwards.");
        AddAddresses(dlg, plan);
        var timestamp = dlg.AddCheck("Also add a document timestamp (PAdES B-LTA)");
        var url = dlg.AddText("Timestamp server", SignDialog.ChosenTimestampUrl(s));
        url.IsEnabled = false;
        dlg.AddNote($"Sectigo's free server is suggested; you can enter another that starts with https://. It {LtvPlan.WhatIsSent(LtvAddressKind.Timestamp)}. A signature with no timestamp of its own takes two.");
        timestamp.Click += (_, _) => url.IsEnabled = timestamp.IsChecked == true;
        dlg.AddNote(NothingElse);
        dlg.Validate(() =>
        {
            if (timestamp.IsChecked != true) return null;
            if (url.Text.Trim().Length == 0) return "Enter the timestamp server's address, or untick the document timestamp.";
            return client.Why(url.Text.Trim(), LtvAddressKind.Timestamp) is { } why ? $"That timestamp server can't be used: {why}." : null;
        });
        if (!dlg.ShowModal()) return null;
        if (timestamp.IsChecked != true) return "";
        s.TimestampUrl = url.Text.Trim();
        s.Save();
        return s.TimestampUrl;
    }

    /// <summary>Signing for the long term: the addresses, once the digital ID and the timestamp server are chosen.</summary>
    public static bool ConfirmSign(Window owner, LtvPlan plan, LongTermLevel level)
    {
        var dlg = new FormDialog(owner, level == LongTermLevel.Lta ? "Sign with long-term validation (PAdES B-LTA)" : "Sign with long-term validation (PAdES B-LT)", "Contact and sign", 620);
        dlg.AddNote("To store the proof that your certificate is good when you sign, these will be asked:");
        AddAddresses(dlg, plan);
        dlg.AddNote(NothingElse);
        return dlg.ShowModal();
    }

    /// <summary>Check Signatures Online: the addresses. Leaves the file alone.</summary>
    public static bool ConfirmOnline(Window owner, LtvPlan plan)
    {
        var dlg = new FormDialog(owner, "Check signatures online", "Contact and check", 620);
        dlg.AddNote("Opening a file never goes online. To check now whether the certificates of its signatures have been revoked, these will be asked. The file stays as it is, and the answer is for this window only.");
        AddAddresses(dlg, plan);
        dlg.AddNote(NothingElse);
        return dlg.ShowModal();
    }

    private static void AddAddresses(FormDialog dlg, LtvPlan plan)
    {
        var asked = plan.Addresses.Where(a => a.RefusedBecause is null).ToList();
        var refused = plan.Addresses.Where(a => a.RefusedBecause is not null).ToList();
        if (asked.Count > 0)
        {
            dlg.Add("What will be contacted", List(asked.Select(a => $"{Host(a.Url)}, about {a.ForWhom}: {a.Url}"), "What will be contacted"));
            foreach (var kind in asked.Select(a => a.Kind).Distinct())
                dlg.AddNote(kind switch
                {
                    LtvAddressKind.Ocsp => $"An OCSP responder {LtvPlan.WhatIsSent(kind)}.",
                    LtvAddressKind.Crl => $"A CRL address {LtvPlan.WhatIsSent(kind)}.",
                    LtvAddressKind.Issuer => $"An issuer's address {LtvPlan.WhatIsSent(kind)}.",
                    _ => $"The timestamp server {LtvPlan.WhatIsSent(kind)}.",
                });
        }
        else if (refused.Count == 0)
            dlg.AddNote(plan.Complete ? "Nothing needs asking: the file already holds the data, or its certificates need none." : "The certificates name nothing to ask about them.");
        if (refused.Count > 0)
            dlg.Add("What won't be contacted", List(refused.Select(a => $"{a.RefusedBecause}: {a.Url}"), "What won't be contacted"));
        foreach (var note in plan.Notes) dlg.AddNote(note);
    }

    private static string Host(string url) => Uri.TryCreate(url, UriKind.Absolute, out var u) && u.Host.Length > 0 ? u.Host : url;

    /// <summary>A list to read with the keyboard: each address is an item a screen reader says.</summary>
    private static ListBox List(IEnumerable<string> lines, string name)
    {
        var list = new ListBox { ItemsSource = lines.ToList(), MaxHeight = 130 };
        AutomationProperties.SetName(list, name);
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Auto);
        return list;
    }

    /// <summary>The details behind what the Signatures pane says was done: each certificate, and everything that was asked.</summary>
    public static string Describe(IReadOnlyList<LtvCertificateResult> certificates, IReadOnlyList<LtvContact> contacts)
    {
        var text = new StringBuilder();
        if (certificates.Count > 0)
        {
            text.Append("Certificates:");
            foreach (var c in certificates) text.Append($"\n{c.Name}: {c.Outcome}");
            text.Append("\n\n");
        }
        if (contacts.Count > 0)
        {
            text.Append("Asked:");
            foreach (var c in contacts) text.Append($"\n{c.Url}: {c.Outcome}");
        }
        else text.Append("Nothing was asked online.");
        return text.ToString();
    }
}
