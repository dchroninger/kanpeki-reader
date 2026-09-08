// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KanpekiDictionary",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "KanpekiDictionary", targets: ["KanpekiDictionary"])],
    targets: [
        .target(name: "KanpekiDictionary", swiftSettings: [.swiftLanguageMode(.v6)], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "KanpekiDictionaryTests", dependencies: ["KanpekiDictionary"],
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
