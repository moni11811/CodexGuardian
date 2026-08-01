import SwiftUI

struct GuardianMenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(short(model.daemonStatus))
        Text(short(model.status))
            .foregroundStyle(.secondary)
        Divider()
        Button("Open Guardian") {
            openWindow(id: "guardian-dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") {
            model.refreshNow()
        }
        Button("Force Restart…") {
            openWindow(id: "guardian-dashboard")
            NSApp.activate(ignoringOtherApps: true)
            model.requestForceRestartConfirmation()
        }
        Divider()
        Button("Quit Guardian") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func short(_ value: String) -> String {
        guard value.count > 30 else { return value }
        return String(value.prefix(27)) + "..."
    }
}
