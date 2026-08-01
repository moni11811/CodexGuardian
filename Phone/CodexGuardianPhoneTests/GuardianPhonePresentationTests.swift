import GuardianPhoneCore
import Testing
@testable import CodexGuardianPhone

struct GuardianPhonePresentationTests {
    @Test func pendingCommandNeverLooksApplied() {
        let command = PhoneCommandRecord(
            id: OperationID("pending"),
            action: .restartAgent,
            state: .pending,
            createdAt: .now
        )
        #expect(CommandDisplay.label(for: command) == "Waiting for Guardian")
        #expect(CommandDisplay.label(for: command) != "Applied")
    }
}
