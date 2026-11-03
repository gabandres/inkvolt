// swift-tools-version:6.0
import PackageDescription

// The Mac's half of roadmap 3.6's benchmark (Windows: pdf/tools/bench): the same corpus, made deterministically, and the
// same measures over PdfCore. Builds only on a Mac (PdfCore needs MuPDF's XCFramework, see InkvoltPdfKit's Package.swift).
//   swift run -c release --package-path mac/tools/bench InkvoltBench make [--out dir] [--small]
//   swift run -c release --package-path mac/tools/bench InkvoltBench run  [--out dir] [--reps n] [--note text] [--md path]
// See README.md.
let package = Package(
    name: "InkvoltBench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../InkvoltPdfKit")],
    targets: [
        .executableTarget(name: "InkvoltBench", dependencies: [.product(name: "PdfCore", package: "InkvoltPdfKit")]),
    ]
)
