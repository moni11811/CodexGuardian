import Foundation

public struct RecoveryPromptPolicy: Sendable {
    public init() {}

    public func select(generated: String, fallback: String) -> String {
        let prompt = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              prompt.count <= 1_200,
              !prompt.contains("{"),
              !prompt.contains("}"),
              !prompt.localizedCaseInsensitiveContains("tool_call"),
              !prompt.localizedCaseInsensitiveContains("function_call") else {
            return fallback
        }
        return prompt
    }
}
