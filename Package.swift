// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PulseBar",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "PulseBarCore",
            targets: ["PulseBarCore"]
        ),
        .executable(
            name: "Pulse",
            targets: ["PulseBar"]
        )
    ],
    targets: [
        .target(
            name: "PulseBarCore",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "PulseBar",
            dependencies: ["PulseBarCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "PulseBarTests",
            dependencies: ["PulseBarCore"]
        )
    ]
)
