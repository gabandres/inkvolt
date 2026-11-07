// swift-tools-version:6.0
import PackageDescription

// The Mac's half of the forms corpus (Windows: pdf/tools/forms-corpus): the same ~300 public forms and synthetic edge
// cases, filled through PdfCore's real form path, read back with FormEditor, MuPDF and pdf.js. Builds only on a Mac (PdfCore
// needs MuPDF's XCFramework). It reads PdfCore's objects to check what was written, so it is built with testing on:
//   swift build -c release -Xswiftc -enable-testing --package-path mac/tools/forms-corpus
// See README.md.
let package = Package(
    name: "InkvoltFormsCorpus",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../InkvoltPdfKit")],
    targets: [
        .executableTarget(name: "InkvoltFormsCorpus", dependencies: [.product(name: "PdfCore", package: "InkvoltPdfKit")]),
    ]
)
