using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.App;

/// <summary>
/// The licence key in the settings (<see cref="AppSettings.ProKey"/>), so it survives reinstalling with them; App wraps it
/// in a <see cref="SharedProStore"/>, which keeps the key where Inkvolt Print finds it too (<c>%LOCALAPPDATA%\Inkvolt\pro-key.txt</c>).
/// </summary>
internal sealed class SettingsProStore : IProStore
{
    public string? Read() => AppSettings.Current.ProKey is { Length: > 0 } key ? key : null;

    public void Write(string? key)
    {
        AppSettings.Current.ProKey = key ?? "";
        AppSettings.Current.Save();
    }
}

/// <summary>
/// Help › Inkvolt Pro…: Free or Pro (licensed to whom), a box to paste a key with its refusal in plain words, Get Inkvolt
/// Pro, Remove licence. A Pro feature that isn't unlocked opens it too (<see cref="ProGate"/>), with what the feature does
/// at the top. While <see cref="Pro.Enforced"/> is off the copy says everything is free and the purchase supports the project.
/// </summary>
internal sealed class ProWindow : Window
{
    private static ProWindow? _open;
    private readonly StackPanel _body = new();
    private readonly TextBox _key = new() { TextWrapping = TextWrapping.Wrap, AcceptsReturn = false, MinHeight = 64, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalContentAlignment = VerticalAlignment.Top };
    private readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
    private readonly ProFeature? _feature;
    private readonly Style _caption;

    public static ProWindow Open(Window owner, ProFeature? feature)
    {
        if (_open is { } existing)
        {
            existing.Activate();
            return existing;
        }
        var w = new ProWindow(owner, feature);
        _open = w;
        w.Closed += (_, _) => _open = null;
        w.Show();
        return w;
    }

    private ProWindow(Window owner, ProFeature? feature)
    {
        _feature = feature;
        Owner = owner;
        Title = "Inkvolt Pro"; // in every language: the product name
        Width = 560;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        _caption = (Style)Application.Current.FindResource("Caption");
        AutomationProperties.SetName(_key, Strings.Pro_LicenceKey);
        _error.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");

        var body = new StackPanel { Margin = new Thickness(24, 20, 24, 20) };
        body.Children.Add(new TextBlock { Text = "Inkvolt Pro", FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 12) }); // in every language: the product name
        body.Children.Add(_body);

        var close = new Button { Content = Strings.Common_Close, MinWidth = 104, IsCancel = true };
        close.Click += (_, _) => Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(24, 16, 24, 16) };
        buttons.Children.Add(close);
        var footer = new Border { Child = buttons, BorderThickness = new Thickness(0, 1, 0, 0) };
        footer.SetResourceReference(Border.BackgroundProperty, "LayerFillColorDefaultBrush");
        footer.SetResourceReference(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush");
        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(body);
        Content = root;
        Refresh();
    }

    private void Refresh()
    {
        _body.Children.Clear();
        _error.Visibility = Visibility.Collapsed;
        var licence = Pro.Licence;

        if (_feature is { } feature && Pro.Allows(feature) == false)
        {
            var banner = new Border { Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 0, 0, 14), CornerRadius = new CornerRadius(6) };
            banner.SetResourceReference(Border.BackgroundProperty, "SystemFillColorAttentionBackgroundBrush");
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = Pro.Locked(feature), FontWeight = FontWeights.SemiBold });
            text.Children.Add(new TextBlock { Text = $"{Pro.Title(feature)}: {Pro.Describe(feature)}", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) }); // in every language: only names and values, no words
            banner.Child = text;
            _body.Children.Add(banner);
        }

        if (licence is not null)
        {
            _body.Children.Add(new TextBlock { Text = Loc.Format(Strings.Pro_LicensedTo, licence.Name), FontSize = 16, FontWeight = FontWeights.SemiBold });
            _body.Children.Add(Caption(Loc.Format(licence.Covers(ProKeys.ProductPrint) ? Strings.Pro_KeyForSuite : Strings.Pro_KeyFor, licence.Email, licence.Issued)));
            if (!Pro.Enforced)
                _body.Children.Add(Caption(Strings.Pro_FreeWhileLaunchLicensed));
            var remove = new Button { Content = Strings.Pro_RemoveLicence, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0) };
            remove.Click += (_, _) =>
            {
                if (!Prompt.Confirm(this, Strings.Pro_RemoveTitle, Strings.Pro_RemoveBody, Strings.Common_Remove)) return;
                Pro.Remove();
                Refresh();
            };
            _body.Children.Add(remove);
            return;
        }

        if (Pro.Enforced)
        {
            _body.Children.Add(new TextBlock { Text = Strings.Pro_Free, FontSize = 16, FontWeight = FontWeights.SemiBold });
            _body.Children.Add(Caption(Loc.Format(Strings.Pro_Unlocks, Pro.PriceText)));
        }
        else
        {
            _body.Children.Add(new TextBlock { Text = Strings.Pro_FreeWhileLaunch, FontSize = 16, FontWeight = FontWeights.SemiBold });
            _body.Children.Add(Caption(Loc.Format(Strings.Pro_IncludesPro, Pro.PriceText)));
        }
        if (Pro.Problem is { } problem)
        {
            var text = new TextBlock { Text = problem, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
            text.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
            _body.Children.Add(text);
        }
        var get = new Button { Content = Loc.Format(Strings.Pro_Get, Pro.PriceText), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0) };
        get.SetResourceReference(StyleProperty, "AccentButtonStyle");
        get.Click += (_, _) => Shell.Open(Pro.BuyUrl);
        _body.Children.Add(get);

        _body.Children.Add(new TextBlock { Text = Strings.Pro_HaveKey, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 20, 0, 4) });
        _body.Children.Add(_key);
        _body.Children.Add(_error);
        var enter = new Button { Content = Strings.Pro_EnterKey, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0), IsDefault = true };
        enter.Click += (_, _) => Enter(_key.Text);
        _body.Children.Add(enter);
    }

    private TextBlock Caption(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Style = _caption, Margin = new Thickness(0, 4, 0, 0) };

    private void Enter(string key)
    {
        try
        {
            var licence = Pro.Install(key);
            Log.Write($"Inkvolt Pro licence entered (issued {licence.Issued:yyyy-MM-dd})");
            _error.Visibility = Visibility.Collapsed;
            _key.Clear();
            Refresh();
            FolderWatches.RaiseChanged(); // the Watched Folders window drops its locked banner
            FolderSearches.RaiseChanged(); // and so does Search Folders, whose folders start indexing
        }
        catch (ProKeyException ex)
        {
            _error.Text = ex.Message;
            _error.Visibility = Visibility.Visible;
        }
    }

    internal void DevEnter(string key) => Enter(key);

    internal void DevRemove()
    {
        Pro.Remove();
        Refresh();
    }

    internal string DevState() =>
        $"{(Pro.Licence is { } l ? $"Pro licensed to {l.Name}" : Strings.Pro_Free)}; enforced={Pro.Enforced}; feature={_feature?.ToString() ?? "-"}; error='{(_error.Visibility == Visibility.Visible ? _error.Text : "")}'; " +
        $"text='{string.Join(" | ", Texts())}'";

    private IEnumerable<string> Texts()
    {
        var found = new List<string>();
        void Walk(DependencyObject d)
        {
            if (d is TextBlock t && t.Text.Length > 2) found.Add(t.Text.Length > 60 ? t.Text[..60] + "…" : t.Text);
            if (d is Button b && b.Content is string s) found.Add($"[{s}]");
            for (var i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(d); i++) Walk(System.Windows.Media.VisualTreeHelper.GetChild(d, i));
        }
        Walk(_body);
        return found;
    }
}
