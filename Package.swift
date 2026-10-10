// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kadr",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Kadr",
            path: "Sources/Kadr",
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
