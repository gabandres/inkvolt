// swift-tools-version:6.0
import PackageDescription

// Inkvolt PDF for macOS: the app (AppKit), over InkvoltPdfKit's PdfCore (MuPDF). build.sh builds it, makes
// "Inkvolt PDF.app" with Info.plist, signs it with the Mac's Apple Development identity and installs it in /Applications.
let package = Package(
    name: "InkvoltPdf",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../InkvoltPdfKit")],
    targets: [
        .executableTarget(name: "InkvoltPdf", dependencies: [.product(name: "PdfCore", package: "InkvoltPdfKit")]),
    ]
)
