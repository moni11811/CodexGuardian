import Testing
@testable import GuardianCore

private let probeDesktop = CodexRunningProcessCandidate(
    application: CodexApplicationCandidate(
        bundleIdentifier: "com.openai.codex",
        bundleURLPath: "/Applications/Codex Renamed.app",
        signingIdentifier: "com.openai.codex",
        teamIdentifier: "2DC432GLL2"
    ),
    processID: 100,
    processStartIdentity: 4_567
)

@Test func desktopChildAppServerDefaultsToStdioWithoutAListenerFlag() throws {
    let processList = """
      100     1 /Applications/Codex Renamed.app/Contents/MacOS/ChatGPT
      101   100 /Applications/Codex Renamed.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
    """

    let observation = try CodexDesktopProcessProbe().inspect(
        processList: processList,
        desktop: probeDesktop
    )

    #expect(observation.processID == 101)
    #expect(observation.parentProcessID == probeDesktop.processID)
    #expect(observation.transport == .stdio)
    #expect(observation.listenerURL == nil)
}

@Test func exactDesktopChildUnixListenerIsReported() throws {
    let processList = """
      101   100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server --listen unix:///tmp/codex.sock
    """

    let observation = try CodexDesktopProcessProbe().inspect(
        processList: processList,
        desktop: probeDesktop
    )

    #expect(observation.transport == .unixSocket)
    #expect(observation.listenerURL == "unix:///tmp/codex.sock")
}

@Test func detachedAppServerCannotImpersonateDesktopChild() {
    let processList = """
      101     1 /Applications/Codex Renamed.app/Contents/Resources/codex app-server --listen unix:///tmp/codex.sock
    """

    #expect(throws: CodexDesktopProcessProbeError.appServerMissing) {
        try CodexDesktopProcessProbe().inspect(
            processList: processList,
            desktop: probeDesktop
        )
    }
}

@Test func multipleDesktopChildAppServersFailClosed() {
    let processList = """
      101   100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server
      102   100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server --listen unix:///tmp/codex.sock
    """

    #expect(throws: CodexDesktopProcessProbeError.ambiguousAppServers) {
        try CodexDesktopProcessProbe().inspect(
            processList: processList,
            desktop: probeDesktop
        )
    }
}

@Test func malformedOrConflictingProcessEvidenceFailsClosed() {
    let malformed = "not-a-pid 100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server"
    let conflicting = "101 100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server --stdio --listen unix:///tmp/codex.sock"

    #expect(throws: CodexDesktopProcessProbeError.malformedProcessTable) {
        try CodexDesktopProcessProbe().inspect(
            processList: malformed,
            desktop: probeDesktop
        )
    }
    #expect(throws: CodexDesktopProcessProbeError.conflictingTransportArguments) {
        try CodexDesktopProcessProbe().inspect(
            processList: conflicting,
            desktop: probeDesktop
        )
    }
}

@Test func sameBundleNameAtDifferentPathCannotMatch() {
    let processList = """
      101   100 /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen unix:///tmp/codex.sock
    """

    #expect(throws: CodexDesktopProcessProbeError.appServerMissing) {
        try CodexDesktopProcessProbe().inspect(
            processList: processList,
            desktop: probeDesktop
        )
    }
}

@Test func globalOptionValueCannotImpersonateAppServerSubcommand() {
    let processList = """
      101   100 /Applications/Codex Renamed.app/Contents/Resources/codex -c app-server --version
    """

    #expect(throws: CodexDesktopProcessProbeError.appServerMissing) {
        try CodexDesktopProcessProbe().inspect(
            processList: processList,
            desktop: probeDesktop
        )
    }
}

@Test func appServerManagementSubcommandIsNotDesktopControlEndpoint() {
    let processList = """
      101   100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server daemon
    """

    #expect(throws: CodexDesktopProcessProbeError.appServerMissing) {
        try CodexDesktopProcessProbe().inspect(
            processList: processList,
            desktop: probeDesktop
        )
    }
}

@Test func missingListenValueFailsClosed() {
    let processList = """
      101   100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server --listen
    """

    #expect(throws: CodexDesktopProcessProbeError.invalidTransportArguments) {
        try CodexDesktopProcessProbe().inspect(
            processList: processList,
            desktop: probeDesktop
        )
    }
}

@Test func unsupportedWebSocketListenerStaysUnknown() throws {
    let processList = """
      101   100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server --listen=ws://127.0.0.1:4500
    """

    let observation = try CodexDesktopProcessProbe().inspect(
        processList: processList,
        desktop: probeDesktop
    )

    #expect(observation.transport == .unknown)
    #expect(observation.listenerURL == "ws://127.0.0.1:4500")
}

@Test func duplicateListenerArgumentsFailClosed() {
    let processList = """
      101   100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server --listen unix:///tmp/a.sock --listen=unix:///tmp/b.sock
    """

    #expect(throws: CodexDesktopProcessProbeError.conflictingTransportArguments) {
        try CodexDesktopProcessProbe().inspect(
            processList: processList,
            desktop: probeDesktop
        )
    }
}

@Test func explicitStdioListenerRemainsNonAttachable() throws {
    let processList = """
      101   100 /Applications/Codex Renamed.app/Contents/Resources/codex app-server --listen stdio://
    """

    let observation = try CodexDesktopProcessProbe().inspect(
        processList: processList,
        desktop: probeDesktop
    )

    #expect(observation.transport == .stdio)
    #expect(observation.listenerURL == "stdio://")
}
