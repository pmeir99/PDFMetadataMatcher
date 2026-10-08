// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFMetadataMatcher",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PDFMetadataMatcher", targets: ["PDFMetadataMatcher"])],
    targets: [.executableTarget(name: "PDFMetadataMatcher")]
)
