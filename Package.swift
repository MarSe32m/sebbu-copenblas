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
        .binaryTarget(
            name: "COpenBLAS", 
            path: "COpenBLAS.artifactbundle"
        ),
        .executableTarget(
            name: "Development",
            dependencies: [
                .target(name: "COpenBLAS", condition: .when(platforms: [.linux, .windows]))
            ]
        )
    ]
)
