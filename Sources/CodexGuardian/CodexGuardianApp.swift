import AppKit
import SwiftUI

final class GuardianAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct CodexGuardianApp: App {
    @NSApplicationDelegateAdaptor(GuardianAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Codex Guardian", id: "guardian-dashboard") {
            GuardianDashboardView(model: model)
                .frame(minWidth: 720, minHeight: 500)
        }
        .defaultSize(width: 860, height: 600)

        MenuBarExtra("Codex Guardian", systemImage: "shield.fill") {
            GuardianMenuBarView(model: model)
        }
    }
}
