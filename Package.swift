// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Kadr",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Kadr",
            path: "Sources/Kadr",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
