// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TimeSink",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TimeSinkKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            linkerSettings: [
                .linkedFramework("ScriptingBridge"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(name: "TimeSink", dependencies: ["TimeSinkKit"]),
        .executableTarget(name: "tsprobe", dependencies: ["TimeSinkKit"]),
        .testTarget(name: "TimeSinkKitTests", dependencies: ["TimeSinkKit"]),
    ]
)
