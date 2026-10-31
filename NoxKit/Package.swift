// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoxKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "NoxCore",      targets: ["NoxCore"]),
        .library(name: "NoxKeepAlive", targets: ["NoxKeepAlive"]),
        .library(name: "NoxParsing",   targets: ["NoxParsing"]),
        .library(name: "NoxDownload",  targets: ["NoxDownload"]),
        .library(name: "NoxState",     targets: ["NoxState"]),
        .library(name: "NoxBrowser",   targets: ["NoxBrowser"]),
    ],
    targets: [
        .target(name: "NoxCore"),
        .target(name: "NoxKeepAlive", dependencies: ["NoxCore"]),
        .target(name: "NoxParsing",   dependencies: ["NoxCore"]),
        .target(name: "NoxDownload",  dependencies: ["NoxCore", "NoxKeepAlive"]),
        .target(name: "NoxState",     dependencies: ["NoxCore"]),
        .target(name: "NoxBrowser",   dependencies: ["NoxCore", "NoxParsing"]),
    ]
)
