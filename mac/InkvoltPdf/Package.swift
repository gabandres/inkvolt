// swift-tools-version:6.0
import PackageDescription

// Inkvolt PDF for macOS: the app (AppKit), over InkvoltPdfKit's PdfCore (MuPDF). build.sh builds it, makes
// "Inkvolt PDF.app" with Info.plist, signs it with the Mac's Apple Development identity and installs it in /Applications.
// Sparkle 2 (MIT) checks for updates; assemble.sh embeds its framework in Contents/Frameworks.
let package = Package(
    name: "InkvoltPdf",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../InkvoltPdfKit"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(name: "InkvoltPdf", dependencies: [
            .product(name: "PdfCore", package: "InkvoltPdfKit"),
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
    ]
)
