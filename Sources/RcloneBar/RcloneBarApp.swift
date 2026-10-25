import SwiftUI
import AppKit
import RcloneBarCore

@main
struct RcloneBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(snapshot: model.snapshot, showSpeed: model.settings.showSpeedInMenuBar)
        }
        .menuBarExtraStyle(.window)

        Window("RcloneBar 设置", id: WindowID.settings) {
            SettingsView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 500)
        }
        .windowResizability(.contentMinSize)

        Window("运行记录", id: WindowID.history) {
            HistoryView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
    }
}

enum WindowID {
    static let settings = "settings"
    static let history = "history"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist 已设置 LSUIElement，这里再确保不显示 Dock 图标
        NSApp.setActivationPolicy(.accessory)
        if PreviewRenderer.isRequested {
            Task { @MainActor in
                PreviewRenderer.renderAll()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
