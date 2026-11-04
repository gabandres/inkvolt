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
    internal static (SanitizeItem Item, string Label, string? Group)[] Kinds =>
    [
        (SanitizeItem.Metadata, Strings.Sanitize_KindMetadata, Strings.Sanitize_GroupMetadata),
        (SanitizeItem.HiddenLayers, Strings.Sanitize_KindHiddenLayers, Strings.Sanitize_GroupHidden),
        (SanitizeItem.HiddenAnnotations, Strings.Sanitize_KindHiddenAnnotations, null),
        (SanitizeItem.Comments, Strings.Sanitize_KindComments, null),
        (SanitizeItem.FormValues, Strings.Sanitize_KindFormValues, null),
        (SanitizeItem.Bookmarks, Strings.Sanitize_KindBookmarks, null),
        (SanitizeItem.Thumbnails, Strings.Sanitize_KindThumbnails, null),
        (SanitizeItem.ActiveContent, Strings.Sanitize_KindActive, Strings.Sanitize_GroupActive),
        (SanitizeItem.ExternalLinks, Strings.Sanitize_KindLinks, null),
        (SanitizeItem.EmbeddedFiles, Strings.Sanitize_KindAttached, Strings.Sanitize_GroupAttachments),
        (SanitizeItem.Signatures, Strings.Sanitize_KindSignatures, Strings.Sanitize_GroupSignatures),
    ];

    public static async Task Sanitize(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        SanitizeReport found;
        host.ShowStatus(Strings.Sanitize_Looking);
        try
        {
            found = await Task.Run(() => Sanitizer.Scan(data, password));
        }
        catch (Exception ex) when (ex is InvalidOperationException or OwnerPasswordRequiredException)
        {
            Log.Write($"Sanitize scan failed: {ex}");
            Prompt.Error(host, Strings.Sanitize_Cant, ex.Message);
            return;
        }
        if (tab.IsDisposed || !ReferenceEquals(data, tab.Session.Data)) return; // changed or closed meanwhile

        if (Ask(host, found, tab) is not { } items || !await tab.SettleAsync()) return;
        SanitizeResult? result = null;
        var signed = found[SanitizeItem.Signatures] > 0;
        var outcome = await tab.TryEdit(Strings.Sanitize_EditLabel, (d, pw) =>
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
        Prompt.Info(host, Strings.Sanitize_Done, Describe(result));
    }

    /// <summary>The dialog: one check box per kind found (with its count). Null when cancelled.</summary>
    private static HashSet<SanitizeItem>? Ask(Window owner, SanitizeReport found, DocumentTab tab)
    {
        var dlg = new FormDialog(owner, Strings.Sanitize_Title, Strings.Sanitize_Sanitize, 540);
        dlg.AddFooterButton(Strings.Sanitize_SeeWhatsIn).Click += (_, _) => _ = InventoryActions.Show(dlg, tab, null);
        var rewrite = new List<string>();
        if (found.EarlierRevisions > 0) rewrite.Add(Loc.Plural(found.EarlierRevisions, Strings.Sanitize_EarlierKept_One, Strings.Sanitize_EarlierKept_Many));
        if (found.UnusedObjects > 0) rewrite.Add(Loc.Plural(found.UnusedObjects, Strings.Sanitize_Leftover_One, Strings.Sanitize_Leftover_Many));
        dlg.AddNote(rewrite.Count > 0 ? Loc.Format(Strings.Sanitize_NoteParen, string.Join(Strings.Viewer_ListAnd, rewrite)) : Strings.Sanitize_Note);
        if (found[SanitizeItem.Signatures] > 0)
            dlg.AddNote(Strings.Sanitize_SignedNote);

        var checks = new List<(SanitizeItem Item, CheckBox Box)>();
        foreach (var (item, label, group) in Kinds)
        {
            var n = found[item];
            if (item == SanitizeItem.Signatures && n == 0) continue; // not signed: nothing to say
            var box = new CheckBox
            {
                Content = new TextBlock { Text = n > 0 ? $"{label} ({n})" : Loc.Format(Strings.Sanitize_NoneFound, label), TextWrapping = TextWrapping.Wrap },
                IsChecked = n > 0,
                IsEnabled = n > 0,
            };
            System.Windows.Automation.AutomationProperties.SetName(box, n > 0 ? Loc.Format(Strings.Sanitize_FoundSpoken, label, n) : Loc.Format(Strings.Sanitize_NoneFoundSpoken, label));
            dlg.Add(group, box, top: 14);
            checks.Add((item, box));
        }
        foreach (var note in found.Notes) dlg.AddNote(note);
        dlg.AddNote(Strings.Sanitize_WhiteTextNote);
        dlg.Validate(() => checks.Any(c => c.Box.IsChecked == true) || found.EarlierRevisions > 0 || found.UnusedObjects > 0
            ? null
            : Strings.Sanitize_NothingToRemove);
        if (!dlg.ShowModal()) return null;
        return [.. checks.Where(c => c.Box.IsChecked == true).Select(c => c.Item)];
    }

    /// <summary>What went (and anything that couldn't).</summary>
    internal static string Describe(SanitizeResult result)
    {
        var removed = result.Removed;
        var sb = new StringBuilder();
        var lines = Kinds.Where(k => removed[k.Item] > 0).Select(k => $"• {Short(k.Item, removed[k.Item])}").ToList();
        if (removed.EarlierRevisions > 0) lines.Add("• " + Loc.Plural(removed.EarlierRevisions, Strings.Sanitize_EarlierOfFile_One, Strings.Sanitize_EarlierOfFile_Many));
        if (removed.UnusedObjects > 0) lines.Add("• " + Loc.Plural(removed.UnusedObjects, Strings.Sanitize_Leftover_One, Strings.Sanitize_Leftover_Many));
        sb.Append(lines.Count > 0 ? Strings.Sanitize_Removed + "\n" + string.Join("\n", lines) : Strings.Sanitize_SavedAfresh);

        var left = result.Remaining;
        var stillThere = left is null ? [] : Kinds.Where(k => removed[k.Item] > 0 && left[k.Item] > 0).Select(k => Short(k.Item, left[k.Item])).ToList();
        if (stillThere.Count > 0) sb.Append("\n\n").Append(Loc.Format(Strings.Sanitize_StillThere, string.Join("; ", stillThere)));
        foreach (var note in removed.Notes) sb.Append("\n\n").Append(note);
        sb.Append("\n\n").Append(Strings.Sanitize_SaveToKeep);
        return sb.ToString();
    }

    private static string Short(SanitizeItem item, int n) => item switch
    {
        SanitizeItem.Metadata => Loc.Plural(n, Strings.Sanitize_Metadata_One, Strings.Sanitize_Metadata_Many),
        SanitizeItem.HiddenLayers => Loc.Plural(n, Strings.Sanitize_Layers_One, Strings.Sanitize_Layers_Many),
        SanitizeItem.HiddenAnnotations => Loc.Plural(n, Strings.Sanitize_HiddenAnnots_One, Strings.Sanitize_HiddenAnnots_Many),
        SanitizeItem.Comments => Loc.Plural(n, Strings.Sanitize_Comments_One, Strings.Sanitize_Comments_Many),
        SanitizeItem.FormValues => Loc.Plural(n, Strings.Sanitize_Values_One, Strings.Sanitize_Values_Many),
        SanitizeItem.Bookmarks => Loc.Plural(n, Strings.Sanitize_Bookmarks_One, Strings.Sanitize_Bookmarks_Many),
        SanitizeItem.Thumbnails => Loc.Plural(n, Strings.Sanitize_Thumbs_One, Strings.Sanitize_Thumbs_Many),
        SanitizeItem.ActiveContent => Loc.Plural(n, Strings.Sanitize_Active_One, Strings.Sanitize_Active_Many),
        SanitizeItem.ExternalLinks => Loc.Plural(n, Strings.Sanitize_Links_One, Strings.Sanitize_Links_Many),
        SanitizeItem.EmbeddedFiles => Loc.Plural(n, Strings.Sanitize_Files_One, Strings.Sanitize_Files_Many),
        SanitizeItem.Signatures => Loc.Plural(n, Strings.Sanitize_Signatures_One, Strings.Sanitize_Signatures_Many),
        _ => n.ToString(),
    };
}
