using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;

namespace PrintDesk.App;

/// <summary>
/// One PrintDesk per user session. A second launch (e.g. "Open with PrintDesk" while it's already open) hands its
/// arguments to the running copy over a named pipe that only this user can open, then exits.
/// </summary>
public sealed class SingleInstance : IDisposable
{
    private static readonly string Id = $"PrintDesk-{WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName}";
    private readonly Mutex _mutex;
    private readonly CancellationTokenSource _cts = new();

    private SingleInstance(Mutex mutex) => _mutex = mutex;

    /// <summary>Returns the owner instance, or null after forwarding <paramref name="args"/> to the running one.</summary>
    public static SingleInstance? TryAcquire(string[] args)
    {
        var mutex = new Mutex(initiallyOwned: true, $@"Local\{Id}", out var created);
        if (created) return new SingleInstance(mutex);
        mutex.Dispose();
        Forward(args);
        return null;
    }

    /// <summary>Calls <paramref name="onArgs"/> (on a background thread) whenever another launch forwards its arguments.</summary>
    public void Listen(Action<string[]> onArgs)
    {
        _ = Task.Run(async () =>
        {
            while (!_cts.IsCancellationRequested)
            {
                try
                {
                    await using var server = new NamedPipeServerStream(Id, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await server.WaitForConnectionAsync(_cts.Token);
                    using var reader = new StreamReader(server, Encoding.UTF8);
                    var text = await reader.ReadToEndAsync(_cts.Token);
                    onArgs(text.Split('\n', StringSplitOptions.RemoveEmptyEntries));
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    Log.Write($"Single-instance pipe: {ex.Message}");
                    await Task.Delay(500);
                }
            }
        });
    }

    private static void Forward(string[] args)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", Id, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            client.Connect(3000);
            var bytes = Encoding.UTF8.GetBytes(string.Join('\n', args.Select(a => File.Exists(a) ? Path.GetFullPath(a) : a)));
            client.Write(bytes);
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or UnauthorizedAccessException)
        {
            Log.Write($"Could not reach the running PrintDesk: {ex.Message}");
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _mutex.ReleaseMutex(); } catch (ApplicationException) { }
        _mutex.Dispose();
    }
}
