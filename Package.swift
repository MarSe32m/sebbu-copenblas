// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "sebbu-copenblas",
    products: [
        .library(
            name: "COpenBLAS",
            targets: ["COpenBLAS"]
        ),
    ],
    targets: [
        .target(
            name: "COpenBLAS",
            dependencies: ["_COpenBLAS"],
            path: "Sources/COpenBLAS",
            linkerSettings: [
                .linkedLibrary("m", .when(platforms: [.linux])),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
            ]
        ),
        .binaryTarget(
            name: "_COpenBLAS",
            path: "COpenBLAS.artifactbundle"
        ),
        .executableTarget(
            name: "Development",
            dependencies: [.target(name: "COpenBLAS", condition: .when(platforms: [.linux, .windows]))]
        )
    ]
)