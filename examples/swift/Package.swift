// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HoundExample",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HoundExample", targets: ["HoundExample"])
    ],
    targets: [
        .systemLibrary(
            name: "CHound",
            path: "Sources/CHound"
        ),
        .executableTarget(
            name: "HoundExample",
            dependencies: ["CHound"],
            path: "Sources/HoundExample",
            linkerSettings: [
                .linkedLibrary("hound_c"),
                .unsafeFlags(["-L."]),
                .unsafeFlags(["-L../../zig-out/lib"])
            ]
        )
    ]
)
