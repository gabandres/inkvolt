using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>The camera scan's window (roadmap 4.12): shows <see cref="CameraScanViewModel"/>; closing it ends the scan and stops the camera.</summary>
public partial class CameraWindow : Window
{
    private readonly CameraScanViewModel _vm;

    private CameraWindow(CameraScanViewModel vm)
    {
        InitializeComponent();
        _vm = vm;
        DataContext = vm;
        vm.Closed += Close;
        Loaded += async (_, _) => await vm.StartAsync();
    }

    /// <summary>The window opened last (the developer snapshot's <c>--camera</c> renders it).</summary>
    internal static CameraWindow? Last { get; private set; }

    /// <summary>Opens the window beside <paramref name="owner"/>, not modal (the review fills in behind it); returns what closes it.</summary>
    public static Action Open(Window? owner, CameraScanViewModel vm)
    {
        var window = new CameraWindow(vm) { Owner = owner is { IsLoaded: true, IsVisible: true } ? owner : null };
        if (window.Owner is null) window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        window.Show();
        Last = window;
        return () =>
        {
            if (window.IsLoaded) window.Close();
        };
    }

    /// <summary>
    /// Space captures a page wherever the focus is (not pressing a focused Done, nor opening the camera list), once per press: a key held
    /// down repeats nothing.
    /// </summary>
    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Space) return;
        e.Handled = true;
        if (!e.IsRepeat && _vm.CaptureCommand.CanExecute(null)) _vm.CaptureCommand.Execute(null);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        _vm.Closed -= Close;
        _ = _vm.CloseAsync();
        base.OnClosing(e);
    }
}
