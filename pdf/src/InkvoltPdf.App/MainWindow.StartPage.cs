using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using Microsoft.Win32;

namespace InkvoltPdf.App;

/// <summary>A card in the start page's Tools grid (its content; the button's Tag is the command it runs).</summary>
public sealed class StartTool
{
    public string Title { get; set; } = "";
    public string Detail { get; set; } = "";
    public string Glyph { get; set; } = "";
}

/// <summary>The start page's Tools grid: tools that need a document ask for a PDF, open it, then run.</summary>
public partial class MainWindow
{
    private async void OnToolCard(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: RoutedCommand command, Content: StartTool tool }) return;
        if (command.CanExecute(null, this))
        {
            command.Execute(null, this);
            return;
        }
        var dlg = new OpenFileDialog
        {
            Title = $"Choose a PDF: {tool.Title}",
            Filter = "PDF files (*.pdf)|*.pdf",
            InitialDirectory = AppSettings.Current.LastFolder,
        };
        if (dlg.ShowDialog(this) != true) return;
        await RunOnFileAsync(dlg.FileName, command, tool.Title);
    }

    /// <summary>Opens <paramref name="path"/> (or switches to it) and runs <paramref name="command"/> on it once it's ready.</summary>
    internal async Task RunOnFileAsync(string path, RoutedCommand command, string name)
    {
        await OpenFileAsync(path);
        var full = Path.GetFullPath(path);
        // Not opened (cancelled password, unreadable file): OpenFileAsync has said why.
        if (ActiveTab is not { } tab || !string.Equals(tab.Session.FilePath, full, StringComparison.OrdinalIgnoreCase)) return;
        // The tab may still be reading its pages; give it a few seconds.
        for (var i = 0; i < 60 && !command.CanExecute(null, this); i++)
        {
            await Task.Delay(50);
            if (ActiveTab != tab) return;
        }
        if (command.CanExecute(null, this)) command.Execute(null, this);
        else ShowToast(new Toast($"{name} isn't available for {Path.GetFileName(full)}.", IsError: true));
    }

    private void OnCreateCard(object sender, RoutedEventArgs e)
    {
        if (CreateCard.ContextMenu is not { } menu) return;
        menu.PlacementTarget = CreateCard;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
    }
}
