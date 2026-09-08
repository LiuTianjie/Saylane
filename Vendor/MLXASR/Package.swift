// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "mlx-swift-asr",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "MLXASR", targets: ["MLXASR"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.2.0"),
    ],
    targets: [
        .target(
            name: "MLXASR",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        )
    ]
)
