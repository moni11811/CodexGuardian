import Foundation
import GuardianBench

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

do {
    let arguments = CommandLine.arguments
    let root = GuardianBenchPaths.repositoryRoot
    let scenarios = URL(fileURLWithPath: value(after: "--scenarios", in: arguments) ?? root.appending(path: "Benchmarks/GuardianBench/scenarios.v1.json").path)
    let output = value(after: "--output", in: arguments).map(URL.init(fileURLWithPath:))
    let seed = UInt64(value(after: "--seed", in: arguments) ?? "1") ?? 1
    let suite = try GuardianBenchCodec.decodeSuite(Data(contentsOf: scenarios))
    let report = try GuardianBenchRunner(configuration: GuardianBenchConfiguration(
        implementation: value(after: "--implementation", in: arguments) ?? "CodexGuardian",
        revision: value(after: "--revision", in: arguments) ?? "working-tree",
        seed: seed,
        environment: "deterministic-local-no-network"
    )).run(suite)
    let data = try GuardianBenchCodec.encode(report)
    if let output {
        try data.write(to: output, options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
} catch {
    FileHandle.standardError.write(Data("guardian-bench: \(error)\n".utf8))
    exit(2)
}
