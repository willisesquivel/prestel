import AppKit
import SwiftUI

struct GenesisCommands: Commands {
    @ObservedObject var app: AppDelegate
    var body: some Commands {
        let _ = app.commandRevision
        let window = app.keyController
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.openSettingsTab() }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { app.newWindow(nil) }.keyboardShortcut("n")
            Button("New Tab") {
                if let window = app.keyController { window.newTab(nil) } else { app.newTab(nil) }
            }.keyboardShortcut("t")
            Button("Open Folder…") { app.openFolder(nil) }.keyboardShortcut("o")
            Button("Reopen Closed Tab") { app.keyController?.reopenClosedTab(nil) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(window?.model.recentlyClosed.isEmpty != false)
            Divider()
            Button("Close Tab") {
                if let window = app.keyController { window.closeTab(nil) } else { app.closeTab(nil) }
            }.keyboardShortcut("w").disabled(NSApp.keyWindow == nil)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(NSApp.keyWindow == nil)
        }
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(before: .toolbar) {
            Button("Toggle Sidebar") { app.keyController?.toggleSidebar(nil) }
                .keyboardShortcut("s", modifiers: [.command, .control]).disabled(window == nil)
            Button("Next Tab") { app.keyController?.nextTab(nil) }
                .keyboardShortcut(.tab, modifiers: [.control]).disabled((window?.model.tabs.count ?? 0) < 2)
            Button("Previous Tab") { app.keyController?.previousTab(nil) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled((window?.model.tabs.count ?? 0) < 2)
            Button("Clear Scrollback") { app.keyController?.clearScrollback(nil) }
                .keyboardShortcut("k").disabled(window?.model.selectedTab?.kind != .terminal)
        }
    }
}

@MainActor
enum CloseConfirmation {
    static func confirm(tabs: [TerminalSession], action: String) -> Bool {
        guard !tabs.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(action)?"
        let names = tabs.prefix(4).map(\.title).joined(separator: ", ")
        alert.informativeText = "Running processes in \(names) will be terminated. Unsaved work in these sessions may be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }
}

// NOTE: The floating navigation capsule was intentionally removed. Window
// controls are the native titlebar buttons; sidebar toggle, tab cycling and
// history live in the menu bar and keyboard shortcuts (see GenesisCommands).
