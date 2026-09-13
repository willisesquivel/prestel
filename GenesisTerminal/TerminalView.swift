import SwiftUI

/// Mock terminal rendered inside the inset detail surface. Real PTY output
/// will replace `MockTerminalSession` without changing this view's chrome.
struct TerminalView: View {
    @ObservedObject var model: TerminalModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        if model.isShowingSettings {
            SettingsPlaceholder()
        } else if let session = model.selectedSession {
            VStack(spacing: 0) {
                header(session: session)
                Divider().opacity(0.35)
                transcript(session: session)
                inputBar(session: session)
            }
            .onChange(of: model.selection) { draft = "" }
        } else {
            unavailable
        }
    }

    // MARK: Header — sits below the floating nav capsule.

    private func header(session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            SidebarTile(symbol: "terminal", size: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("zsh — \(session.cwd)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Clear") { model.clearCurrent() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .help("Clear this tab's mock buffer")

            Text("MOCK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                }
                .help("No PTY yet — output is canned")
        }
        .padding(.horizontal, 16)
        .padding(.top, 54)
        .padding(.bottom, 10)
    }

    // MARK: Transcript

    private func transcript(session: TerminalSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let buffer = model.buffer(for: session.id) {
                        ForEach(buffer.lines) { line in
                            TerminalLineView(line: line)
                                .id(line.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .textSelection(.enabled)
            }
            .onChange(of: model.buffer(for: session.id)?.lines.count ?? 0) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Input

    private func inputBar(session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            Text(model.promptPrefix(for: session))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.18, green: 0.80, blue: 0.44))
                .lineLimit(1)

            TextField("type `help` — mock, nothing executes", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                .focused($inputFocused)
                .onSubmit {
                    model.submit(command: draft)
                    draft = ""
                }

            if !draft.isEmpty {
                Button(action: {
                    model.submit(command: draft)
                    draft = ""
                }) {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Run (mock)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var unavailable: some View {
        VStack {
            Spacer()
            Text("No session")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct SettingsPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            SidebarTile(symbol: "gearshape.fill", size: 40)
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
            Text("Settings UI lands in a later pass — sidebar + shell come first.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

private struct TerminalLineView: View {
    let line: TerminalLine
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        lineText
            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var lineText: Text {
        if line.segments.allSatisfy({ $0.text.isEmpty }) {
            return Text(" ")
        }
        var attr = AttributedString()
        for seg in line.segments {
            var run = AttributedString(seg.text)
            run.foregroundColor = seg.color.swiftUIColor(isDark: colorScheme == .dark)
            if seg.bold {
                run.inlinePresentationIntent = .stronglyEmphasized
            }
            attr.append(run)
        }
        return Text(attr)
    }
}
