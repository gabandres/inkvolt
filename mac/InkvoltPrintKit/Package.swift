// swift-tools-version:6.0
import PackageDescription

// PrintCore: Inkvolt Print's protocols and rules, ported from shared/InkvoltPrint.Core. Foundation only, so it builds
// and tests on the Windows PC too; the tests read the .NET fixtures in place (print/tests/InkvoltPrint.Tests/Fixtures).
let package = Package(
    name: "InkvoltPrintKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PrintCore", targets: ["PrintCore"]),
    ],
    targets: [
        .target(name: "PrintCore"),
        .testTarget(name: "PrintCoreTests", dependencies: ["PrintCore"]),
    ]
)
