import SwiftUI
import UIKit

struct KeyboardInputView: UIViewRepresentable {
    @Binding var isActive: Bool
    let client: WebSocketClient?

    func makeUIView(context: Context) -> InvisibleTextField {
        let field = InvisibleTextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        return field
    }

    func updateUIView(_ view: InvisibleTextField, context: Context) {
        context.coordinator.client = client
        if isActive && !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isActive && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    class Coordinator: NSObject, UITextFieldDelegate {
        var client: WebSocketClient?

        init(client: WebSocketClient?) { self.client = client }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                // Backspace
                sendKey(keyCode: 51, modifiers: [])
            } else {
                for char in string {
                    if let (keyCode, mods) = KeyCodeMapper.map(char) {
                        sendKey(keyCode: keyCode, modifiers: mods)
                    }
                }
            }
            textField.text = ""
            return false
        }

        private func sendKey(keyCode: Int, modifiers: [String]) {
            client?.sendKeyboardMessage(KeyboardMessage(keyCode: keyCode, modifiers: modifiers, action: "down"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.client?.sendKeyboardMessage(KeyboardMessage(keyCode: keyCode, modifiers: modifiers, action: "up"))
            }
        }
    }
}

class InvisibleTextField: UITextField {
    override var intrinsicContentSize: CGSize { .zero }
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}
