import SwiftUI

@main
struct MeetingTruthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LabStore()

    var body: some Scene {
        WindowGroup("MeetingTruth", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Run Selected Models") {
                    store.runComparison()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Download Selected Model") {
                    store.downloadSelectedModel()
                }
                .keyboardShortcut("d", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(width: 560)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
