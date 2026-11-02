import Testing

/// The suites that touch the Pro check's globals (`Pro.store`, `Pro.verifier`, `ProCheck.enforced`) run under this one, one
/// test at a time (the Windows tests' "Pro" collection): `ProTests` and `SupplyHistoryCsvTests`.
@Suite(.serialized)
struct ProGated {}
