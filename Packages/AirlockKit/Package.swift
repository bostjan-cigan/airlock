// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AirlockKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AirlockCore", targets: ["AirlockCore"]),
        .library(name: "AirlockRuntime", targets: ["AirlockRuntime"]),
        .library(name: "AirlockDocker", targets: ["AirlockDocker"]),
        .library(name: "AirlockApple", targets: ["AirlockApple"]),
        .library(name: "AirlockWorkspace", targets: ["AirlockWorkspace"]),
        .library(name: "AirlockProviders", targets: ["AirlockProviders"]),
        .library(name: "AirlockEngine", targets: ["AirlockEngine"]),
        .library(name: "AirlockControl", targets: ["AirlockControl"]),
        .library(name: "AirlockUI", targets: ["AirlockUI"]),
        .executable(name: "airlock-cli", targets: ["airlock-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        // Same version apple/container ships with; the API is only stable within a release.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.47.0"),
        // 1.12+ adds Metal shaders, which need a separate Xcode toolchain download to build.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.11.2")),
    ],
    targets: [
        // Models, persistence, secrets, activity reduction. Foundation only.
        .target(name: "AirlockCore"),

        // The runtime-agnostic container interface every backend implements.
        .target(name: "AirlockRuntime", dependencies: ["AirlockCore"]),

        // Docker Engine API over the local unix socket.
        .target(
            name: "AirlockDocker",
            dependencies: [
                "AirlockRuntime",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),

        // Apple Containerization: each container is its own lightweight VM.
        .target(
            name: "AirlockApple",
            dependencies: [
                "AirlockRuntime",
                "AirlockDocker",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ]
        ),

        // How a task's code gets into its container (git worktree or isolated clone).
        .target(name: "AirlockWorkspace", dependencies: ["AirlockRuntime"]),

        // Agent providers (Claude Code today) and the container images they run in.
        .target(
            name: "AirlockProviders",
            dependencies: ["AirlockRuntime"],
            resources: [.copy("Resources/images")]
        ),

        // Orchestrates tasks across runtimes, workspaces and providers.
        .target(
            name: "AirlockEngine",
            dependencies: [
                "AirlockRuntime", "AirlockDocker", "AirlockApple", "AirlockWorkspace", "AirlockProviders",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),

        // Control socket served by the app, and the MCP server the Claude plugin runs.
        .target(
            name: "AirlockControl",
            dependencies: [
                "AirlockEngine",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),

        // SwiftUI views. The app target is a thin @main around this.
        .target(
            name: "AirlockUI",
            dependencies: ["AirlockEngine", "AirlockControl", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),

        .executableTarget(name: "airlock-cli", dependencies: ["AirlockEngine", "AirlockDocker", "AirlockApple", "AirlockProviders", "AirlockControl"]),

        .testTarget(name: "AirlockCoreTests", dependencies: ["AirlockCore"]),
        .testTarget(name: "AirlockDockerTests", dependencies: ["AirlockDocker"]),
        .testTarget(name: "AirlockWorkspaceTests", dependencies: ["AirlockWorkspace"]),
        .testTarget(name: "AirlockProvidersTests", dependencies: ["AirlockProviders"]),
        .testTarget(name: "AirlockEngineTests", dependencies: ["AirlockEngine", "AirlockDocker", "AirlockProviders"]),
        .testTarget(name: "AirlockControlTests", dependencies: ["AirlockControl"]),
        .testTarget(name: "AirlockUITests", dependencies: ["AirlockUI"]),
    ]
)
