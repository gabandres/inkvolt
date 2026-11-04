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
    private static string NothingElse => Strings.Ltv_NothingElse;

    /// <summary>Add Verification Information: the addresses, and the choice of a document timestamp. The timestamp server's address, or "" for none; null when cancelled.</summary>
    public static string? ConfirmAdd(Window owner, LtvPlan plan, LtvClient client)
    {
        var s = AppSettings.Current;
        var dlg = new FormDialog(owner, Strings.Ltv_AddTitle, Strings.Ltv_ContactAndAdd, 620);
        dlg.AddNote(Strings.Ltv_AddNote);
        AddAddresses(dlg, plan);
        var timestamp = dlg.AddCheck(Strings.Ltv_AlsoTimestamp);
        var url = dlg.AddText(Strings.Ltv_TimestampServer, SignDialog.ChosenTimestampUrl(s));
        url.IsEnabled = false;
        dlg.AddNote(Loc.Format(Strings.Ltv_SectigoNote, LtvPlan.WhatIsSent(LtvAddressKind.Timestamp)));
        timestamp.Click += (_, _) => url.IsEnabled = timestamp.IsChecked == true;
        dlg.AddNote(NothingElse);
        dlg.Validate(() =>
        {
            if (timestamp.IsChecked != true) return null;
            if (url.Text.Trim().Length == 0) return Strings.Ltv_EnterServer;
            return client.Why(url.Text.Trim(), LtvAddressKind.Timestamp) is { } why ? Loc.Format(Strings.Ltv_ServerRefused, why) : null;
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
        var dlg = new FormDialog(owner, level == LongTermLevel.Lta ? Strings.Ltv_SignLta : Strings.Ltv_SignLt, Strings.Ltv_ContactAndSign, 620);
        dlg.AddNote(Strings.Ltv_SignNote);
        AddAddresses(dlg, plan);
        dlg.AddNote(NothingElse);
        return dlg.ShowModal();
    }

    /// <summary>Check Signatures Online: the addresses. Leaves the file alone.</summary>
    public static bool ConfirmOnline(Window owner, LtvPlan plan)
    {
        var dlg = new FormDialog(owner, Strings.Ltv_CheckOnline, Strings.Ltv_ContactAndCheck, 620);
        dlg.AddNote(Strings.Ltv_CheckNote);
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
            dlg.Add(Strings.Ltv_WillContact, List(asked.Select(a => Loc.Format(Strings.Ltv_AddressLine, Host(a.Url), a.ForWhom, a.Url)), Strings.Ltv_WillContact));
            foreach (var kind in asked.Select(a => a.Kind).Distinct())
                dlg.AddNote(kind switch
                {
                    LtvAddressKind.Ocsp => Loc.Format(Strings.Ltv_OcspSends, LtvPlan.WhatIsSent(kind)),
                    LtvAddressKind.Crl => Loc.Format(Strings.Ltv_CrlSends, LtvPlan.WhatIsSent(kind)),
                    LtvAddressKind.Issuer => Loc.Format(Strings.Ltv_IssuerSends, LtvPlan.WhatIsSent(kind)),
                    _ => Loc.Format(Strings.Ltv_TimestampSends, LtvPlan.WhatIsSent(kind)),
                });
        }
        else if (refused.Count == 0)
            dlg.AddNote(plan.Complete ? Strings.Ltv_NothingNeeded : Strings.Ltv_NothingNamed);
        if (refused.Count > 0)
            dlg.Add(Strings.Ltv_WontContact, List(refused.Select(a => $"{a.RefusedBecause}: {a.Url}"), Strings.Ltv_WontContact));
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
            text.Append(Strings.Ltv_Certificates);
            foreach (var c in certificates) text.Append($"\n{c.Name}: {c.Outcome}");
            text.Append("\n\n");
        }
        if (contacts.Count > 0)
        {
            text.Append(Strings.Ltv_Asked);
            foreach (var c in contacts) text.Append($"\n{c.Url}: {c.Outcome}");
        }
        else text.Append(Strings.Ltv_NothingAsked);
        return text.ToString();
    }
}
