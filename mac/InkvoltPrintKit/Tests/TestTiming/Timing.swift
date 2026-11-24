import Foundation
#if os(Windows)
import WinSDK
#endif

/// Time in the Mac's tests, for both test targets (as Windows' shared/Testing/Timing.cs). GitHub's macOS runner is shared
/// and much slower than the Mac or the PC, and a full parallel run starves tasks there for seconds: a test that measures
/// time takes its limit through `limit(_:)`, so CI gets one factor instead of numbers scattered per test. The local limits
/// stay what they were.
public enum Timing {
    /// On a GitHub Actions runner.
    public static let onCI = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil

    /// How much longer a time limit may be on CI (the most the tests gave one by one before this).
    public static let ciFactor = 5

    /// A limit sized for the Mac and the PC, `ciFactor` times longer on CI.
    public static func limit(_ local: Duration) -> Duration { onCI ? local * ciFactor : local }

    /// The same, in seconds (tests timed with `Date`).
    public static func limit(_ local: TimeInterval) -> TimeInterval { onCI ? local * Double(ciFactor) : local }

    /// Seconds of processor time the calling thread has used: for a synchronous test that times its own work, which a full
    /// parallel run (the cores shared by every image test) can stretch tenfold on the clock without it doing more.
    public static func threadSeconds() -> TimeInterval {
        #if os(Windows)
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user) else { return 0 }
        func ticks(_ t: FILETIME) -> UInt64 { UInt64(t.dwHighDateTime) << 32 | UInt64(t.dwLowDateTime) }
        return Double(ticks(kernel) + ticks(user)) / 10_000_000 // 100 ns units
        #else
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { return 0 }
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
        #endif
    }
}
