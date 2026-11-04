import PdfCore
import PrintCore
import Testing

/// The suites that touch the Pro check's globals (`Pro.store`, `Pro.verifier`, `Pro.enforced`) or ask it from the command
/// line, run one test at a time (the Windows tests' "Pro" collection): `ProTests` and `BatchAutomationTests`.
@Suite(.serialized)
struct ProGated {}

// The key, its check and its stores are the suite's (PrintCore), which has Inkvolt Print's `Pro` and `ProFeature` too:
// in these tests both names are Inkvolt PDF's, whichever modules a file imports.
typealias Pro = PdfCore.Pro
typealias ProFeature = PdfCore.ProFeature
typealias MemoryProStore = PrintCore.MemoryProStore
