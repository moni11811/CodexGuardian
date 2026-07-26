import Testing
@testable import GuardianCore

@Test func recoveryContextKeepsRecentStateButRemovesSecrets() {
    let origin = "7BBD258F-5BA6-4B2E-BC25-044C252B21A8"
    let fakeCredential = "sk-" + String(repeating: "x", count: 30)
    let rollout = """
    {"type":"response_item","payload":{"role":"user","content":"Fix the restart queue in Sources/GuardianCore/RestartRequest.swift"}}
    {"type":"response_item","payload":{"role":"assistant","content":"I found concurrent requests overwrite pending-restart.json"}}
    {"type":"response_item","payload":{"role":"tool","content":"OPENAI_API_KEY=\(fakeCredential)"}}
    {"type":"response_item","payload":{"role":"assistant","content":"Calling restart_codex with origin (origin)"}}
    """

    let snapshot = RecoveryContextExtractor().extract(from: rollout, originToken: origin)

    #expect(snapshot.contains("RestartRequest.swift"))
    #expect(snapshot.contains("concurrent requests overwrite"))
    #expect(!snapshot.contains(origin))
    #expect(!snapshot.contains(fakeCredential))
    #expect(snapshot.count <= RecoveryContextExtractor.maximumCharacters)
}

@Test func recoveryPromptSanitizerRemovesCredentialsAndPersonalPaths() {
    let credential = "sk-" + String(repeating: "z", count: 30)
    let personalPath = "/" + "Users/" + "PrivateName/project"
    let prompt = "Retry with \(credential) from \(personalPath)"

    let sanitized = RecoveryContextExtractor().sanitize(prompt, originToken: "")

    #expect(!sanitized.contains(credential))
    #expect(!sanitized.contains("PrivateName"))
    #expect(sanitized.contains("[REDACTED]"))
    #expect(sanitized.contains("/Users/[USER]"))
}
