import GuardianPhoneCore
import SwiftUI

struct GuardianPhoneRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    let store: GuardianPhoneStore

    var body: some View {
        NavigationStack {
            Group {
                switch store.connection {
                case .loading:
                    ProgressView("Checking Guardian…")
                        .accessibilityIdentifier("guardian.loading")
                case .disconnected:
                    unavailable(
                        title: "Guardian is offline",
                        detail: "Pair this iPhone or retry when your Mac is reachable."
                    )
                case let .failed(message):
                    unavailable(title: "Couldn’t load Guardian", detail: message)
                case .ready:
                    dashboard
                }
            }
            .navigationTitle("Guardian")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Codex Guardian shield")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair", systemImage: "qrcode") { store.presentedSheet = .pairing }
                        .accessibilityIdentifier("guardian.pair")
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await store.monitor()
        }
        .sheet(item: Binding(get: { store.presentedSheet }, set: { store.presentedSheet = $0 })) { sheet in
            switch sheet {
            case let .task(task): TaskDetailSheet(task: task)
            case .pairing: PairingSheet(store: store)
            case let .restart(snapshot): RestartConfirmationSheet(store: store, snapshot: snapshot)
            }
        }
        .alert("Guardian couldn’t finish", isPresented: Binding(
            get: { store.operationError != nil },
            set: { if !$0 { store.operationError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(store.operationError ?? "Unknown error") }
    }

    private func unavailable(title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "shield.slash")
        } description: {
            Text(detail)
        } actions: {
            HStack {
                Button("Retry") { Task { await store.load() } }
                Button("Pair") { store.presentedSheet = .pairing }
            }
        }
        .accessibilityIdentifier("guardian.unavailable")
    }

    private var dashboard: some View {
        VStack(spacing: 12) {
            HStack {
                Label(store.computerName, systemImage: "desktopcomputer")
                Spacer()
                Text("Connected").foregroundStyle(.green)
            }
            .font(.subheadline)
            .padding(.horizontal)

            Picker("Tasks", selection: Binding(
                get: { store.selectedSegment }, set: { store.selectedSegment = $0 }
            )) {
                ForEach(GuardianSegment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .accessibilityIdentifier("guardian.taskFilter")

            List {
                if !store.visibleTasks.isEmpty {
                    Section("Tasks") {
                        ForEach(store.visibleTasks) { task in
                            Button { store.select(task) } label: { TaskRow(task: task) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("guardian.task.\(task.id)")
                        }
                    }
                }
                if store.selectedSegment == .recent {
                    Section("Recovery history") {
                        if store.operationHistoryCompleteness == .unavailable {
                            Label(
                                "History unavailable until Guardian sends a complete snapshot",
                                systemImage: "exclamationmark.shield"
                            )
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("guardian.history.incomplete")
                        } else if store.operationHistoryCompleteness == .truncated {
                            Label(
                                "Showing latest \(store.operationHistory.count) of \(store.operationHistoryTotalCount)",
                                systemImage: "clock.badge.exclamationmark"
                            )
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("guardian.history.truncated")
                        }
                        ForEach(store.operationHistory) { operation in
                            OperationHistoryRow(operation: operation)
                                .accessibilityIdentifier("guardian.history.\(operation.id.uuidString)")
                        }
                    }
                    Section("Command history") {
                        if store.commandHistoryCompleteness == .unavailable {
                            Label(
                                store.commandHistory.isEmpty
                                    ? "Command history unavailable from this Guardian"
                                    : "Full history unavailable; showing durable entries",
                                systemImage: "exclamationmark.shield"
                            )
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("guardian.commandHistory.unavailable")
                        } else if store.commandHistoryCompleteness == .truncated {
                            Label(
                                "Showing latest \(store.commandHistory.count) of \(store.commandHistoryTotalCount)",
                                systemImage: "clock.badge.exclamationmark"
                            )
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("guardian.commandHistory.truncated")
                        }
                        ForEach(store.commandHistory) { command in
                            CommandHistoryRow(command: command)
                                .accessibilityIdentifier("guardian.commandHistory.\(command.id.uuidString)")
                        }
                    }
                }
            }
            .overlay {
                if store.visibleTasks.isEmpty
                    && (store.selectedSegment != .recent || (
                        store.operationHistory.isEmpty
                            && store.commandHistory.isEmpty
                            && store.operationHistoryCompleteness == .complete
                            && store.commandHistoryCompleteness == .complete
                    )) {
                    ContentUnavailableView("Nothing here", systemImage: "checkmark.shield")
                }
            }

            VStack(spacing: 8) {
                if let selectedTask = store.selectedTask {
                    Label("Controlling: \(selectedTask.title)", systemImage: "scope")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("guardian.selectedTask")
                } else {
                    Label("Select one task first", systemImage: "scope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField("Tell the agent what to do next", text: Binding(
                    get: { store.prompt }, set: { store.prompt = $0 }
                ), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("guardian.prompt")
                HStack {
                    Button("Send prompt", systemImage: "paperplane.fill") {
                        Task { await store.sendPrompt() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.can(.promptAgent) || store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isWorking)
                    .accessibilityHint(store.can(.promptAgent) ? "Sends this prompt to the selected agent" : "Unavailable because the Mac adapter is not ready")

                    Spacer()

                    Button("Restart safely", systemImage: "arrow.clockwise", role: .destructive) {
                        Task { await store.prepareRestart() }
                    }
                    .disabled(!store.can(.restartAgent) || store.isWorking)
                    .accessibilityIdentifier("guardian.restart.prepare")
                    .accessibilityHint("Checks every active task and uncommitted workspace before asking for confirmation")
                }
            }
            .padding([.horizontal, .bottom])
        }
    }
}

private struct OperationHistoryRow: View {
    let operation: GuardianOperationItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: operation.kind == .hardRestart
                ? "arrow.clockwise.circle.fill"
                : "paperplane.circle.fill")
                .foregroundStyle(operation.phase.isTerminal ? .green : .blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(operation.kind == .hardRestart ? "Hard recovery" : "Native recovery")
                    .font(.headline)
                Text(operation.threadID)
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

private struct CommandHistoryRow: View {
    let command: GuardianCommandHistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: command.presentation.symbolName)
                .foregroundStyle(command.presentation.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(command.action.displayName)
                    .font(.headline)
                Text(command.threadID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(command.presentation.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(command.presentation.color)
            }
            Spacer()
            Text(command.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension PhoneRemoteCommandAction {
    var displayName: String {
        switch self {
        case .observe: "Observe"
        case .prompt: "Prompt"
        case .steer: "Steer"
        case .interrupt: "Interrupt"
        case .approve: "Approve"
        case .deny: "Deny"
        case .repair: "Repair"
        case .hardRecover: "Safe recovery"
        case .cancelRecovery: "Cancel recovery"
        case .readFiles: "Read files"
        case .openTerminal: "Open terminal"
        }
    }
}

private extension PhoneCommandPresentation {
    var displayName: String {
        switch self {
        case .waitingForGuardian: "Waiting for Guardian"
        case .acceptedByGuardian: "Accepted by Guardian"
        case .applied: "Applied"
        case .failed: "Failed"
        case .needsReview: "Needs review"
        }
    }

    var symbolName: String {
        switch self {
        case .waitingForGuardian: "clock"
        case .acceptedByGuardian: "tray.and.arrow.down.fill"
        case .applied: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .needsReview: "questionmark.diamond.fill"
        }
    }

    var color: Color {
        switch self {
        case .waitingForGuardian: .secondary
        case .acceptedByGuardian: .blue
        case .applied: .green
        case .failed: .red
        case .needsReview: .orange
        }
    }
}

private extension PhoneRemoteOperationPhase {
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

private struct TaskRow: View {
    let task: GuardianTaskItem
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: task.activity == .needsAttention ? "exclamationmark.shield.fill" : "shield")
                .foregroundStyle(task.activity == .needsAttention ? .orange : .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.headline)
                Text(task.project).font(.caption).foregroundStyle(.secondary)
                if let state = CommandDisplay.label(for: task.command) {
                    Text(state).font(.caption2).foregroundStyle(state == "Applied" ? .green : .secondary)
                        .accessibilityLabel("Command status: \(state)")
                }
            }
            Spacer()
            Text(task.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct TaskDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let task: GuardianTaskItem
    var body: some View {
        NavigationStack {
            List {
                Section("Task") { LabeledContent("Project", value: task.project); Text(task.summary) }
                Section("State") {
                    LabeledContent("Activity", value: task.activity.rawValue)
                    if let state = CommandDisplay.label(for: task.command) { LabeledContent("Command", value: state) }
                }
            }
            .navigationTitle(task.title)
            .toolbar { Button("Done") { dismiss() } }
        }
        .accessibilityIdentifier("guardian.taskDetail")
    }
}

private struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: GuardianPhoneStore
    @State private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 72)).frame(maxWidth: .infinity)
                        .accessibilityLabel("QR pairing code entry")
                    TextField("Paste or enter QR pairing code", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("guardian.pair.code")
                } footer: { Text("The code stays on this device. Camera scanning will use this same field when transport ships.") }
            }
            .navigationTitle("Pair with Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") { Task { if await store.pair(code: code) { dismiss() } } }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isWorking)
                }
            }
        }
    }
}

private struct RestartConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: GuardianPhoneStore
    let snapshot: ImpactSnapshot
    var body: some View {
        NavigationStack {
            Form {
                Section("Fresh impact check") {
                    LabeledContent("Captured", value: snapshot.capturedAt.formatted(date: .omitted, time: .standard))
                    LabeledContent("Server generation", value: "\(snapshot.serverGeneration)")
                    LabeledContent("Completeness", value: snapshot.completeness.rawValue.capitalized)
                    if case let .known(activeTasks, workspaces) = snapshot.impact {
                        LabeledContent("Active tasks", value: "\(activeTasks)")
                        LabeledContent("Uncommitted workspaces", value: "\(workspaces)")
                    }
                }
                Section { Text("Restart only after this complete, fresh check. This confirmation does not assume a pending command was applied.") }
            }
            .navigationTitle("Confirm restart")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restart agent", role: .destructive) {
                        Task { if await store.confirmRestart(using: snapshot) { dismiss() } }
                    }
                    .accessibilityIdentifier("guardian.restart.confirm")
                    .disabled(store.isWorking)
                }
            }
        }
    }
}

#Preview("Offline fixtures") {
    GuardianPhoneRootView(store: GuardianPhoneStore(service: PreviewGuardianPhoneService(snapshot: .preview)))
}

#Preview("Disconnected") {
    GuardianPhoneRootView(store: GuardianPhoneStore(service: ProductionGuardianPhoneService()))
}
