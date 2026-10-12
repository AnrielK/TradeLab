// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TradeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OptionsMath", targets: ["OptionsMath"]),
        .library(name: "MarketData", targets: ["MarketData"]),
    ],
    targets: [
        .target(name: "OptionsMath"),
        .target(name: "MarketData", dependencies: ["OptionsMath"]),
        .testTarget(name: "OptionsMathTests", dependencies: ["OptionsMath"]),
        .testTarget(
            name: "MarketDataTests",
            dependencies: ["MarketData"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
