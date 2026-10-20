// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DateiConverter",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DateiConverter", targets: ["DateiConverter"])],
    targets: [.executableTarget(name: "DateiConverter", path: "Sources/DateiConverter")]
)
