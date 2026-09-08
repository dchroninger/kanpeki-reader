// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KanpekiOCR",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "KanpekiOCR", targets: ["KanpekiOCR"])],
    targets: [
        .target(name: "KanpekiOCR", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "KanpekiOCRTests", dependencies: ["KanpekiOCR"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
