import Foundation

public struct RecoveryPromptPolicy: Sendable {
    public init() {}

    public func select(generated: String, fallback: String) -> String {
        let prompt = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbiddenControlTerms = [
            "restart_codex",
            "prepare_restart",
            "prepare_recovery",
            "recovery_tick",
            "ack_recovery",
            "continuation_automation_id",
            "origin_token",
            "codex exec resume",
        ]
        guard !prompt.isEmpty,
              prompt.count <= 1_200,
              !prompt.contains("{"),
              !prompt.contains("}"),
              !prompt.localizedCaseInsensitiveContains("tool_call"),
              !prompt.localizedCaseInsensitiveContains("function_call"),
              !forbiddenControlTerms.contains(where: {
                prompt.localizedCaseInsensitiveContains($0)
              }) else {
            return fallback
        }
        return prompt
    }
}
