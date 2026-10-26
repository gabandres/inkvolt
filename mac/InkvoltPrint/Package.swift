// swift-tools-version:6.0
import PackageDescription

// Inkvolt Print for macOS. For now a SwiftPM executable that build.sh wraps into a signed, sandboxed .app; the Xcode
// project App Store archiving needs comes before P11 (docs/PLAN.md).
let package = Package(
    name: "InkvoltPrint",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../InkvoltPrintKit")],
    targets: [
        .executableTarget(name: "InkvoltPrint", dependencies: [
            .product(name: "PrintCore", package: "InkvoltPrintKit"),
            .product(name: "PrintMac", package: "InkvoltPrintKit"),
        ]),
    ]
)
