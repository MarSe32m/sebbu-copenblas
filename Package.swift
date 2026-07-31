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
            url: "https://github.com/MarSe32m/sebbu-copenblas/releases/download/0.3.34/COpenBLAS.artifactbundle.zip", 
            checksum: "803439d4963a8206b938178c62822048ce9bd36e0a3ef1eb400a104aa4a27506"
        ),
        .executableTarget(
            name: "Development",
            dependencies: [
                .target(name: "COpenBLAS", condition: .when(platforms: [.linux, .windows]))
            ]
        )
    ]
)