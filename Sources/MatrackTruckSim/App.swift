import SwiftUI

/// Promotes the process to a regular, windowed app the instant it launches — even when run as a
/// bare executable (`.build/debug/MatrackTruckSim`) instead of a `.app` bundle. Without this the
/// app can come up as a background accessory (no Dock tile, no on-screen window), so the window
/// never renders and `ContentView.onAppear` never fires (no BLE, no drive, no LAN feed).
final class AppLifecycle: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MatrackSimApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
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
