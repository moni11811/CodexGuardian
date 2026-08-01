import GuardianCore
import SwiftUI

struct GuardianDashboardView: View {
    @ObservedObject var model: AppModel
    @State private var selection: GuardianOperatorSection? = .attention

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                sectionRow(.attention, title: "Attention", icon: "exclamationmark.triangle.fill")
                sectionRow(.active, title: "Active", icon: "bolt.fill")
                sectionRow(.recent, title: "Recent", icon: "clock.fill")
            }
            .listStyle(.sidebar)
            .navigationTitle("Guardian")
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                taskList
                Spacer(minLength: 0)
                actions
            }
            .padding(20)
            .navigationTitle(title(for: selection ?? .attention))
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.refreshNow()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .confirmationDialog(
            "Force restart Codex?",
            isPresented: Binding(
                get: { model.forceRestartConfirmationRequested },
                set: { model.forceRestartConfirmationRequested = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("Force Restart Codex", role: .destructive) {
                model.requestManualRecovery()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can stop every running Codex task. Guardian will use the armed recovery path only.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.fill")
                .font(.system(size: 30))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Guardian")
                    .font(.title2.weight(.semibold))
                Text("Recovery status without raw logs")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.daemonStatus, systemImage: daemonStatusIcon)
                .font(.headline)
            Text(model.status)
                .foregroundStyle(.secondary)
            if let readiness = model.readinessNotice {
                Label(readinessText(readiness), systemImage: readinessIcon(readiness))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(readinessColor(readiness))
                    .accessibilityLabel(readinessText(readiness))
            }
            if let capturedAt = model.daemonSnapshotCapturedAt {
                Text("Updated \(capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var taskList: some View {
        let visible = model.tasks(in: selection ?? .attention)
        let showsHistory = selection == .recent
        let history = model.daemonOperationHistory.sorted(by: newestOperationFirst)
        if visible.isEmpty && (!showsHistory || history.isEmpty)
            && (!showsHistory || model.daemonOperationHistoryCompleteness != nil) {
            ContentUnavailableView(
                model.taskInventoryCompleteness == .complete ? "Nothing here" : "Observer not ready",
                systemImage: model.taskInventoryCompleteness == .complete
                    ? "checkmark.shield"
                    : "questionmark.diamond",
                description: Text(model.taskInventoryCompleteness == .complete
                    ? "Guardian has no tasks in this section."
                    : "Destructive automation stays disabled until task inventory is complete.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !visible.isEmpty {
                    Section("Tasks") {
                        ForEach(visible, id: \.threadID) { task in
                            GuardianTaskRow(task: task)
                        }
                    }
                }
                if showsHistory {
                    Section("Recovery history") {
                        if model.daemonOperationHistoryCompleteness == nil {
                            Label(
                                "History unavailable until the daemon sends a complete snapshot",
                                systemImage: "exclamationmark.shield"
                            )
                            .foregroundStyle(.secondary)
                        } else if model.daemonOperationHistoryCompleteness == .truncated {
                            Label(
                                "Showing latest \(history.count) of \(model.daemonOperationHistoryTotalCount)",
                                systemImage: "clock.badge.exclamationmark"
                            )
                            .foregroundStyle(.secondary)
                        }
                        ForEach(history, id: \.operationID) { operation in
                            GuardianOperationHistoryRow(operation: operation)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func newestOperationFirst(
        _ left: GuardianIPCOperationHistoryItem,
        _ right: GuardianIPCOperationHistoryItem
    ) -> Bool {
        if left.updatedAt == right.updatedAt {
            return left.operationID.uuidString > right.operationID.uuidString
        }
        return left.updatedAt > right.updatedAt
    }

    private var actions: some View {
        HStack {
            Label(
                "Automatic restart unavailable",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Live Codex Desktop control is not yet proven, so Guardian fails closed.")
            Spacer()
            Button("Force Restart…", role: .destructive) {
                model.requestForceRestartConfirmation()
            }
            .accessibilityHint("Requires another confirmation before stopping Codex")
        }
    }

    private func sectionRow(
        _ section: GuardianOperatorSection,
        title: String,
        icon: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(model.tasks(in: section).count) tasks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(section)
    }

    private func title(for section: GuardianOperatorSection) -> String {
        switch section {
        case .attention: "Attention"
        case .active: "Active"
        case .recent: "Recent"
        }
    }

    private var daemonStatusIcon: String {
        model.taskInventoryCompleteness == .complete
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
    }

    private func readinessText(_ notice: GuardianOperatorReadinessNotice) -> String {
        switch notice {
        case let .blocked(_, capabilities):
            "Blocked: \(capabilities.joined(separator: ", "))"
        case let .waiting(_, capabilities):
            "Waiting: \(capabilities.joined(separator: ", "))"
        case let .degraded(_, capabilities):
            "Degraded: \(capabilities.joined(separator: ", "))"
        }
    }

    private func readinessIcon(_ notice: GuardianOperatorReadinessNotice) -> String {
        switch notice {
        case .blocked: "xmark.octagon.fill"
        case .waiting: "hourglass"
        case .degraded: "exclamationmark.triangle.fill"
        }
    }

    private func readinessColor(_ notice: GuardianOperatorReadinessNotice) -> Color {
        switch notice {
        case .blocked: .red
        case .waiting, .degraded: .orange
        }
    }
}

private struct GuardianOperationHistoryRow: View {
    let operation: GuardianIPCOperationHistoryItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: operation.kind == .hardRestart
                ? "arrow.clockwise.circle.fill"
                : "paperplane.circle.fill")
                .foregroundStyle(operation.phase.isTerminal ? .green : .blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(operation.kind == .hardRestart ? "Hard recovery" : "Native recovery")
                Text(operation.originThreadID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(operation.phase.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(operation.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension GuardianOperationPhase {
    var isTerminal: Bool {
        switch self {
        case .acknowledged, .failed, .timedOut, .deadLetter:
            true
        case .prepared, .gated, .restartIssued, .desktopStarted, .controlReady,
             .targetLoaded, .continuationSent, .deliveryReceipt, .monitoring,
             .waitingUser:
            false
        }
    }

    var displayName: String {
        switch self {
        case .prepared: "Prepared"
        case .gated: "Safety check"
        case .restartIssued: "Restart issued"
        case .desktopStarted: "Desktop started"
        case .controlReady: "Control ready"
        case .targetLoaded: "Task loaded"
        case .continuationSent: "Continuation sent"
        case .deliveryReceipt: "Delivered"
        case .monitoring: "Monitoring"
        case .waitingUser: "Waiting for you"
        case .acknowledged: "Continued"
        case .failed: "Failed"
        case .timedOut: "Timed out"
        case .deadLetter: "Needs review"
        }
    }
}

private struct GuardianTaskRow: View {
    let task: GuardianIPCTaskSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconStyle)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.threadID)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(task.state.rawValue.replacingOccurrences(of: "User", with: " user"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        "Evidence \(Int(task.confidence * 100))% · expires \(task.expiresAt.formatted(date: .omitted, time: .standard))"
    }

    private var icon: String {
        switch task.state {
        case .waitingUser: "person.crop.circle.badge.exclamationmark"
        case .stuck: "exclamationmark.octagon.fill"
        case .unknown: "questionmark.diamond.fill"
        case .slow: "tortoise.fill"
        case .working, .running: "bolt.fill"
        case .recovering: "cross.case.fill"
        case .idle: "pause.circle.fill"
        case .finished: "checkmark.circle.fill"
        }
    }

    private var iconStyle: Color {
        switch task.state {
        case .waitingUser, .slow: .orange
        case .stuck, .unknown: .red
        case .working, .running, .recovering: .blue
        case .idle, .finished: .green
        }
    }
}
