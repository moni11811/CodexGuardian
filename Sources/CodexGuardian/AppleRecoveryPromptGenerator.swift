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
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return fallback }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You recover a stuck coding agent. Write one concise continuation prompt.
            Use only supplied facts. Name the last known task, failure, and one changed next action.
            Never repeat secrets, invent completed work, or claim success. Output only the prompt.
            """
        )
        do {
            let response = try await session.respond(to: """
                Last sanitized task state:
                \(snapshot)

                Safe fallback if evidence is incomplete:
                \(fallback)
                """, generating: GeneratedRecoveryPrompt.self)
            return RecoveryPromptPolicy().select(
                generated: response.content.prompt,
                fallback: fallback
            )
        } catch {
            return fallback
        }
    }
}
#endif
