// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "logi-mouse",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "logi-mouse", targets: ["LogiMouse"])
    ],
    targets: [
        .executableTarget(
            name: "LogiMouse",
            path: "Sources/LogiMouse",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "LogiMouseTests",
            dependencies: ["LogiMouse"],
            path: "Tests/LogiMouseTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
