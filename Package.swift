// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexGuardian",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GuardianCore", targets: ["GuardianCore"]),
        .library(name: "GuardianPhoneCore", targets: ["GuardianPhoneCore"]),
        .library(name: "GuardianClient", targets: ["GuardianClient"]),
        .library(name: "GuardianBench", targets: ["GuardianBench"]),
        .executable(name: "CodexGuardian", targets: ["CodexGuardian"]),
        .executable(name: "codex-guardian-mcp", targets: ["CodexGuardianMCP"]),
        .executable(name: "guardian-daemon", targets: ["GuardianDaemon"]),
        .executable(name: "guardianctl", targets: ["GuardianCLI"]),
        .executable(name: "guardian-bench", targets: ["GuardianBenchCLI"]),
        .executable(
            name: "guardian-journal-crash-worker",
            targets: ["GuardianJournalCrashWorker"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "GuardianCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "GuardianClient", dependencies: ["GuardianCore"]),
        .target(name: "GuardianPhoneCore"),
        .target(name: "GuardianBench", dependencies: ["GuardianCore"]),
        .executableTarget(
            name: "GuardianBenchCLI",
            dependencies: ["GuardianBench"],
            path: "Benchmarks/GuardianBench/CLI"
        ),
        .executableTarget(name: "GuardianDaemon", dependencies: ["GuardianCore"]),
        .executableTarget(
            name: "GuardianCLI",
            dependencies: ["GuardianClient", "GuardianCore"]
        ),
        .executableTarget(
            name: "CodexGuardian",
            dependencies: ["GuardianClient", "GuardianCore"]
        ),
        .executableTarget(
            name: "CodexGuardianMCP",
            dependencies: ["GuardianClient", "GuardianCore"]
        ),
        .executableTarget(
            name: "GuardianJournalCrashWorker",
            dependencies: ["GuardianCore"]
        ),
        .testTarget(
            name: "GuardianCoreTests",
            dependencies: [
                "GuardianCore",
                "GuardianBench",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            exclude: ["Fixtures/FakeCodexAppServer.py"]
        ),
        .testTarget(
            name: "GuardianClientTests",
            dependencies: ["GuardianClient", "GuardianCore"]
        ),
        .testTarget(
            name: "GuardianPhoneCoreTests",
            dependencies: ["GuardianPhoneCore", "GuardianCore"]
        ),
    ]
)
