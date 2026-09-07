// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KanpekiCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "KanpekiCore", targets: ["KanpekiCore"])],
    targets: [
        .target(name: "KanpekiCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "KanpekiCoreTests", dependencies: ["KanpekiCore"],
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
