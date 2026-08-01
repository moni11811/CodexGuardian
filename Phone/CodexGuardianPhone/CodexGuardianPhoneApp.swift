import SwiftUI

@main
struct CodexGuardianPhoneApp: App {
    @State private var store = GuardianPhoneStore(service: ProductionGuardianPhoneService())

    var body: some Scene {
        WindowGroup {
            GuardianPhoneRootView(store: store)
        }
    }
}
