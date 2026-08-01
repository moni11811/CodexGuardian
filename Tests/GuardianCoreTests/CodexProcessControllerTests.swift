import Testing
@testable import GuardianCore
#if os(macOS)
import Darwin
#endif

private final class FakeCodexProcessDiscovery: CodexProcessDiscovering, @unchecked Sendable {
    var applicationSnapshots: [[CodexApplicationCandidate]]
    var processSnapshots: [[CodexRunningProcessCandidate]]
    var terminationCalls: [(Int32, Bool)] = []
    var launchCalls: [String] = []
    var terminationSucceeds = true
    var launchSucceeds = true

    init(
        applicationSnapshots: [[CodexApplicationCandidate]],
        processSnapshots: [[CodexRunningProcessCandidate]] = []
    ) {
        self.applicationSnapshots = applicationSnapshots
        self.processSnapshots = processSnapshots
    }

    func applicationCandidates(bundleIdentifier: String) throws -> [CodexApplicationCandidate] {
        next(&applicationSnapshots)
    }

    func runningProcessCandidates(bundleIdentifier: String) throws -> [CodexRunningProcessCandidate] {
        next(&processSnapshots)
    }

    func terminate(processID: Int32, force: Bool) -> Bool {
        terminationCalls.append((processID, force))
        return terminationSucceeds
    }

    func launch(applicationPath: String) -> Bool {
        launchCalls.append(applicationPath)
        return launchSucceeds
    }

    private func next<T>(_ snapshots: inout [[T]]) -> [T] {
        guard !snapshots.isEmpty else { return [] }
        if snapshots.count == 1 { return snapshots[0] }
        return snapshots.removeFirst()
    }
}

private let productionCodexTrust = CodexProcessTrustRequirement(
    bundleIdentifier: "com.openai.codex",
    signingIdentifier: "com.openai.codex",
    teamIdentifier: "2DC432GLL2"
)

@Test func productionCodexTrustPinsOpenAISigningIdentity() {
    #expect(CodexProcessTrustRequirement.openAIProduction == productionCodexTrust)
}

private func applicationCandidate(
    path: String = "/Applications/ChatGPT.app",
    bundleIdentifier: String = "com.openai.codex",
    signingIdentifier: String = "com.openai.codex",
    teamIdentifier: String = "2DC432GLL2"
) -> CodexApplicationCandidate {
    CodexApplicationCandidate(
        bundleIdentifier: bundleIdentifier,
        bundleURLPath: path,
        signingIdentifier: signingIdentifier,
        teamIdentifier: teamIdentifier
    )
}

private func runningCandidate(
    path: String = "/Applications/ChatGPT.app",
    processID: Int32 = 41,
    processStartIdentity: UInt64 = 4_567
) -> CodexRunningProcessCandidate {
    CodexRunningProcessCandidate(
        application: applicationCandidate(path: path),
        processID: processID,
        processStartIdentity: processStartIdentity
    )
}

@Test func renamedSignedCodexBundleDoesNotNeedAHardCodedProductName() throws {
    let candidate = applicationCandidate(path: "/Applications/Codex Renamed.app")

    let selected = try CodexProcessSelectionPolicy().selectApplication(
        candidates: [candidate],
        requirement: productionCodexTrust
    )

    #expect(selected == candidate)
}

@Test func multipleTrustedCodexInstallationsFailClosedAsAmbiguous() {
    let stable = applicationCandidate(path: "/Applications/ChatGPT.app")
    let beta = applicationCandidate(path: "/Applications/ChatGPT Beta.app")

    #expect(throws: CodexProcessSelectionError.ambiguousApplications) {
        try CodexProcessSelectionPolicy().selectApplication(
            candidates: [stable, beta],
            requirement: productionCodexTrust
        )
    }
}

@Test func signingAndTeamIdentityDriftFailClosed() {
    let wrongSigningID = applicationCandidate(signingIdentifier: "example.attacker")
    let wrongTeam = applicationCandidate(teamIdentifier: "ATTACKER123")

    #expect(throws: CodexProcessSelectionError.signingIdentifierMismatch) {
        try CodexProcessSelectionPolicy().selectApplication(
            candidates: [wrongSigningID],
            requirement: productionCodexTrust
        )
    }
    #expect(throws: CodexProcessSelectionError.teamIdentifierMismatch) {
        try CodexProcessSelectionPolicy().selectApplication(
            candidates: [wrongTeam],
            requirement: productionCodexTrust
        )
    }
}

@Test func reusedPIDCannotBeSignaledAsTheCapturedProcessEpoch() {
    let captured = runningCandidate(processID: 41, processStartIdentity: 4_567)
    let reused = runningCandidate(processID: 41, processStartIdentity: 9_999)
    let policy = CodexProcessSelectionPolicy()

    #expect(throws: CodexProcessSelectionError.processEpochChanged) {
        try policy.validateSignalTarget(captured: captured, observed: reused)
    }
    #expect(policy.didRestart(previous: captured, current: reused))
}

@Test func unchangedProcessEpochIsNotARestart() {
    let process = runningCandidate(processID: 41, processStartIdentity: 4_567)

    #expect(!CodexProcessSelectionPolicy().didRestart(
        previous: process,
        current: process
    ))
}

@Test func missingApplicationAndRunningProcessFailClosed() {
    let policy = CodexProcessSelectionPolicy()

    #expect(throws: CodexProcessSelectionError.applicationNotFound) {
        try policy.selectApplication(candidates: [], requirement: productionCodexTrust)
    }
    #expect(throws: CodexProcessSelectionError.processNotFound) {
        try policy.selectRunningProcess(candidates: [], requirement: productionCodexTrust)
    }
}

@Test func multipleTrustedRunningProcessesFailClosed() {
    let first = runningCandidate(processID: 41, processStartIdentity: 4_567)
    let second = runningCandidate(processID: 42, processStartIdentity: 4_568)

    #expect(throws: CodexProcessSelectionError.ambiguousProcesses) {
        try CodexProcessSelectionPolicy().selectRunningProcess(
            candidates: [first, second],
            requirement: productionCodexTrust
        )
    }
}

@Test func malformedApplicationAndProcessIdentityFailClosed() {
    let malformedApplication = applicationCandidate(path: "relative/ChatGPT.app")
    let malformedProcess = CodexRunningProcessCandidate(
        application: applicationCandidate(),
        processID: 0,
        processStartIdentity: 0
    )
    let policy = CodexProcessSelectionPolicy()

    #expect(throws: CodexProcessSelectionError.invalidApplicationIdentity) {
        try policy.selectApplication(
            candidates: [malformedApplication],
            requirement: productionCodexTrust
        )
    }
    #expect(throws: CodexProcessSelectionError.invalidProcessIdentity) {
        try policy.selectRunningProcess(
            candidates: [malformedProcess],
            requirement: productionCodexTrust
        )
    }
}

@Test func controllerRevalidatesProcessEpochImmediatelyBeforeTermination() throws {
    let application = applicationCandidate()
    let captured = runningCandidate(processID: 41, processStartIdentity: 4_567)
    let reused = runningCandidate(processID: 41, processStartIdentity: 9_999)
    let discovery = FakeCodexProcessDiscovery(
        applicationSnapshots: [[application]],
        processSnapshots: [[captured], [reused]]
    )
    let controller = CodexProcessController(
        requirement: productionCodexTrust,
        discovery: discovery
    )

    let observed = try controller.captureRunningProcess()
    #expect(throws: CodexProcessSelectionError.processEpochChanged) {
        try controller.terminate(observed, force: false)
    }
    #expect(discovery.terminationCalls.isEmpty)
}

@Test func controllerRefusesLaunchServicesReplacementBeforeLaunch() throws {
    let captured = applicationCandidate(path: "/Applications/ChatGPT.app")
    let replacement = applicationCandidate(path: "/Applications/ChatGPT Beta.app")
    let discovery = FakeCodexProcessDiscovery(
        applicationSnapshots: [[captured], [replacement]]
    )
    let controller = CodexProcessController(
        requirement: productionCodexTrust,
        discovery: discovery
    )

    let resolved = try controller.resolveApplication()
    #expect(throws: CodexProcessControllerError.applicationIdentityChanged) {
        try controller.launch(resolved)
    }
    #expect(discovery.launchCalls.isEmpty)
}

@Test func controllerRejectsRunningProcessFromDifferentTrustedBundlePath() throws {
    let selected = applicationCandidate(path: "/Applications/ChatGPT.app")
    let betaProcess = runningCandidate(path: "/Applications/ChatGPT Beta.app")
    let discovery = FakeCodexProcessDiscovery(
        applicationSnapshots: [[selected]],
        processSnapshots: [[betaProcess]]
    )
    let controller = CodexProcessController(
        requirement: productionCodexTrust,
        discovery: discovery
    )

    #expect(throws: CodexProcessControllerError.applicationIdentityChanged) {
        try controller.captureRunningProcess(matching: selected)
    }
}

@Test func controllerLaunchesExactVerifiedPathAndRequiresNewProcessEpoch() throws {
    let application = applicationCandidate(path: "/Applications/Codex Renamed.app")
    let previous = runningCandidate(
        path: application.bundleURLPath,
        processID: 41,
        processStartIdentity: 4_567
    )
    let current = runningCandidate(
        path: application.bundleURLPath,
        processID: 41,
        processStartIdentity: 9_999
    )
    let discovery = FakeCodexProcessDiscovery(
        applicationSnapshots: [[application]],
        processSnapshots: [[current]]
    )
    let controller = CodexProcessController(
        requirement: productionCodexTrust,
        discovery: discovery
    )

    try controller.launch(application)
    let verified = try controller.verifyRestart(previous: previous)

    #expect(discovery.launchCalls == [application.bundleURLPath])
    #expect(verified == current)
}

@Test func controllerRejectsUnchangedProcessAfterLaunch() {
    let application = applicationCandidate()
    let previous = runningCandidate()
    let discovery = FakeCodexProcessDiscovery(
        applicationSnapshots: [[application]],
        processSnapshots: [[previous]]
    )
    let controller = CodexProcessController(
        requirement: productionCodexTrust,
        discovery: discovery
    )

    #expect(throws: CodexProcessControllerError.processDidNotRestart) {
        try controller.verifyRestart(previous: previous)
    }
}

@Test func controllerVerifiesTrustedLaunchWhenCodexWasAlreadyStopped() throws {
    let application = applicationCandidate()
    let current = runningCandidate()
    let discovery = FakeCodexProcessDiscovery(
        applicationSnapshots: [[application]],
        processSnapshots: [[], [current]]
    )
    let controller = CodexProcessController(
        requirement: productionCodexTrust,
        discovery: discovery
    )

    let previous = try controller.captureRunningProcessIfPresent()
    #expect(previous == nil)
    let verified = try controller.verifyLaunch(
        application: application,
        previous: previous
    )

    #expect(verified == current)
}

@Test func controllerRefusesWrongTrustedBundleAfterLaunch() throws {
    let selected = applicationCandidate(path: "/Applications/ChatGPT.app")
    let betaProcess = runningCandidate(path: "/Applications/ChatGPT Beta.app")
    let discovery = FakeCodexProcessDiscovery(
        applicationSnapshots: [[selected]],
        processSnapshots: [[betaProcess]]
    )
    let controller = CodexProcessController(
        requirement: productionCodexTrust,
        discovery: discovery
    )

    #expect(throws: CodexProcessControllerError.applicationIdentityChanged) {
        try controller.verifyLaunch(application: selected, previous: nil)
    }
}

#if os(macOS)
@Test func macDiscoveryReadsAStableNonzeroProcessStartIdentity() throws {
    let discovery = MacCodexProcessDiscovery()

    let first = try discovery.processStartIdentity(processID: getpid())
    let second = try discovery.processStartIdentity(processID: getpid())

    #expect(first > 0)
    #expect(first == second)
}

@Test func macDiscoveryFailsClosedWhenProcessIdentityIsUnavailable() {
    #expect(throws: MacCodexProcessDiscoveryError.processIdentityUnavailable) {
        try MacCodexProcessDiscovery().processStartIdentity(processID: -1)
    }
}
#endif
