import SwiftUI

@main
struct CodexGuardianApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Codex Guardian", systemImage: "shield.fill") {
            Text(model.status)
            Divider()
            Button("Force Restart Codex Now") {
                model.requestManualRecovery()
            }
            Divider()
            Button("Quit Guardian") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
