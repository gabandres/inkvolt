// swift-tools-version:6.0
import PackageDescription

// PrintCore: Inkvolt Print's protocols and rules, ported from shared/InkvoltPrint.Core. Foundation only, so it builds
// and tests on the Windows PC too; the tests read the .NET fixtures in place (print/tests/InkvoltPrint.Tests/Fixtures).
// PrintMac: the adapters to Apple's frameworks (URLSession, sockets, Bonjour, libcups), so it exists only when building on a Mac.
var products: [Product] = [.library(name: "PrintCore", targets: ["PrintCore"])]
var targets: [Target] = [
    .target(name: "PrintCore"),
    .testTarget(name: "PrintCoreTests", dependencies: ["PrintCore"]),
]
#if os(macOS)
products.append(.library(name: "PrintMac", targets: ["PrintMac"]))
targets += [
    .systemLibrary(name: "CCups", path: "Sources/CCups"), // libcups, macOS's own (the print queues)
    .target(name: "PrintMac", dependencies: ["PrintCore", "CCups"]),
    .testTarget(name: "PrintMacTests", dependencies: ["PrintMac", "PrintCore"]),
]
#endif

let package = Package(
    name: "InkvoltPrintKit",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
