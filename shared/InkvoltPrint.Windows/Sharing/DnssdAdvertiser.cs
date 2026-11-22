using System.Net.Sockets;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Sharing;

namespace InkvoltPrint.Windows.Sharing;

/// <summary>
/// Announces a shared scanner (<c>_uscans._tcp</c>) or printer (<c>_ipp._tcp</c>, roadmap 4.10) over DNS-SD (Bonjour, multicast DNS) with
/// Windows' own responder: <c>DnsServiceRegister</c> (windns.h,
/// dnsapi.dll, Windows 10 1809 and later; no package, no administrator rights). One registration per private interface, with that
/// interface's IPv4 address, so nothing is announced on a public network. Disposing takes every registration back
/// (<c>DnsServiceDeRegister</c>), waiting up to two seconds for Windows to confirm each.
/// </summary>
public sealed class DnssdAdvertiser : IShareAdvertiser
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(5);

    /// <summary>Answers the subtypes Windows' API can't register (AirPrint's <c>_universal</c>), on the same networks, while the advert lasts.</summary>
    private readonly MdnsSubtypeResponder _subtypes = new();

    public async Task<IAsyncDisposable> AdvertiseAsync(ShareAdvert advert, IReadOnlyList<LocalNetwork> on, CancellationToken ct)
    {
        // Every interface at once: one that's slow to confirm doesn't hold up the others, or the app's exit (which cancels ct).
        var starts = on.Where(n => n.Address.AddressFamily == AddressFamily.InterNetwork).GroupBy(n => n.InterfaceIndex).Select(g => g.First())
            .Select(network => Registration.StartAsync(advert, network, ct)).ToList();
        try
        {
            await Task.WhenAll(starts).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Looked at one by one below.
        }
        var done = starts.Where(t => t.IsCompletedSuccessfully).Select(t => t.Result).ToList();
        if (ct.IsCancellationRequested)
        {
            await new Registrations(done, null).DisposeAsync().ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
        }
        if (done.Count == 0)
            throw starts.FirstOrDefault(t => t.IsFaulted)?.Exception?.InnerException
                ?? new InvalidOperationException("No private network with an IPv4 address to announce on.");
        var subtypes = advert.Subtypes.Count > 0 ? _subtypes.Add(advert, on) : null;
        return new Registrations(done, subtypes);
    }

    /// <summary>Taken back together, so the whole takes at most one registration's wait (two seconds).</summary>
    private sealed class Registrations(List<Registration> all, IDisposable? subtypes) : IAsyncDisposable
    {
        public async ValueTask DisposeAsync()
        {
            subtypes?.Dispose(); // the subtype's goodbye first, then Windows' own
            await Task.WhenAll(all.Select(r => r.StopAsync())).ConfigureAwait(false);
        }
    }

    /// <summary>One service registered on one interface; its native request and instance live until Windows confirms it's taken back.</summary>
    private sealed class Registration
    {
        private const uint RequestPending = 9506; // DNS_REQUEST_PENDING
        private static readonly RegisterComplete Callback = OnComplete;
        private static readonly IntPtr CallbackPointer = Marshal.GetFunctionPointerForDelegate(Callback);

        private IntPtr _request, _instance;
        private GCHandle _self;
        // Windows calls back once when the registration is done and once when it's taken back: memory is freed after both.
        private readonly TaskCompletionSource<uint> _registered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _deregistered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _callbacks, _stopped, _freed;

        public static async Task<Registration> StartAsync(ShareAdvert advert, LocalNetwork network, CancellationToken ct)
        {
            var r = new Registration();
            var ip4 = BitConverter.ToUInt32(network.Address.GetAddressBytes()); // IP4_ADDRESS: the bytes in network order
            var keys = advert.Txt.Select(kv => kv.Key).ToArray();
            var values = advert.Txt.Select(kv => kv.Value).ToArray();
            r._instance = DnsServiceConstructInstance($"{advert.Instance}.{advert.Kind}.local", advert.Host, ref ip4, IntPtr.Zero,
                (ushort)advert.Port, 0, 0, (uint)keys.Length, keys, values);
            if (r._instance == IntPtr.Zero) throw new InvalidOperationException("DnsServiceConstructInstance failed.");
            r._self = GCHandle.Alloc(r);
            r._request = Marshal.AllocHGlobal(Marshal.SizeOf<RegisterRequest>());
            Marshal.StructureToPtr(new RegisterRequest
            {
                Version = 1, // DNS_QUERY_REQUEST_VERSION1
                InterfaceIndex = (uint)network.InterfaceIndex,
                ServiceInstance = r._instance,
                Callback = CallbackPointer,
                Context = GCHandle.ToIntPtr(r._self),
            }, r._request, false);
            var status = DnsServiceRegister(r._request, IntPtr.Zero);
            if (status != RequestPending)
            {
                r.Free();
                throw new InvalidOperationException($"DnsServiceRegister returned {status}.");
            }
            uint result;
            try
            {
                result = await r._registered.Task.WaitAsync(Wait, ct).ConfigureAwait(false);
            }
            catch
            {
                await r.StopAsync().ConfigureAwait(false);
                throw;
            }
            if (result != 0)
            {
                await r.StopAsync().ConfigureAwait(false);
                throw new InvalidOperationException($"DNS-SD registration failed ({result}).");
            }
            return r;
        }

        public async Task StopAsync()
        {
            if (Interlocked.Exchange(ref _stopped, 1) != 0) return;
            if (DnsServiceDeRegister(_request, IntPtr.Zero) != RequestPending)
            {
                // Not taken back by a call: the registration's own callback still frees it, if it ever comes.
                if (Interlocked.Increment(ref _callbacks) >= 2) Free();
                return;
            }
            try
            {
                await _deregistered.Task.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                // Windows may still use the request: freed when its callbacks come, never under it.
            }
        }

        private void Free()
        {
            if (Interlocked.Exchange(ref _freed, 1) != 0) return;
            if (_instance != IntPtr.Zero) DnsServiceFreeInstance(_instance);
            if (_request != IntPtr.Zero) Marshal.FreeHGlobal(_request);
            if (_self.IsAllocated) _self.Free();
            _instance = _request = IntPtr.Zero;
        }

        private static void OnComplete(uint status, IntPtr context, IntPtr instance)
        {
            if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance); // the copy Windows hands back is ours to free
            if (context == IntPtr.Zero || GCHandle.FromIntPtr(context).Target is not Registration r) return;
            if (Interlocked.Increment(ref r._callbacks) == 1)
            {
                r._registered.TrySetResult(status);
                return;
            }
            r.Free();
            r._deregistered.TrySetResult();
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void RegisterComplete(uint status, IntPtr context, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    private struct RegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr Callback;
        public IntPtr Context;
        public IntPtr Credentials;
        public int UnicastEnabled;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName, ref uint ip4, IntPtr ip6, ushort port, ushort priority,
        ushort weight, uint propertyCount, string[] keys, string[] values);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsServiceFreeInstance(IntPtr instance);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceRegister(IntPtr request, IntPtr cancel);

    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceDeRegister(IntPtr request, IntPtr cancel);
}
