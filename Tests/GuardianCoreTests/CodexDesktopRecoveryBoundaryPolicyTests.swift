import Testing
@testable import GuardianCore

struct CodexDesktopRecoveryBoundaryPolicyTests {
    @Test func absentDesktopIsLaunchedWithoutADestructiveRestartGate() {
        #expect(CodexDesktopRecoveryBoundaryPolicy().decision(
            desktopIsRunning: false,
            nativeDeliveryFailed: false,
            inventoryIsAuthoritativeAndSafe: false
        ) == .launchBeforeNativeRecovery)
    }

    @Test func runningDesktopWithUnknownTaskInventoryCannotBeKilledAutomatically() {
        #expect(CodexDesktopRecoveryBoundaryPolicy().decision(
            desktopIsRunning: true,
            nativeDeliveryFailed: true,
            inventoryIsAuthoritativeAndSafe: false
        ) == .humanForceRequired)
    }

    @Test func nativeRecoveryRemainsSmallestRepairWhileDesktopRuns() {
        #expect(CodexDesktopRecoveryBoundaryPolicy().decision(
            desktopIsRunning: true,
            nativeDeliveryFailed: false,
            inventoryIsAuthoritativeAndSafe: false
        ) == .continueNativeRecovery)
    }
}
