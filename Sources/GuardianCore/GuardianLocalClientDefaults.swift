import Foundation

public enum GuardianLocalClientDefaults {
    public static let macUIID = UUID(
        uuidString: "C0D00000-0000-0000-0000-000000000001"
    )!
    public static let mcpID = UUID(
        uuidString: "C0D00000-0000-0000-0000-000000000002"
    )!
    public static let cliID = UUID(
        uuidString: "C0D00000-0000-0000-0000-000000000003"
    )!

    public static func maximumCapabilities(
        for role: GuardianIPCClientRole
    ) -> GuardianIPCCapabilities {
        switch role {
        case .macUI:
            [.observe, .nativeRecovery, .hardRecovery, .crossThreadControl, .forceRestart]
        case .mcp:
            [.observe, .nativeRecovery, .hardRecovery]
        case .cli, .remoteGateway:
            [.observe]
        }
    }
}
