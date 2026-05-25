import SwiftUI
import UIKit
import AirDeskProtocol

struct KeyboardInputView: UIViewRepresentable {
    @Binding var isActive: Bool
    @Binding var activeModifiers: Set<String>
    let client: WebSocketClient?
    let inputEnabled: Bool

    func makeUIView(context: Context) -> InvisibleTextField {
        let field = InvisibleTextField()
        field.delegate = context.coordinator
        field.keyboardType = .asciiCapable
        field.returnKeyType = .default
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        field.text = " "
        return field
    }

    func updateUIView(_ view: InvisibleTextField, context: Context) {
        context.coordinator.client = client
        context.coordinator.activeModifiers = $activeModifiers
        context.coordinator.inputEnabled = inputEnabled
        context.coordinator.setActive(isActive && inputEnabled, for: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, activeModifiers: $activeModifiers, inputEnabled: inputEnabled)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var client: WebSocketClient?
        var activeModifiers: Binding<Set<String>>
        var inputEnabled: Bool
        private var desiredActive = false
        private weak var pendingResponderView: InvisibleTextField?
        private let keyUpDelay: TimeInterval = 0.015

        init(client: WebSocketClient?, activeModifiers: Binding<Set<String>>, inputEnabled: Bool) {
            self.client = client
            self.activeModifiers = activeModifiers
            self.inputEnabled = inputEnabled
        }

        func setActive(_ active: Bool, for textField: InvisibleTextField) {
            desiredActive = active
            guard textField.isFirstResponder != active else {
                pendingResponderView = nil
                return
            }
            guard pendingResponderView !== textField else { return }

            pendingResponderView = textField
            DispatchQueue.main.async { [weak self, weak textField] in
                guard let self, let textField else { return }
                self.pendingResponderView = nil

                if self.desiredActive {
                    guard self.inputEnabled, textField.window != nil, !textField.isFirstResponder else { return }
                    textField.becomeFirstResponder()
                } else if textField.isFirstResponder {
                    textField.resignFirstResponder()
                }
            }
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

        func textFieldDidEndEditing(_ textField: UITextField) {
            desiredActive = false
        }

        private func sendKey(keyCode: Int, modifiers: [String]) {
            guard inputEnabled else { return }
            var allMods = modifiers
            let sticky = activeModifiers.wrappedValue
            if !sticky.isEmpty {
                allMods.append(contentsOf: sticky)
                DispatchQueue.main.async { self.activeModifiers.wrappedValue.removeAll() }
            }

            let targetClient = client
            targetClient?.sendKeyboardMessage(KeyboardMessage(keyCode: keyCode, modifiers: allMods, action: "down"))
            DispatchQueue.main.asyncAfter(deadline: .now() + keyUpDelay) {
                targetClient?.sendKeyboardMessage(KeyboardMessage(keyCode: keyCode, modifiers: allMods, action: "up"))
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
