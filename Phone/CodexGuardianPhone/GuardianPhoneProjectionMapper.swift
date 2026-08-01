import Foundation
import GuardianPhoneCore

struct GuardianPhoneProjectionMapper {
    func map(_ remote: PhoneRemoteSnapshot) -> GuardianPhoneSnapshot {
        GuardianPhoneSnapshot(
            tasks: remote.tasks.map { task in
                GuardianTaskItem(
                    id: task.threadID,
                    title: task.threadID,
                    project: "Codex",
                    summary: "\(task.state.rawValue) · \(task.reason)",
                    activity: activity(for: task.state),
                    updatedAt: remote.capturedAt,
                    command: nil
                )
            },
            capabilities: capabilities,
            computerName: "Paired Mac",
            serverGeneration: remote.cursor.generation,
            operationHistory: remote.operationHistory
                .sorted(by: Self.newestOperationFirst)
                .map {
                    GuardianOperationItem(
                        id: $0.operationID,
                        kind: $0.kind,
                        threadID: $0.originThreadID,
                        phase: $0.phase,
                        createdAt: $0.createdAt,
                        updatedAt: $0.updatedAt
                    )
                },
            operationHistoryCompleteness: remote.operationHistoryCompleteness,
            operationHistoryTotalCount: remote.operationHistoryTotalCount,
            commandHistory: remote.commandHistory.items.map {
                GuardianCommandHistoryItem(
                    id: $0.outcome.commandID,
                    action: $0.action,
                    threadID: $0.targetThreadID,
                    state: $0.outcome.state,
                    issuedAt: $0.issuedAt,
                    updatedAt: $0.updatedAt,
                    outcomeVersion: $0.outcomeVersion
                )
            },
            commandHistoryCompleteness: remote.commandHistory.completeness,
            commandHistoryTotalCount: remote.commandHistory.totalCount
        )
    }

    private static func newestOperationFirst(
        _ left: PhoneRemoteOperationSnapshot,
        _ right: PhoneRemoteOperationSnapshot
    ) -> Bool {
        if left.updatedAt == right.updatedAt {
            return left.operationID.uuidString > right.operationID.uuidString
        }
        return left.updatedAt > right.updatedAt
    }

    private var capabilities: [PhoneCapability] {
        let actions: [PhoneAction] = [
            .observe,
            .promptAgent,
            .steerAgent,
            .interruptAgent,
            .approve,
            .deny,
            .repair,
            .restartAgent,
            .cancelRecovery,
            .readFiles,
        ]
        return actions.map {
            PhoneCapability(
                action: $0,
                availability: $0 == .observe ? .available : .adapterUnavailable
            )
        }
    }

    private func activity(
        for state: PhoneRemoteTaskState
    ) -> GuardianTaskItem.Activity {
        switch state {
        case .stuck, .waitingUser, .recovering, .unknown:
            .needsAttention
        case .working, .slow, .running:
            .active
        case .finished, .idle:
            .recent
        }
    }
}
