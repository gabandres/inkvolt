using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Links from Addresses (roadmap 4.15): finds the web and email addresses printed in the text that aren't links yet
/// (<see cref="AddressLinks"/>), lists them to untick, and makes the ticked ones links as one undo step.
/// </summary>
public partial class DocumentTab
{
    public async Task LinkAddresses()
    {
        if (!Session.IsPdf || !await SettleAsync()) return;
        var owner = Window.GetWindow(this);
        var engine = Session.Engine;
        var data = Session.Data;
        IReadOnlyList<FoundAddress> found;
        using (BeginBusy(null))
        using (var progress = new ProgressPrompt(owner, Strings.Links_Finding, Strings.Review_Starting))
        {
            try
            {
                found = await Task.Run(() => AddressLinks.Find(engine, PageProgress(progress, Strings.Links_Finding), progress.Token), progress.Token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
        if (_disposed || !ReferenceEquals(data, Session.Data)) return; // changed meanwhile: what was found may be elsewhere now
        if (found.Count == 0)
        {
            Prompt.Info(owner, Strings.Links_NoneTitle, Strings.Links_NoneBody);
            return;
        }

        var dlg = new FormDialog(owner, Strings.Links_Title, Strings.Links_Add, 560);
        dlg.AddNote(Loc.Plural(found.Count, Strings.Links_Found_One, Strings.Links_Found_Many)
                    + (found.Count >= AddressLinks.MaxFound ? " " + Loc.Format(Strings.Links_FoundMax, AddressLinks.MaxFound) : ""));
        var list = new StackPanel();
        var boxes = new List<CheckBox>();
        foreach (var address in found)
        {
            // The address as printed (shortened when long), its page, and where the link will lead when that reads differently.
            var shown = address.Text.Length > 80 ? address.Text[..77] + "…" : address.Text;
            var leads = address.Uri.Length > 80 ? address.Uri[..77] + "…" : address.Uri;
            var line = Loc.Format(Strings.Links_Item, PageLabel(address.Page), shown);
            var content = new StackPanel();
            content.Children.Add(new TextBlock { Text = line, TextTrimming = TextTrimming.CharacterEllipsis });
            if (!leads.Equals(shown, StringComparison.OrdinalIgnoreCase))
            {
                var to = new TextBlock { Text = Loc.Format(Strings.Links_LeadsTo, leads), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
                to.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
                content.Children.Add(to);
            }
            var box = new CheckBox { Content = content, IsChecked = true, Margin = new Thickness(0, 3, 0, 3) };
            System.Windows.Automation.AutomationProperties.SetName(box, line);
            boxes.Add(box);
            list.Children.Add(box);
        }
        dlg.Add(null, new ScrollViewer { Content = list, MaxHeight = 360, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        List<FoundAddress> chosen = [];
        dlg.Validate(() =>
        {
            chosen = [.. found.Where((_, i) => boxes[i].IsChecked == true)];
            return chosen.Count == 0 ? Strings.Links_NoneTicked : null;
        });
        if (!dlg.ShowModal() || _disposed || !await SettleAsync() || !ReferenceEquals(data, Session.Data)) return;

        await RunEdit(Loc.Plural(chosen.Count, Strings.Links_Edit_One, Strings.Links_Edit_Many), (d, pw) => AddressLinks.Apply(d, pw, chosen));
    }
}
