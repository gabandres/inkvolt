import Foundation

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
}
