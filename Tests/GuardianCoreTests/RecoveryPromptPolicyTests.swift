import Testing
@testable import GuardianCore

@Test func inventedToolCallFallsBackToKnownSafePrompt() {
    let fallback = RestartRequest.defaultPrompt
    let invented = #"{"instruction":"continue","tool_call":{"name":"get_available_storage_configurations"}}"#

    #expect(RecoveryPromptPolicy().select(generated: invented, fallback: fallback) == fallback)
}

@Test func concisePlainRecoveryPromptIsAccepted() {
    let fallback = RestartRequest.defaultPrompt
    let generated = "Continue fixing the queue overwrite in RestartRequest.swift. Replace the single pending file with per-request files, then rerun the concurrency test."

    #expect(RecoveryPromptPolicy().select(generated: generated, fallback: fallback) == generated)
}

@Test func recoveryControlCommandFallsBackInsteadOfRestartingAgain() {
    let fallback = "Continue the exact task after recovery."
    let generated = "Run restart_codex with the previous origin token, then verify recovery."

    #expect(RecoveryPromptPolicy().select(generated: generated, fallback: fallback) == fallback)
}
