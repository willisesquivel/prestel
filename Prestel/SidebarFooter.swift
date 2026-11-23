import SwiftUI

/// Bottom of the sidebar: conditional rows stacked over the activity / spaces / new-tab bar.
struct SidebarFooter: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject private var updates = UpdateStatus.shared
    let width: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            if let version = updates.readyVersion {
                UpdateReadyRow(version: version, width: width) { updates.restart() }
            }
            SidebarBottomBar(model: model, width: width)
        }
        .frame(width: width)
    }
}

/// Strength of the sidebar's glyph icons: the bell, the + and the tab close X.
enum SidebarIconStyle {
    static let opacity: Double = 0.62
}

private enum FooterMetrics {
    static let barHeight: CGFloat = 32
    static let iconSide: CGFloat = 28
    static let labelGap: CGFloat = 8
}

private struct SidebarBottomBar: View {
    @ObservedObject var model: TerminalModel
    let width: CGFloat

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ActivityToggle(model: model)
                Spacer(minLength: 0)
                NewTabButton { model.newTab() }
            }
            SpaceMenu(model: model)
                .frame(maxWidth: max(0, width - (FooterMetrics.iconSide + FooterMetrics.labelGap) * 2))
        }
        .frame(width: width, height: FooterMetrics.barHeight)
    }
}

private struct FooterIconButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(SidebarIconStyle.opacity))
                .frame(width: FooterMetrics.iconSide, height: FooterMetrics.iconSide)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn ? Color.accentColor.opacity(0.16) : Color.primary.opacity(isHovered ? 0.075 : 0))
                        .animation(.easeInOut(duration: 0.14), value: isHovered)
                        .animation(.easeInOut(duration: 0.16), value: isOn)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Activity

/// Switches the sidebar between the tab list and the activity layout.
private struct ActivityToggle: View {
    @ObservedObject var model: TerminalModel
    @AppStorage(SidebarDefaults.activityView) private var isOn = false

    var body: some View {
        let count = model.activity.count
        FooterIconButton(
            symbol: "bell",
            help: (isOn ? "Turn Off Activity View" : "Turn On Activity View") + " (⌥⌘U)",
            isOn: isOn
        ) {
            isOn.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if count > 0, !isOn {
                Circle()
                    .fill(Color(red: 0.89, green: 0.80, blue: 0.56))
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Activity view")
        .accessibilityValue((isOn ? "On" : "Off") + (count > 0 ? ", \(count) need attention" : ""))
        .accessibilityIdentifier("sidebar-activity")
    }
}

// MARK: - Spaces

private struct SpaceMenu: View {
    @ObservedObject var model: TerminalModel

    var body: some View {
        let controller = AppDelegate.current?.controllers[model.id]
        let active = model.activeSpace
        Menu {
            Picker("Spaces", selection: Binding(
                get: { model.activeSpaceID },
                set: { model.switchSpace(to: $0) }
            )) {
                ForEach(model.spaces) { space in
                    Text(space.name).tag(space.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Space") { model.newSpace() }
            Button("Rename “\(active.name)”…") { controller?.requestRenameSpace(active.id) }
            Button("Close “\(active.name)”") { controller?.requestCloseSpace(active.id) }
                .disabled(model.spaces.count < 2)
        } label: {
            HStack(spacing: 6) {
                Text(active.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.45))
            }
            .frame(height: FooterMetrics.barHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .focusable(false)
        .help("Spaces")
        .accessibilityLabel("Space: \(active.name)")
        .accessibilityIdentifier("sidebar-spaces")
    }
}

private struct NewTabButton: View {
    let action: () -> Void

    var body: some View {
        FooterIconButton(symbol: "plus", help: "New Tab", action: action)
            .accessibilityIdentifier("sidebar-new-tab")
    }
}

// MARK: - Conditional rows

private struct UpdateReadyRow: View {
    let version: String
    let width: CGFloat
    let restart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SidebarTile(symbol: "arrow.down")
            Text("Update ready")
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Restart", action: restart)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .focusable(false)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: ShellMetrics.sidebarRowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.075))
        }
        .help("Prestel \(version) is downloaded. Restart to install it.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar-update-ready")
    }
}
