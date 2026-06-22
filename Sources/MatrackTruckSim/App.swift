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
        .defaultSize(width: 1366, height: 854)   // opens fitting 14"/15"/16" laptops; scales down on smaller, fills on larger
    }
}
