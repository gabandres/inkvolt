// swift-tools-version:6.0
import PackageDescription

// A throwaway app: build it with build.sh, which wraps the binary in a signed, sandboxed .app.
let package = Package(
    name: "InkvoltProbe",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CCups", path: "Sources/CCups"),
        .executableTarget(name: "InkvoltProbe", dependencies: ["CCups"], path: "Sources/InkvoltProbe"),
    ],
    swiftLanguageModes: [.v5]
)
