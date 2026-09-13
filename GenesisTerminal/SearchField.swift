import AppKit
import SwiftUI

struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 13, height: 16)

            BorderlessSearchTextField(text: $text, placeholder: "Search")
                .frame(height: 20)
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .frame(height: ShellMetrics.searchHeight)
        .background {
            Capsule()
                .fill(.quaternary)
        }
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }
}

/// Plain borderless NSTextField. The capsule behind it owns the shape and the
/// SwiftUI magnifier beside it owns the icon, so the cell never lays out an
/// embedded button and text and icon can never collide.
struct BorderlessSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Search terminal tabs")
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Escape clears the query and drops focus.
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let field = control as? NSTextField else { return false }
            text.wrappedValue = ""
            field.stringValue = ""
            field.window?.makeFirstResponder(nil)
            return true
        }
    }
}
