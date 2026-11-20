using System.Runtime.InteropServices;

namespace InkvoltPdf.Bench;

/// <summary>What makes this console program start like a windowed app for a test of the command line's output.</summary>
internal static class BenchConsole
{
    [DllImport("kernel32.dll")]
    public static extern bool FreeConsole();

    [DllImport("kernel32.dll")]
    public static extern bool SetStdHandle(int which, nint handle);
}
