import SwiftUI

struct MatrackSimApp: App {
    @StateObject private var sim = SimController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sim)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
