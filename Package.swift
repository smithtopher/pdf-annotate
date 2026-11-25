// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PDFAnnotate",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PDFAnnotate", path: "Sources/PDFAnnotate")
    ]
)
