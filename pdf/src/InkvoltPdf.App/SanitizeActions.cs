using System.Text;
using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Review › Sanitize Document: finds metadata, hidden data, active content and attachments (counted in the dialog, each
/// kind a check box), removes the chosen ones as one undoable edit (a full rewrite), then says what went.
/// </summary>
public static class SanitizeActions
{
    internal static readonly (SanitizeItem Item, string Label, string? Group)[] Kinds =
    [
        (SanitizeItem.Metadata, "Document properties (title, author, keywords…), comment authors and dates, other apps' private data", "Metadata"),
        (SanitizeItem.HiddenLayers, "Hidden layers, with what they draw", "Hidden data"),
        (SanitizeItem.HiddenAnnotations, "Hidden comments and form fields", null),
        (SanitizeItem.Comments, "Comments, markup, stamps and drawings", null),
        (SanitizeItem.FormValues, "Form field values (the fields stay, empty)", null),
        (SanitizeItem.Bookmarks, "Bookmarks", null),
        (SanitizeItem.Thumbnails, "Embedded page thumbnails", null),
        (SanitizeItem.ActiveContent, "JavaScript, actions that run programs or send data, multimedia", "Active content"),
        (SanitizeItem.ExternalLinks, "Links to web pages and other files", null),
        (SanitizeItem.EmbeddedFiles, "Attached files", "Attachments"),
        (SanitizeItem.Signatures, "Digital signatures (the signature fields stay, empty)", "Signatures"),
    ];

    public static async Task Sanitize(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        SanitizeReport found;
        host.ShowStatus("Looking for hidden data…");
        try
        {
            found = await Task.Run(() => Sanitizer.Scan(data, password));
        }
        catch (Exception ex) when (ex is InvalidOperationException or OwnerPasswordRequiredException)
        {
            Log.Write($"Sanitize scan failed: {ex}");
            Prompt.Error(host, "This document can't be sanitized", ex.Message);
            return;
        }
        if (tab.IsDisposed || !ReferenceEquals(data, tab.Session.Data)) return; // changed or closed meanwhile

        if (Ask(host, found, tab) is not { } items || !await tab.SettleAsync()) return;
        SanitizeResult? result = null;
        var signed = found[SanitizeItem.Signatures] > 0;
        var outcome = await tab.TryEdit("Sanitize document", (d, pw) =>
        {
            // The dialog said that a signed file's signatures stop verifying: no second warning.
            var (bytes, _) = SignedEdits.Run(() =>
            {
                var r = Sanitizer.Sanitize(d, pw, items);
                result = r;
                return r.Data;
            }, allowRewrite: true);
            return bytes;
        }, signaturesWarned: signed);
        if (outcome != EditOutcome.Done || result is null) return;
        Prompt.Info(host, "Document sanitized", Describe(result));
    }

    /// <summary>The dialog: one check box per kind found (with its count). Null when cancelled.</summary>
    private static HashSet<SanitizeItem>? Ask(Window owner, SanitizeReport found, DocumentTab tab)
    {
        var dlg = new FormDialog(owner, "Sanitize Document", "Sanitize", 540);
        dlg.AddFooterButton("See What's in It…").Click += (_, _) => _ = InventoryActions.Show(dlg, tab, null);
        var rewrite = new List<string>();
        if (found.EarlierRevisions > 0) rewrite.Add(Count(found.EarlierRevisions, "earlier version", "earlier versions") + " kept by incremental saves");
        if (found.UnusedObjects > 0) rewrite.Add(Count(found.UnusedObjects, "leftover piece", "leftover pieces") + " of earlier edits");
        dlg.AddNote("Removes what the document carries besides its pages. The file is saved afresh, so nothing of its earlier versions stays in it" +
                    (rewrite.Count > 0 ? $" ({string.Join(" and ", rewrite)})" : "") +
                    ". You can undo this until you save.");
        if (found[SanitizeItem.Signatures] > 0)
            dlg.AddNote("This document is digitally signed. Sanitizing rewrites it, so its signatures will no longer verify. Removing them takes " +
                        "the signers' names and certificates out too; kept, they show as invalid. To keep the signed original, save the result as a copy (Save As).");

        var checks = new List<(SanitizeItem Item, CheckBox Box)>();
        foreach (var (item, label, group) in Kinds)
        {
            var n = found[item];
            if (item == SanitizeItem.Signatures && n == 0) continue; // not signed: nothing to say
            var box = new CheckBox
            {
                Content = new TextBlock { Text = n > 0 ? $"{label} ({n})" : $"{label} (none found)", TextWrapping = TextWrapping.Wrap },
                IsChecked = n > 0,
                IsEnabled = n > 0,
            };
            System.Windows.Automation.AutomationProperties.SetName(box, n > 0 ? $"{label}: {n} found" : $"{label}: none found");
            dlg.Add(group, box, top: 14);
            checks.Add((item, box));
        }
        foreach (var note in found.Notes) dlg.AddNote(note);
        dlg.AddNote("Text drawn in white or outside the page isn't removed here (it can't be told reliably from text that shows): " +
                    "See What's in It lists it, and redacting its area removes it.");
        dlg.Validate(() => checks.Any(c => c.Box.IsChecked == true) || found.EarlierRevisions > 0 || found.UnusedObjects > 0
            ? null
            : "Nothing to remove: this document holds none of these.");
        if (!dlg.ShowModal()) return null;
        return [.. checks.Where(c => c.Box.IsChecked == true).Select(c => c.Item)];
    }

    /// <summary>What went (and anything that couldn't).</summary>
    internal static string Describe(SanitizeResult result)
    {
        var removed = result.Removed;
        var sb = new StringBuilder();
        var lines = Kinds.Where(k => removed[k.Item] > 0).Select(k => $"• {Short(k.Item, removed[k.Item])}").ToList();
        if (removed.EarlierRevisions > 0) lines.Add($"• {Count(removed.EarlierRevisions, "earlier version", "earlier versions")} of the file");
        if (removed.UnusedObjects > 0) lines.Add($"• {Count(removed.UnusedObjects, "leftover piece", "leftover pieces")} of earlier edits");
        sb.Append(lines.Count > 0 ? "Removed:\n" + string.Join("\n", lines) : "The file was saved afresh, without its earlier versions; there was nothing else to remove.");

        var left = result.Remaining;
        var stillThere = left is null ? [] : Kinds.Where(k => removed[k.Item] > 0 && left[k.Item] > 0).Select(k => Short(k.Item, left[k.Item])).ToList();
        if (stillThere.Count > 0) sb.Append("\n\nStill in the file: ").Append(string.Join("; ", stillThere)).Append('.');
        foreach (var note in removed.Notes) sb.Append("\n\n").Append(note);
        sb.Append("\n\nSave to keep it (Save As keeps the original as it was).");
        return sb.ToString();
    }

    private static string Short(SanitizeItem item, int n) => item switch
    {
        SanitizeItem.Metadata => Count(n, "metadata entry", "metadata entries"),
        SanitizeItem.HiddenLayers => n == 1 ? "1 hidden layer with its content" : $"{n} hidden layers with their content",
        SanitizeItem.HiddenAnnotations => Count(n, "hidden comment or field", "hidden comments and fields"),
        SanitizeItem.Comments => Count(n, "comment", "comments"),
        SanitizeItem.FormValues => Count(n, "field value", "field values"),
        SanitizeItem.Bookmarks => Count(n, "bookmark", "bookmarks"),
        SanitizeItem.Thumbnails => Count(n, "page thumbnail", "page thumbnails"),
        SanitizeItem.ActiveContent => Count(n, "script or active item", "scripts and active items"),
        SanitizeItem.ExternalLinks => Count(n, "external link", "external links"),
        SanitizeItem.EmbeddedFiles => Count(n, "attached file", "attached files"),
        SanitizeItem.Signatures => Count(n, "digital signature", "digital signatures"),
        _ => n.ToString(),
    };

    private static string Count(int n, string one, string many) => n == 1 ? $"1 {one}" : $"{n} {many}";
}
