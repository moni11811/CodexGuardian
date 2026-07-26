import Testing
@testable import GuardianCore

@Test func hardRestartSelectsOnlyDesktopAppServerHelpers() {
    let processList = """
     1791 /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
     1800 /Applications/ChatGPT.app/Contents/Resources/codex exec resume thread-id
     1900 /usr/bin/grep app-server
     2000 /Applications/Other.app/Contents/Resources/codex app-server
    """
    let policy = CodexAppServerProcessPolicy()

    #expect(policy.processIDsToStop(
        processList: processList,
        applicationPaths: ["/Applications/ChatGPT.app"]
    ) == [1791])
}
