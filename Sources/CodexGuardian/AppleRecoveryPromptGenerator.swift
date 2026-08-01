import Foundation
import GuardianCore

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
private struct GeneratedRecoveryPrompt {
    @Guide(description: "A plain-text continuation instruction. No JSON, tool calls, or markdown.")
    var prompt: String
}

@available(macOS 26.0, *)
struct AppleRecoveryPromptGenerator {
    func generate(snapshot: String, fallback: String) async -> String {
        let sanitizedSnapshot = String(
            RecoveryContextExtractor()
                .sanitize(snapshot, originToken: "")
                .prefix(GuardianAdvisor.maximumInputCharacters)
        )
        guard !sanitizedSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        let context = GuardianAdvisorContext(
            failureFamily: .thread,
            taskState: .recovering,
            blockers: ["Recovery continuation requires a grounded next step."],
            verifiedEvents: [sanitizedSnapshot],
            repairHistory: [],
            diffSummary: nil,
            continuationFallback: fallback,
            evidenceIsComplete: true
        )
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return await GuardianAdvisor(model: nil)
                .advise(for: context).continuationDraft ?? fallback
        }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You recover a stuck coding agent. Write one concise continuation prompt.
            Use only supplied facts. Name the last known task, failure, and one changed next action.
            Never repeat secrets, invent completed work, or claim success. Output only the prompt.
            The desktop restart already happened. Never request another restart, recovery tool,
            heartbeat, origin token, automation, or acknowledgement. Resume project work only.
            """
        )
        do {
            let response = try await session.respond(to: """
                Last sanitized task state:
                \(sanitizedSnapshot)

                Safe fallback if evidence is incomplete:
                \(fallback)
                """, generating: GeneratedRecoveryPrompt.self)
            let candidate = GuardianAdviceCandidate(
                summary: "Verified recovery context is available for continuation.",
                likelyFailureFamily: .thread,
                suggestedDiagnostic: .requestFreshSnapshot,
                continuationDraft: response.content.prompt,
                uncertainty: "The next action is grounded only in the supplied recovery context."
            )
            let advice = await GuardianAdvisor(model: { _ in candidate })
                .advise(for: context)
            return advice.continuationDraft ?? fallback
        } catch {
            return await GuardianAdvisor(model: nil)
                .advise(for: context).continuationDraft ?? fallback
        }
    }
}
#endif
