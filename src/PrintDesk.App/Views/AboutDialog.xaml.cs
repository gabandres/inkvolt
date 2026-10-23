using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using PrintDesk.Windows;

namespace PrintDesk.App.Views;

/// <summary>Version, license, source code link and third-party notices (both texts are embedded resources).</summary>
public partial class AboutDialog : Window
{
    public const string SourceUrl = "https://github.com/gabandres/PrintDesk";

    private AboutDialog()
    {
        InitializeComponent();
        VersionText.Text = $"Version {AppVersion}";
        if (AppPackage.IsPackaged) PackagedNote.Visibility = Visibility.Visible;
    }

    /// <summary>The product version without build metadata ("1.2.0", not "1.2.0+commit").</summary>
    public static string AppVersion
    {
        get
        {
            var asm = typeof(AboutDialog).Assembly;
            var info = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            return info?.Split('+')[0] ?? asm.GetName().Version?.ToString() ?? "?";
        }
    }

    public static void Open(Window? owner)
    {
        var dlg = new AboutDialog { Owner = owner is { IsLoaded: true } ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }

    private void Source_Click(object sender, RoutedEventArgs e) => Shell.Open(SourceUrl);

    private void License_Click(object sender, RoutedEventArgs e) => ShowText("License", "LICENSE");

    private void Notices_Click(object sender, RoutedEventArgs e) => ShowText("Third-party notices", "THIRD-PARTY-NOTICES.md");

    private void ShowText(string title, string resource)
    {
        string text;
        try
        {
            var info = Application.GetResourceStream(new Uri($"pack://application:,,,/{resource}")) ?? throw new IOException($"{resource} is missing.");
            using var reader = new StreamReader(info.Stream);
            text = reader.ReadToEnd();
        }
        catch (IOException ex)
        {
            text = $"The text could not be loaded: {ex.Message}";
        }
        var box = new TextBox
        {
            Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Height = 420, Margin = new Thickness(16),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        };
        new Window
        {
            Title = title, Owner = this, Width = 680, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false, Icon = Icon, Content = box,
        }.ShowDialog();
    }
}
