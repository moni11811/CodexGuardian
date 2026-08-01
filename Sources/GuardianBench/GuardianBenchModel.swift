import Foundation

public enum GuardianBenchSeverity: String, Codable, Sendable {
    case low, medium, high, critical
}

public enum GuardianBenchSupport: String, Codable, Sendable {
    case supported
    case notAvailable = "not_available"
}

public struct GuardianBenchScenario: Codable, Equatable, Sendable {
    public let id: String
    public let severity: GuardianBenchSeverity
    public let support: GuardianBenchSupport
    public let trialCount: Int
    public let seedOffset: UInt64

    public init(id: String, severity: GuardianBenchSeverity, support: GuardianBenchSupport, trialCount: Int, seedOffset: UInt64) {
        self.id = id
        self.severity = severity
        self.support = support
        self.trialCount = trialCount
        self.seedOffset = seedOffset
    }
}

public struct GuardianBenchSuite: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let frozenRevision: String
    public let scenarios: [GuardianBenchScenario]

    public init(schemaVersion: Int, frozenRevision: String, scenarios: [GuardianBenchScenario]) {
        self.schemaVersion = schemaVersion
        self.frozenRevision = frozenRevision
        self.scenarios = scenarios
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw GuardianBenchError.unsupportedSchema(schemaVersion) }
        guard !frozenRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GuardianBenchError.invalidSuite("empty frozenRevision") }
        guard !scenarios.isEmpty else { throw GuardianBenchError.invalidSuite("no scenarios") }
        var ids = Set<String>()
        for scenario in scenarios {
            guard !scenario.id.isEmpty, ids.insert(scenario.id).inserted else { throw GuardianBenchError.invalidSuite("scenario ids must be unique and nonempty") }
            guard scenario.trialCount > 0 else { throw GuardianBenchError.invalidSuite("trialCount must be positive") }
        }
    }
}

public enum GuardianBenchResultStatus: String, Codable, Sendable {
    case completed
    case notAvailable = "not_available"
}

public struct GuardianBenchConfidenceBounds: Codable, Equatable, Sendable {
    public let lower: Double
    public let upper: Double
}

public struct GuardianBenchResult: Codable, Equatable, Sendable {
    public let scenarioId: String
    public let status: GuardianBenchResultStatus
    public let trialCount: Int?
    public let correctOutcomes: Int?
    public let unsafeRestarts: Int?
    public let wrongThreadContinuations: Int?
    public let duplicateAcceptedCommands: Int?
    public let lostAcceptedCommands: Int?
    public let operatorActions: Int?
    public let classificationMilliseconds: [Int]?
    public let repairMilliseconds: [Int]?
    public let safePointWaitMilliseconds: [Int]?
    public let finalJournalPhase: String?
    public let evidence: [String]
    public let confidenceBounds: GuardianBenchConfidenceBounds?
}

public struct GuardianBenchConfidenceMetadata: Codable, Equatable, Sendable {
    public let method: String
    public let confidenceLevel: Double
    public let warning: String
}

public struct GuardianBenchReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let benchmarkRevision: String
    public let implementation: String
    public let revision: String
    public let environment: String
    public let seed: UInt64
    public let mode: String
    public let confidence: GuardianBenchConfidenceMetadata
    public let results: [GuardianBenchResult]
}

public struct GuardianBenchConfiguration: Equatable, Sendable {
    public let implementation: String
    public let revision: String
    public let seed: UInt64
    public let environment: String

    public init(implementation: String, revision: String, seed: UInt64, environment: String) {
        self.implementation = implementation
        self.revision = revision
        self.seed = seed
        self.environment = environment
    }
}

public enum GuardianBenchError: Error, Equatable {
    case unsupportedSchema(Int)
    case invalidSuite(String)
    case unsupportedScenario(String)
}

public enum GuardianBenchPaths {
    public static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()
}

public enum GuardianBenchCodec {
    public static func decodeSuite(_ data: Data) throws -> GuardianBenchSuite {
        let suite = try JSONDecoder().decode(GuardianBenchSuite.self, from: data)
        try suite.validate()
        return suite
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
