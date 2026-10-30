// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchBar",
            path: "Sources/NotchBar",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        )
    ]
)
