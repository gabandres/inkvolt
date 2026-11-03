using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App.Views;

/// <summary>
/// The licence key's copy in state.json (<see cref="AppState.ProKey"/>); App wraps it in a <see cref="SharedProStore"/>, which
/// keeps the key where Inkvolt PDF finds it too (<c>%LOCALAPPDATA%\Inkvolt\pro-key.txt</c>).
/// </summary>
internal sealed class StateProStore(AppState state) : IProStore
{
    public string? Read() => state.ProKey is { Length: > 0 } key ? key : null;

    public void Write(string? key)
    {
        state.ProKey = key ?? "";
        state.Save();
    }
}

/// <summary>
/// Help › Inkvolt Pro…: Free or Pro (licensed to whom), a box to paste a key with its refusal in plain words, Get Inkvolt
/// Pro, Remove licence; the same window as Inkvolt PDF's. A Pro feature that isn't unlocked will open it too, with what
/// the feature does at the top. While <see cref="Pro.Enforced"/> is off the copy says everything is free and the purchase
/// supports the project.
/// </summary>
public sealed class ProWindow : Window
{
    private static ProWindow? _open;
    private readonly StackPanel _body = new();
    private readonly TextBox _key = new() { TextWrapping = TextWrapping.Wrap, AcceptsReturn = false, MinHeight = 64, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalContentAlignment = VerticalAlignment.Top };
    private readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
    private readonly ProFeature? _feature;
    private readonly Style _caption;

    public static ProWindow Open(Window? owner, ProFeature? feature = null)
    {
        if (_open is { } existing)
        {
            existing.Activate();
            return existing;
        }
        var w = Create(owner, feature);
        _open = w;
        w.Closed += (_, _) => _open = null;
        w.Show();
        return w;
    }

    /// <summary>The window not yet shown (the snapshot aid's <c>--dialog pro</c>).</summary>
    public static ProWindow Create(Window? owner, ProFeature? feature = null) => new(owner, feature);

    private ProWindow(Window? owner, ProFeature? feature)
    {
        _feature = feature;
        Owner = owner is { IsLoaded: true } ? owner : null;
        Title = "Inkvolt Pro";
        Icon = Application.Current.MainWindow?.Icon;
        Width = 560;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = Owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        _caption = (Style)Application.Current.FindResource("Caption");
        AutomationProperties.SetName(_key, Strings.Pro_LicenceKey);
        _error.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");

        var body = new StackPanel { Margin = new Thickness(24, 20, 24, 20) };
        body.Children.Add(new TextBlock { Text = "Inkvolt Pro", FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 12) });
        body.Children.Add(_body);
        var close = new Button { Content = Strings.Common_Close, MinWidth = 96, IsCancel = true, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        close.SetResourceReference(StyleProperty, "AccentButtonStyle");
        close.Click += (_, _) => Close();
        body.Children.Add(close);
        Content = body;
        Refresh();
    }

    private void Refresh()
    {
        _body.Children.Clear();
        _error.Visibility = Visibility.Collapsed;
        var licence = Pro.Licence;

        if (_feature is { } feature && !Pro.Allows(feature))
        {
            var banner = new Border { Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 0, 0, 14), CornerRadius = new CornerRadius(6) };
            banner.SetResourceReference(Border.BackgroundProperty, "SystemFillColorAttentionBackgroundBrush");
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = Pro.Locked(feature), FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            text.Children.Add(new TextBlock { Text = $"{Pro.Title(feature)}: {Pro.Describe(feature)}", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
            banner.Child = text;
            _body.Children.Add(banner);
        }

        if (licence is not null)
        {
            _body.Children.Add(new TextBlock { Text = string.Format(Strings.Pro_LicensedTo, licence.Name), FontSize = 16, FontWeight = FontWeights.SemiBold });
            _body.Children.Add(Caption(string.Format(licence.Covers(ProKeys.ProductPdf) ? Strings.Pro_KeyForWithPdf : Strings.Pro_KeyFor, licence.Email, licence.Issued)));
            if (!Pro.Enforced)
                _body.Children.Add(Caption(Strings.Pro_FreeWhileLaunchingLicensed));
            var remove = new Button { Content = Strings.Pro_RemoveLicence, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0) };
            remove.Click += (_, _) =>
            {
                if (!ConfirmDialog.Ask(this, Strings.Pro_RemoveQuestion, Strings.Common_Remove)) return;
                Pro.Remove();
                Log.Write("Inkvolt Pro licence removed");
                Refresh();
            };
            _body.Children.Add(remove);
            return;
        }

        if (Pro.Enforced)
        {
            _body.Children.Add(new TextBlock { Text = Strings.Pro_Free, FontSize = 16, FontWeight = FontWeights.SemiBold });
            _body.Children.Add(Caption(string.Format(Strings.Pro_Unlocks, Pro.PriceText)));
        }
        else
        {
            _body.Children.Add(new TextBlock { Text = Strings.Pro_FreeWhileLaunching, FontSize = 16, FontWeight = FontWeights.SemiBold });
            _body.Children.Add(Caption(string.Format(Strings.Pro_FreeWhileLaunchingNote, Pro.PriceText)));
        }
        if (Pro.Problem is { } problem)
        {
            var text = new TextBlock { Text = problem, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
            text.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
            _body.Children.Add(text);
        }
        var get = new Button { Content = string.Format(Strings.Pro_Get, Pro.PriceText), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0) };
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
        }
        catch (ProKeyException ex)
        {
            _error.Text = ex.Message;
            _error.Visibility = Visibility.Visible;
        }
    }

    /// <summary>The snapshot aid (<c>--dialog pro --pro-key KEY</c>): as if the key were pasted and entered.</summary>
    internal void DevEnter(string key) => Enter(key);
}
