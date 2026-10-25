using System.IO;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Presets;
using Microsoft.Win32;

namespace InkvoltPrint.App.Presets;

/// <summary>
/// "Email it": hands saved scans to the PC's own mail app. Nothing is sent by Inkvolt Print, and it has no mail account
/// or server. When a Simple MAPI mail client is registered (<c>Software\Clients\Mail</c>, e.g. classic Outlook or
/// Thunderbird), <c>MAPISendMailW</c> opens a new message with the files attached for the user to address and send.
/// Otherwise (or if that fails) the folder opens with the file selected and a <c>mailto:</c> link starts a message, since
/// mailto can't carry attachments. MAPI isn't tried when it can't work (<see cref="MailRoute"/>): the new Outlook as the
/// default mail app, or classic Outlook without a mail profile (which would ask to create one first).
/// </summary>
public static class MailHandoff
{
    public enum Result { Attached, Cancelled, FolderAndMailto }

    public static async Task<Result> SendAsync(IReadOnlyList<string> files, string subject)
    {
        var setup = ReadSetup();
        var (route, why) = MailRoute.Choose(setup);
        if (route == MailRouteKind.Mapi)
        {
            var code = await RunStaAsync(() => SendMail(files, subject));
            if (code == SuccessSuccess) return Result.Attached;
            if (code == MapiUserAbort) return Result.Cancelled;
            Log.Write($"MAPISendMailW ({setup.MapiClient}) returned {code}; falling back to mailto");
        }
        else
        {
            Log.Write($"Email: {why}; opening the folder and a mailto message");
        }
        Shell.ShowInFolder(files[0]);
        Shell.Open(MailRoute.MailtoUri(subject, files.Select(Path.GetFileName).OfType<string>().ToList()));
        return Result.FolderAndMailto;
    }

    private static MailSetup ReadSetup()
    {
        var progId = ReadString(Registry.CurrentUser, @"Software\Microsoft\Windows\Shell\Associations\UrlAssociations\mailto\UserChoice", "ProgId");
        var appId = progId is { Length: > 0 } && !progId.Contains('\\')
            ? ReadString(Registry.ClassesRoot, $@"{progId}\Application", "AppUserModelID")
            : null;
        return new MailSetup(DefaultMapiClient(), progId, appId, OutlookHasProfile());
    }

    /// <summary>
    /// Classic Outlook has a mail profile (Office 2016 and later, then 2013). No Profiles key, or an empty one, means Outlook
    /// was never set up: MAPI would ask to create a profile. Null when the registry couldn't be read.
    /// </summary>
    private static bool? OutlookHasProfile()
    {
        try
        {
            foreach (var version in new[] { "16.0", "15.0" })
            {
                using var key = Registry.CurrentUser.OpenSubKey($@"Software\Microsoft\Office\{version}\Outlook\Profiles");
                if (key?.SubKeyCount > 0) return true;
            }
            return false;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    private static string? ReadString(RegistryKey hive, string path, string? name)
    {
        try
        {
            using var key = hive.OpenSubKey(path);
            return key?.GetValue(name) as string;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    /// <summary>The registered Simple MAPI client's name (per user, then per machine), or null when there's none.</summary>
    private static string? DefaultMapiClient()
    {
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var key = hive.OpenSubKey(@"Software\Clients\Mail");
                if (key?.GetValue(null) is string { Length: > 0 } name) return name;
            }
            catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
            {
                // try the other hive
            }
        }
        return null;
    }

    /// <summary>MAPI's compose window is modal to its thread and blocks until it closes: give it its own STA thread.</summary>
    private static Task<uint> RunStaAsync(Func<uint> call)
    {
        var done = new TaskCompletionSource<uint>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try { done.SetResult(call()); }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException or SEHException or COMException)
            {
                Log.Write($"Simple MAPI unavailable: {ex.Message}");
                done.SetResult(MapiFailure);
            }
        }) { IsBackground = true, Name = "MAPI send" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }

    private const uint SuccessSuccess = 0, MapiUserAbort = 1, MapiFailure = 2;
    private const uint MapiLogonUi = 0x1, MapiDialog = 0x8;

    private static uint SendMail(IReadOnlyList<string> files, string subject)
    {
        var size = Marshal.SizeOf<MapiFileDescW>();
        var array = Marshal.AllocHGlobal(size * files.Count);
        var strings = new List<IntPtr>();
        try
        {
            for (var i = 0; i < files.Count; i++)
            {
                var path = Marshal.StringToHGlobalUni(files[i]);
                var name = Marshal.StringToHGlobalUni(Path.GetFileName(files[i]));
                strings.Add(path);
                strings.Add(name);
                Marshal.StructureToPtr(new MapiFileDescW { nPosition = uint.MaxValue, lpszPathName = path, lpszFileName = name }, array + i * size, false);
            }
            var subjectPtr = Marshal.StringToHGlobalUni(subject);
            strings.Add(subjectPtr);
            var message = new MapiMessageW { lpszSubject = subjectPtr, nFileCount = (uint)files.Count, lpFiles = array };
            return MAPISendMailW(IntPtr.Zero, IntPtr.Zero, ref message, MapiLogonUi | MapiDialog, 0);
        }
        finally
        {
            foreach (var s in strings) Marshal.FreeHGlobal(s);
            Marshal.FreeHGlobal(array);
        }
    }

    // mapi.h: MapiFileDescW, MapiMessageW (Windows 8+; mapi32.dll forwards to the default mail client).
    [StructLayout(LayoutKind.Sequential)]
    private struct MapiFileDescW
    {
        public uint ulReserved;
        public uint flFlags;
        public uint nPosition;
        public IntPtr lpszPathName;
        public IntPtr lpszFileName;
        public IntPtr lpFileType;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MapiMessageW
    {
        public uint ulReserved;
        public IntPtr lpszSubject;
        public IntPtr lpszNoteText;
        public IntPtr lpszMessageType;
        public IntPtr lpszDateReceived;
        public IntPtr lpszConversationID;
        public uint flFlags;
        public IntPtr lpOriginator;
        public uint nRecipCount;
        public IntPtr lpRecips;
        public uint nFileCount;
        public IntPtr lpFiles;
    }

    [DllImport("mapi32.dll", ExactSpelling = true)]
    private static extern uint MAPISendMailW(IntPtr session, IntPtr uiParam, ref MapiMessageW message, uint flags, uint reserved);
}
