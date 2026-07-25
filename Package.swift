// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexGuardian",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GuardianCore", targets: ["GuardianCore"]),
        .executable(name: "CodexGuardian", targets: ["CodexGuardian"]),
        .executable(name: "codex-guardian-mcp", targets: ["CodexGuardianMCP"]),
    ],
    targets: [
        .target(name: "GuardianCore"),
        .executableTarget(name: "CodexGuardian", dependencies: ["GuardianCore"]),
        .executableTarget(name: "CodexGuardianMCP", dependencies: ["GuardianCore"]),
        .testTarget(name: "GuardianCoreTests", dependencies: ["GuardianCore"]),
    ]
)
