// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TransposeNative",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TransposeNative", type: .static, targets: ["TransposeNative"])],
    targets: [
        .target(name: "TransposeNative")
    ],
    swiftLanguageModes: [.v5]
)
