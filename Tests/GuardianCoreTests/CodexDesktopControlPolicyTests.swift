import Testing
@testable import GuardianCore

@Test func desktopPrivateIPCSocketIsNotAppServerControl() {
    let evidence = CodexDesktopControlEvidence(
        desktopProcessID: 22_091,
        appServerProcessID: 22_468,
        appServerParentProcessID: 22_091,
        transport: .stdio,
        socketOwnerProcessID: 22_091,
        schemaSupported: true,
        inventory: .unavailable,
        desktopUISynchronizationProven: false,
        correlatedMessagePersistenceProven: false
    )

    #expect(CodexDesktopControlPolicy().mode(for: evidence) ==
        .unavailable(.noSupportedControlListener))
}

@Test func supportedListenerStaysObserveOnlyUntilWriteProofCompletes() {
    let evidence = CodexDesktopControlEvidence(
        desktopProcessID: 100,
        appServerProcessID: 101,
        appServerParentProcessID: 100,
        transport: .unixSocket,
        socketOwnerProcessID: 101,
        schemaSupported: true,
        inventory: .complete,
        desktopUISynchronizationProven: true,
        correlatedMessagePersistenceProven: false
    )

    #expect(CodexDesktopControlPolicy().mode(for: evidence) == .observeOnly)
}

@Test func exactDesktopControlRequiresEveryGate() {
    let evidence = CodexDesktopControlEvidence(
        desktopProcessID: 100,
        appServerProcessID: 101,
        appServerParentProcessID: 100,
        transport: .unixSocket,
        socketOwnerProcessID: 101,
        schemaSupported: true,
        inventory: .complete,
        desktopUISynchronizationProven: true,
        correlatedMessagePersistenceProven: true
    )

    #expect(CodexDesktopControlPolicy().mode(for: evidence) == .readWrite)
}

@Test func partialInventoryNeverAuthorizesWrites() {
    let evidence = CodexDesktopControlEvidence(
        desktopProcessID: 100,
        appServerProcessID: 101,
        appServerParentProcessID: 100,
        transport: .unixSocket,
        socketOwnerProcessID: 101,
        schemaSupported: true,
        inventory: .partial,
        desktopUISynchronizationProven: true,
        correlatedMessagePersistenceProven: true
    )

    #expect(CodexDesktopControlPolicy().mode(for: evidence) == .observeOnly)
}
