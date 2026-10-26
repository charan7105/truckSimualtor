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
    /// Shared with ContentView through UserDefaults, so the choice survives a relaunch.
    @AppStorage("uiZoom") private var uiZoom: Double = 1.0

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sim)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // The whole face is scaled to fit the window, so on a laptop every label renders below
            // its nominal size. macOS has no Dynamic Type to opt into; this is the equivalent.
            CommandGroup(after: .sidebar) {
                // Bound to "=" like Safari, Preview and Finder: it is the key people actually press
                // for ⌘+, and it fires without needing Shift. "+" alone did not register.
                Button("Zoom In") { uiZoom = min(2.0, uiZoom + 0.1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { uiZoom = max(1.0, uiZoom - 0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { uiZoom = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
        }
    }
}
