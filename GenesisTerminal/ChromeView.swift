import SwiftUI

struct NavigationCapsule: View {
    @ObservedObject var model: TerminalModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ChromeButton(
                symbol: "sidebar.leading",
                help: model.isSidebarVisible ? "Hide sidebar" : "Show sidebar"
            ) {
                withAnimation(.smooth(duration: ShellMetrics.sidebarAnimationDuration)) {
                    model.isSidebarVisible.toggle()
                }
            }

            ChromeDivider()

            ChromeButton(symbol: "chevron.left", help: "Back", isEnabled: model.canGoBack) {
                model.goBack()
            }

            ChromeDivider()

            ChromeButton(symbol: "chevron.right", help: "Forward", isEnabled: model.canGoForward) {
                model.goForward()
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
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.10),
            radius: 14,
            y: 8
        )
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

private struct ChromeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 1, height: 16)
    }
}
