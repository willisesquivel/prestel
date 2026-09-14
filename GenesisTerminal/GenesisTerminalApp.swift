import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct GenesisTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands { GenesisCommands(app: appDelegate) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var commandRevision = 0
    static weak var current: AppDelegate?
    override init() { super.init(); Self.current = self }
    var keyController: TerminalWindowController? { (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? TerminalWindowController }
    private(set) var controllers: [UUID: TerminalWindowController] = [:]
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        guard !Self.isTesting else { return }
        if controllers.isEmpty { createWindow() }
    }
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }
    @discardableResult
    func createWindow(directory: String = ShellConfiguration.defaultDirectory, restoration: WindowDescriptor? = nil, show: Bool = true) -> TerminalWindowController {
        let controller = TerminalWindowController(model: TerminalModel(directory: directory, restoration: restoration))
        controllers[controller.model.id] = controller
        controller.onClose = { [weak self] id in self?.controllers.removeValue(forKey: id) }
        if show {
            controller.window?.center()
            if let previous = NSApp.keyWindow { controller.window?.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)) }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            DispatchQueue.main.async { controller.focusTerminal() }
        }
        return controller
    }

    @discardableResult
    func createWindow(adopting tab: TerminalSession, near screenPoint: NSPoint) -> TerminalWindowController {
        let controller = TerminalWindowController(model: TerminalModel(adopting: tab))
        controllers[controller.model.id] = controller
        controller.onClose = { [weak self] id in self?.controllers.removeValue(forKey: id) }
        if let window = controller.window {
            var frame = window.frame
            frame.origin = TabInsertionGeometry.originForDetachedWindow(size: frame.size, drop: screenPoint)
            window.setFrame(frame, display: false)
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            DispatchQueue.main.async { controller.focusTerminal() }
        }
        return controller
    }

    func openSettingsTab() {
        if let controller = keyController { controller.model.showSettings() }
        else { createWindow().model.showSettings() }
    }
    @objc func newWindow(_ sender: Any?) {
        createWindow(directory: (NSApp.keyWindow?.windowController as? TerminalWindowController)?.model.selectedTab?.currentDirectory ?? ShellConfiguration.defaultDirectory)
    }
    @objc func newTab(_ sender: Any?) { createWindow() }
    @objc func closeTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }
    @objc func closeTerminalWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }
    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal"
        panel.allowedContentTypes = [.folder]
        if panel.runModal() == .OK, let url = panel.url { openDirectory(url) }
    }
    func openDirectory(_ url: URL) {
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return }
        if let controller = NSApp.keyWindow?.windowController as? TerminalWindowController {
            controller.model.newTab(directory: url.path)
        } else { createWindow(directory: url.path) }
    }
    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(openDirectory) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let controller = controllers.values.first { controller.window?.deminiaturize(nil); controller.showWindow(nil) }
            else { createWindow() }
        }
        return true
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        let active = controllers.values.flatMap { $0.model.tabs }.filter(\.hasActiveJobs)
        guard CloseConfirmation.confirm(tabs: active, action: "Quit Genesis") else { return .terminateCancel }
        quitting = true
        for controller in controllers.values {
            controller.preserveForQuit()
            controller.window?.invalidateRestorableState()
            controller.model.closeAll()
        }
        // Allow asynchronous hangup, PID-safe escalation and reaping to finish before app exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct GenesisSettingsView: View {
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("optionAsMeta") private var optionAsMeta = false
    @AppStorage("startingDirectory") private var directory = ""
    var body: some View {
        Form {
            Section("Terminal") {
                Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...32)
                Toggle("Use Option as Meta", isOn: $optionAsMeta)
                Text("With Meta disabled, Option enters accented and alternate characters using your macOS input source.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("New sessions") {
                TextField("Starting folder", text: $directory, prompt: Text("Home folder"))
                Text("New tabs inherit the current shell’s folder when it is available. Restored tabs start new login shells.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: fontSize) { applyPreferences() }
        .onChange(of: optionAsMeta) { applyPreferences() }
    }
    private func applyPreferences() {
        for window in NSApp.windows {
            (window.windowController as? TerminalWindowController)?.model.tabs.forEach { $0.surface?.applyPreferences() }
        }
    }
}
