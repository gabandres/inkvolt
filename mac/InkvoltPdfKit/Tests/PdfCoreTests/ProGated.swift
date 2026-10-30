import Testing

/// The suites that touch the Pro check's globals (`Pro.store`, `Pro.enforced`) or ask it from the command line, run one
/// test at a time (the Windows tests' "Pro" collection): `ProTests` and `BatchAutomationTests`.
@Suite(.serialized)
struct ProGated {}
