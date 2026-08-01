import Foundation
import GuardianPhoneCore

enum GuardianSegment: String, CaseIterable, Identifiable {
    case attention = "Attention"
    case active = "Active"
    case recent = "Recent"
    var id: Self { self }
}

enum GuardianConnectionState: Equatable {
    case loading
    case disconnected
    case failed(String)
    case ready
}

struct GuardianTaskItem: Identifiable, Sendable {
    enum Activity: String, Sendable {
        case needsAttention = "Needs attention"
        case active = "Active"
        case recent = "Recent"
    }

    let id: String
    let title: String
    let project: String
    let summary: String
    let activity: Activity
    let updatedAt: Date
    let command: PhoneCommandRecord?
}

struct GuardianOperationItem: Identifiable, Sendable {
    let id: UUID
    let kind: PhoneRemoteOperationKind
    let threadID: String
    let phase: PhoneRemoteOperationPhase
    let createdAt: Date
    let updatedAt: Date
}

struct GuardianCommandHistoryItem: Identifiable, Sendable {
    let id: UUID
    let action: PhoneRemoteCommandAction
    let threadID: String
    let state: PhoneCommandState
    let issuedAt: Date
    let updatedAt: Date
    let outcomeVersion: Int64

    var presentation: PhoneCommandPresentation {
        switch state {
        case .pending: .waitingForGuardian
        case .accepted: .acceptedByGuardian
        case .applied: .applied
        case .failed: .failed
        case .indeterminate: .needsReview
        }
    }
}

struct GuardianPhoneSnapshot: Sendable {
    let tasks: [GuardianTaskItem]
    let capabilities: [PhoneCapability]
    let computerName: String
    let serverGeneration: Int64
    let operationHistory: [GuardianOperationItem]
    let operationHistoryCompleteness: PhoneRemoteOperationHistoryCompleteness
    let operationHistoryTotalCount: Int
    let commandHistory: [GuardianCommandHistoryItem]
    let commandHistoryCompleteness: PhoneRemoteCommandHistoryCompleteness
    let commandHistoryTotalCount: Int

    var operationHistoryIsComplete: Bool {
        operationHistoryCompleteness == .complete
    }

    init(
        tasks: [GuardianTaskItem],
        capabilities: [PhoneCapability],
        computerName: String,
        serverGeneration: Int64,
        operationHistory: [GuardianOperationItem] = [],
        operationHistoryCompleteness: PhoneRemoteOperationHistoryCompleteness = .unavailable,
        operationHistoryTotalCount: Int? = nil,
        commandHistory: [GuardianCommandHistoryItem] = [],
        commandHistoryCompleteness: PhoneRemoteCommandHistoryCompleteness = .unavailable,
        commandHistoryTotalCount: Int? = nil
    ) {
        self.tasks = tasks
        self.capabilities = capabilities
        self.computerName = computerName
        self.serverGeneration = serverGeneration
        self.operationHistory = operationHistory
        self.operationHistoryCompleteness = operationHistoryCompleteness
        self.operationHistoryTotalCount = operationHistoryTotalCount ?? operationHistory.count
        self.commandHistory = commandHistory
        self.commandHistoryCompleteness = commandHistoryCompleteness
        self.commandHistoryTotalCount = commandHistoryTotalCount ?? commandHistory.count
    }
}

enum GuardianSheet: Identifiable {
    case task(GuardianTaskItem)
    case pairing
    case restart(ImpactSnapshot)

    var id: String {
        switch self {
        case let .task(task): "task-\(task.id)"
        case .pairing: "pairing"
        case let .restart(snapshot): "restart-\(snapshot.capturedAt.timeIntervalSince1970)"
        }
    }
}

enum CommandDisplay {
    static func label(for command: PhoneCommandRecord?) -> String? {
        guard let command else { return nil }
        switch command.presentation {
        case .waitingForGuardian: return "Waiting for Guardian"
        case .acceptedByGuardian: return "Accepted by Guardian"
        case .applied: return "Applied"
        case .failed: return "Failed"
        case .needsReview: return "Needs review"
        }
    }
}
