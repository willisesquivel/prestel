import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PrestelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands { PrestelCommands(app: appDelegate) }
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
        PrestelAppearance.apply(UserDefaults.standard.string(forKey: "appearanceMode") ?? "system")
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
        createWindow(adopting: [tab], selectedID: tab.id, near: screenPoint)
    }

    @discardableResult
    func createWindow(adopting tabs: [TerminalSession], selectedID: UUID?, near screenPoint: NSPoint) -> TerminalWindowController {
        let controller = TerminalWindowController(model: TerminalModel(adopting: tabs, selectedID: selectedID))
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
        guard CloseConfirmation.confirm(tabs: active, action: "Quit Prestel") else { return .terminateCancel }
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

@MainActor
enum PrestelAppearance {
    static func apply(_ mode: String) {
        switch mode {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
        if let app = AppDelegate.current {
            for controller in app.controllers.values {
                controller.model.allSessions.forEach { $0.surface?.refreshColorsForCurrentAppearance() }
            }
        }
    }
}

struct PrestelSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("optionAsMeta") private var optionAsMeta = false
    @AppStorage("startingDirectory") private var directory = ""
    @AppStorage("openSidebarInNewWindows") private var openSidebarInNewWindows = true
    @AppStorage("reviewExpandFilesByDefault") private var expandReviewFiles = false

    var body: some View {
        GeometryReader { proxy in
            let compactAppearancePicker = proxy.size.width < 620
            let stacksControls = proxy.size.width < 440
            let horizontalInset: CGFloat = compactAppearancePicker ? 20 : 28
            let contentWidth = min(720, max(0, proxy.size.width - horizontalInset * 2))

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsContentSection(title: "Appearance") {
                        SettingsContentCard {
                            if compactAppearancePicker {
                                VStack(alignment: .leading, spacing: 14) {
                                    SettingsContentLabel(
                                        title: "Interface appearance",
                                        detail: "Choose a fixed light or dark appearance, or follow your Mac."
                                    )
                                    SettingsAppearancePicker(selection: $appearanceMode, isCompact: true)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            } else {
                                HStack(alignment: .top, spacing: 16) {
                                    SettingsContentLabel(
                                        title: "Interface appearance",
                                        detail: "Choose a fixed light or dark appearance, or follow your Mac."
                                    )
                                    Spacer(minLength: 12)
                                    SettingsAppearancePicker(selection: $appearanceMode, isCompact: false)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                    }

                    SettingsContentSection(title: "Terminal") {
                        SettingsContentCard {
                            SettingsContentRow(title: "Text size", detail: "Changes open terminals without changing the rest of the window", stacksControl: stacksControls) {
                                Stepper("\(Int(fontSize)) pt", value: $fontSize,
                                        in: Double(TerminalFontSize.minimum)...Double(TerminalFontSize.maximum))
                                    .controlSize(.small)
                                    .fixedSize()
                                    .accessibilityIdentifier("terminal-text-size")
                                    .accessibilityValue("\(Int(fontSize)) pt")
                            }
                            SettingsContentDivider()
                            SettingsContentRow(title: "Use Option as Meta", detail: "Send Option as a terminal key instead of typing alternate characters", stacksControl: stacksControls) {
                                Toggle("Use Option as Meta", isOn: $optionAsMeta)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .accessibilityLabel("Use Option as Meta")
                                    .accessibilityIdentifier("option-as-meta")
                                    .accessibilityValue(optionAsMeta ? "on" : "off")
                            }
                        }
                    }

                    SettingsContentSection(title: "New sessions") {
                        SettingsContentCard {
                            SettingsContentRow(
                                title: "Starting folder",
                                detail: "Used when a new window has no folder to inherit from the current terminal",
                                stacksControl: stacksControls
                            ) {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Button("Choose Folder…", action: chooseDirectory)
                                        .controlSize(.small)
                                    Text(selectedDirectoryPath)
                                        .font(.system(.subheadline))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                        .help(selectedDirectoryPath)
                                        .accessibilityIdentifier("starting-folder-path")
                                        .accessibilityLabel("Starting folder: \(selectedDirectoryPath)")
                                        .frame(maxWidth: 180, alignment: .trailing)
                                }
                            }
                        }
                    }

                    SettingsContentSection(title: "Windows") {
                        SettingsContentCard {
                            SettingsContentRow(title: "Open sidebar in new windows", detail: "Restored windows keep their own sidebar state", stacksControl: stacksControls) {
                                Toggle("Open sidebar in new windows", isOn: $openSidebarInNewWindows)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .accessibilityLabel("Open sidebar in new windows")
                                    .accessibilityIdentifier("open-sidebar-in-new-windows")
                                    .accessibilityValue(openSidebarInNewWindows ? "on" : "off")
                            }
                        }
                    }

                    SettingsContentSection(title: "Code review") {
                        SettingsContentCard {
                            SettingsContentRow(title: "Expand files by default", detail: "Show each changed file’s details when opening a review", stacksControl: stacksControls) {
                                Toggle("Expand files by default", isOn: $expandReviewFiles)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .accessibilityLabel("Expand files by default")
                                    .accessibilityIdentifier("expand-files-by-default")
                                    .accessibilityValue(expandReviewFiles ? "on" : "off")
                            }
                        }
                    }
                }
                .frame(maxWidth: contentWidth, alignment: .leading)
                .padding(.horizontal, horizontalInset)
                .padding(.top, 26)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: appearanceMode) { _, mode in PrestelAppearance.apply(mode) }
        .onChange(of: fontSize) { _, _ in TerminalFontSize.applyToOpenTerminals() }
        .onChange(of: optionAsMeta) { _, _ in TerminalFontSize.applyToOpenTerminals() }
        .onChange(of: expandReviewFiles) { _, expanded in
            AppDelegate.current?.controllers.values.forEach { $0.review.expandFilesByDefault = expanded }
        }
    }

    private var selectedDirectoryPath: String {
        directory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : directory
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: selectedDirectoryPath, isDirectory: true)
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let path = panel.url?.path { directory = path }
    }
}

private struct SettingsContentSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.7))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsContentCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SettingsContentLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.body))
            Text(detail)
                .font(.system(.subheadline))
                .foregroundStyle(Color.primary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsContentRow<Control: View>: View {
    let title: String
    let detail: String
    let stacksControl: Bool
    @ViewBuilder let control: Control

    var body: some View {
        Group {
            if stacksControl {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsContentLabel(title: title, detail: detail)
                    HStack {
                        Spacer(minLength: 0)
                        control
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    SettingsContentLabel(title: title, detail: detail)
                    Spacer(minLength: 8)
                    control
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
    }
}

private struct SettingsContentDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

private struct SettingsAppearancePicker: View {
    @Binding var selection: String
    let isCompact: Bool

    var body: some View {
        Group {
            if isCompact {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 80), alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(SettingsAppearanceChoice.allCases) { choice in
                        optionCard(choice)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(SettingsAppearanceChoice.allCases) { choice in
                        optionCard(choice)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
    }

    private func optionCard(_ choice: SettingsAppearanceChoice) -> some View {
        let isSelected = choice.rawValue == selection

        return Button {
            selection = choice.rawValue
        } label: {
            VStack(spacing: 7) {
                SettingsAppearancePreview(choice: choice)
                    .frame(width: 75, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                    }
                    .padding(3)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        }
                    }

                Text(choice.title)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.help)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum SettingsAppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var help: String {
        switch self {
        case .system: "Follow your Mac’s appearance"
        case .light: "Always use the light appearance"
        case .dark: "Always use the dark appearance"
        }
    }

    var imageName: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

private struct SettingsAppearancePreview: View {
    let choice: SettingsAppearanceChoice

    var body: some View {
        Image(choice.imageName)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
    }
}
