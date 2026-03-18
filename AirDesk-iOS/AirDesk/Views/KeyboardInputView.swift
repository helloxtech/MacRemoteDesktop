import SwiftUI
import UIKit

struct KeyboardInputView: UIViewRepresentable {
    @Binding var isActive: Bool
    @Binding var activeModifiers: Set<String>
    let client: WebSocketClient?

    func makeUIView(context: Context) -> InvisibleTextField {
        let field = InvisibleTextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.text = " "
        return field
    }

    func updateUIView(_ view: InvisibleTextField, context: Context) {
        context.coordinator.client = client
        context.coordinator.activeModifiers = $activeModifiers
        if isActive && !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isActive && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(client: client, activeModifiers: $activeModifiers) }

    class Coordinator: NSObject, UITextFieldDelegate {
        var client: WebSocketClient?
        var activeModifiers: Binding<Set<String>>

        init(client: WebSocketClient?, activeModifiers: Binding<Set<String>>) {
            self.client = client
            self.activeModifiers = activeModifiers
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                sendKey(keyCode: 51, modifiers: [])
            } else {
                for char in string {
                    if let (keyCode, mods) = KeyCodeMapper.map(char) {
                        sendKey(keyCode: keyCode, modifiers: mods)
                    }
                }
            }
            textField.text = " "
            return false
        }

        private func sendKey(keyCode: Int, modifiers: [String]) {
            var allMods = modifiers
            let sticky = activeModifiers.wrappedValue
            if !sticky.isEmpty {
                allMods.append(contentsOf: sticky)
                DispatchQueue.main.async { self.activeModifiers.wrappedValue.removeAll() }
            }

            client?.sendKeyboardMessage(KeyboardMessage(keyCode: keyCode, modifiers: allMods, action: "down"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.client?.sendKeyboardMessage(KeyboardMessage(keyCode: keyCode, modifiers: allMods, action: "up"))
            }
        }
    }
}

class InvisibleTextField: UITextField {
    override var canBecomeFirstResponder: Bool { true }
    override var intrinsicContentSize: CGSize { CGSize(width: 1, height: 1) }
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}
