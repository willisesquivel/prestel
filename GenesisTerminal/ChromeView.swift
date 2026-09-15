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
            Button(window?.model.reviewVisible == true ? "Hide Code Review" : "Show Code Review") {
                app.keyController?.toggleCodeReview(nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            .disabled(window == nil && window?.model.reviewVisible != true)
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

// NOTE: Window controls are the native titlebar buttons plus the floating
// navigation capsule below. Sidebar toggle, tab cycling and history also
// live in the menu bar and keyboard shortcuts (see GenesisCommands).

struct NavigationCapsule: View {
    @ObservedObject var model: TerminalModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ChromeButton(
                symbol: "sidebar.leading",
                help: model.sidebarVisible ? "Hide sidebar" : "Show sidebar"
            ) {
                ShellPanelAnimation.run {
                    model.sidebarVisible.toggle()
                }
            }

            ChromeDivider()

            ChromeButton(symbol: "chevron.left", help: "Back", isEnabled: model.canGoBack) {
                model.navigate(-1)
            }

            ChromeDivider()

            ChromeButton(symbol: "chevron.right", help: "Forward", isEnabled: model.canGoForward) {
                model.navigate(1)
            }
        }
        .frame(width: ShellMetrics.navigationWidth, height: ShellMetrics.navigationHeight)
        .background {
            Capsule().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.26)
                    : Color.white.opacity(0.30)
            )
        }
        .glassEffect(.regular, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.48),
                lineWidth: 0.5
            )
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ChromeButton: View {
    let symbol: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.primary.opacity(0.72) : Color.primary.opacity(0.17))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct CodeReviewToggle: View {
    @ObservedObject var model: TerminalModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            ShellPanelAnimation.run { model.reviewVisible.toggle() }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: ShellMetrics.reviewToggleWidth, height: ShellMetrics.navigationHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            Capsule().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.26)
                    : Color.white.opacity(0.30)
            )
        }
        .glassEffect(.regular, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.48),
                lineWidth: 0.5
            )
        }
        .focusable(false)
        .help(model.reviewVisible ? "Hide Code Review" : "Show Code Review")
        .accessibilityLabel("Code Review")
        .accessibilityValue(model.reviewVisible ? "on" : "off")
        .accessibilityAddTraits(model.reviewVisible ? [.isSelected] : [])
    }
}

private struct ChromeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 1, height: 16)
    }
}
