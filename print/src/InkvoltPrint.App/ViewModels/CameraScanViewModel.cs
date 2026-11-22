using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Capture;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The camera window of a camera scan (roadmap 4.12): the cameras Windows lists, the chosen one's live picture, Capture page (the latest
/// frame in full, to <see cref="CameraSession"/>) and Done. Which format and when a capture counts are Core's (<see cref="CameraFormats"/>,
/// <see cref="CameraSession"/>); this shows the frames on the dispatcher and stops the camera when the window closes.
/// </summary>
public sealed partial class CameraScanViewModel : ObservableObject
{
    private readonly ICameras _cameras;
    private readonly CameraSession _session;
    private readonly Action<string> _log;
    private ICameraFeed? _feed;
    private int _opening;

    public CameraScanViewModel(ICameras cameras, CameraSession session, Action<string> log)
    {
        _cameras = cameras;
        _session = session;
        _log = log;
        Status = session.StatusText();
    }

    public ObservableCollection<CameraInfo> Cameras { get; } = [];

    public bool HasCameraChoice => Cameras.Count > 1;

    [ObservableProperty]
    public partial CameraInfo? Camera { get; set; }

    /// <summary>The live picture (a frame at most ten times a second).</summary>
    [ObservableProperty]
    public partial WriteableBitmap? Preview { get; set; }

    /// <summary>The line under the picture: what to do, how many pages, or why the camera didn't start.</summary>
    [ObservableProperty]
    public partial string Status { get; set; }

    /// <summary>The window is to close (Done, or the scan ended elsewhere).</summary>
    public event Action? Closed;

    /// <summary>Lists the cameras and starts the first; says so when there's none.</summary>
    public async Task StartAsync()
    {
        try
        {
            foreach (var camera in await _cameras.ListAsync()) Cameras.Add(camera);
        }
        catch (Exception ex)
        {
            _log($"Camera scan: cameras not listed: {ex.Message}");
        }
        OnPropertyChanged(nameof(HasCameraChoice));
        if (Cameras.Count == 0)
        {
            Status = CoreStrings.Camera_NoCamera;
            return;
        }
        Camera = Cameras[0];
    }

    partial void OnCameraChanged(CameraInfo? value) => _ = OpenAsync(value);

    private async Task OpenAsync(CameraInfo? camera)
    {
        var turn = Interlocked.Increment(ref _opening);
        await StopAsync();
        if (camera is null || _session.IsFinished) return;
        try
        {
            var feed = await _cameras.OpenAsync(camera);
            if (turn != _opening || _session.IsFinished)
            {
                await feed.DisposeAsync(); // another camera was chosen meanwhile, or the scan ended
                return;
            }
            _feed = feed;
            feed.Frame += OnFrame;
            Status = _session.StatusText();
            _log($"Camera scan: {feed.Size.Width} × {feed.Size.Height}.");
        }
        catch (CameraException ex)
        {
            Status = ex.Message;
            _log($"Camera scan: didn't start: {ex.InnerException?.Message ?? ex.Message}");
        }
        catch (Exception ex)
        {
            Status = CoreStrings.Camera_InUse;
            _log($"Camera scan: didn't start: {ex.Message}");
        }
        CaptureCommand.NotifyCanExecuteChanged();
    }

    private void OnFrame(byte[] bgra, int width, int height) => UiThread.Run(() =>
    {
        if (_feed is null) return;
        if (Preview is not { } bmp || bmp.PixelWidth != width || bmp.PixelHeight != height)
            Preview = bmp = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgr32, null);
        bmp.WritePixels(new Int32Rect(0, 0, width, height), bgra, width * 4, 0);
        CaptureCommand.NotifyCanExecuteChanged();
    });

    private bool CanCapture() => _feed is not null && Preview is not null && _session.CanCapture;

    /// <summary>The camera's latest frame becomes the scan's next page.</summary>
    [RelayCommand(CanExecute = nameof(CanCapture))]
    private void Capture()
    {
        if (!_session.Capture(_feed)) return;
        Status = _session.StatusText();
        Prompt.Announce(Status);
        CaptureCommand.NotifyCanExecuteChanged();
    }

    [RelayCommand]
    private void Done()
    {
        _session.Finish();
        Closed?.Invoke();
    }

    /// <summary>The window closed: the scan ends (its pages kept) and the camera stops.</summary>
    public async Task CloseAsync()
    {
        _session.Finish();
        Interlocked.Increment(ref _opening);
        await StopAsync();
    }

    private async Task StopAsync()
    {
        if (_feed is not { } feed) return;
        _feed = null;
        feed.Frame -= OnFrame;
        try
        {
            await feed.DisposeAsync();
        }
        catch (Exception ex)
        {
            _log($"Camera scan: camera not stopped cleanly: {ex.Message}");
        }
    }
}
