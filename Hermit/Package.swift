// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermitCoreValidation",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "HermitCoreValidationRunner", targets: ["HermitCoreValidationRunner"]),
    ],
    targets: [
        .executableTarget(
            name: "HermitCoreValidationRunner",
            path: ".",
            exclude: [
                "Gemfile",
                "Gemfile.lock",
                "Hermit/App",
                "Hermit/Assets.xcassets",
                "Hermit/Hermit.entitlements",
                "Hermit/Info.plist",
                "Hermit/Models",
                "Hermit/Resources",
                "Hermit/SSH",
                "Hermit/Storage",
                "Hermit/Tmux/TmuxCommands.swift",
                "Hermit/Tmux/TmuxControlClient.swift",
                "Hermit/Tmux/TmuxWorkspaceModel.swift",
                "Hermit/Views",
                "Hermit/Voice",
                "HermitTests",
                "run-hermit-simulator.sh",
                "setup-xcode-ios.sh",
                "fastlane",
            ],
            sources: [
                "Hermit/Tmux/TmuxModels.swift",
                "Hermit/Tmux/TmuxProtocolParser.swift",
                "Hermit/Rendering/AnsiAttributedString.swift",
                "Hermit/Rendering/PaneLayoutParser.swift",
                "Validation/Runner.swift",
            ]
        ),
    ]
)
