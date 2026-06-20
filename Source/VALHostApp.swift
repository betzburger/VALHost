import SwiftUI
import AppKit

@main
struct VALHostApp: App {
    init() {
        // Force the app to run as a standard foreground application
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        // Initialize JUCE C++ Engine and its Cocoa wrapper
        VALHostEngine.sharedInstance().initializeEngine()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .navigationTitle("VALHost")
        }
        .windowStyle(.titleBar)
    }
}
