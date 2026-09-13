import AppKit
import SwiftUI

struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        NativeSearchField(text: $text)
            .frame(height: ShellMetrics.searchHeight)
            .background {
                Capsule()
                    .fill(.quaternary)
            }
            .clipShape(Capsule())
            .accessibilityElement(children: .contain)
    }
}

/// Real NSSearchField (native editor, cancel button, accessibility role, undo)
/// in the same borderless capsule. No custom bezel drawing — the capsule
/// behind it owns the shape.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchAction(_:))
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search terminal tabs")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func searchAction(_ sender: NSSearchField) {
            // Covers Enter and the cancel button (which clears the field).
            text.wrappedValue = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
