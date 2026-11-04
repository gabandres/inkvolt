// swift-tools-version:6.0
import PackageDescription

// PdfCore: Inkvolt PDF's rules, ported from pdf/src/InkvoltPdf.Core, over MuPDF (the same engine as the Windows app).
// MuPDF comes as a static XCFramework that mac/Vendor/mupdf/build.sh builds into Frameworks/ (not in git), so this
// package builds only on a Mac. MuPDFShim is the C between them: MuPDF reports errors with setjmp/longjmp (fz_try),
// which Swift can't catch, so every MuPDF call goes through a shim function that catches and returns the message.
// PrintCore (InkvoltPrintKit, this repo) brings the suite's Inkvolt Pro key, check and shared key file, as the Windows
// InkvoltPdf.Core references InkvoltPrint.Core; the tests take PrintMac's CryptoKit signature check.
let package = Package(
    name: "InkvoltPdfKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PdfCore", targets: ["PdfCore"])],
    dependencies: [.package(path: "../InkvoltPrintKit")],
    targets: [
        .binaryTarget(name: "MuPDF", path: "Frameworks/MuPDF.xcframework"),
        .target(name: "MuPDFShim", dependencies: ["MuPDF"]),
        // JavaScriptCore's watchdog (the time limit of form scripts), declared in C: see ScriptLimits.c.
        .target(name: "ScriptLimits", linkerSettings: [.linkedFramework("JavaScriptCore")]),
        .target(name: "PdfCore", dependencies: ["MuPDFShim", "ScriptLimits", .product(name: "PrintCore", package: "InkvoltPrintKit")]),
        .testTarget(name: "PdfCoreTests", dependencies: ["PdfCore", .product(name: "PrintCore", package: "InkvoltPrintKit"),
                                                         .product(name: "PrintMac", package: "InkvoltPrintKit")]),
    ]
)
