// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermitControlLifecycleValidation",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", exact: "0.3.7"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.100.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
    ],
    targets: [
        .target(name: "Hermit", dependencies: [
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "HermitTests", dependencies: ["Hermit"]),
    ],
    swiftLanguageModes: [.v5]
)
