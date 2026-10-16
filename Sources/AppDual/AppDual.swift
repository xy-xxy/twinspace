import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AppDual: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("双栖", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 830, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel() }
        }
        .defaultSize(width: 920, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) { Button("添加应用…") { model.chooseApp() }.keyboardShortcut("o").disabled(model.busy) }
        }
    }
}
