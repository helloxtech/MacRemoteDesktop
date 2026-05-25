import SwiftUI
import UIKit
import RoyalVNCKit

struct VNCKeyboardInputView: UIViewRepresentable {
    @Binding var isActive: Bool
    @Binding var activeModifiers: Set<String>
    let session: VNCSessionController?
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
        context.coordinator.session = session
        context.coordinator.activeModifiers = $activeModifiers
        context.coordinator.inputEnabled = inputEnabled
        context.coordinator.setActive(isActive && inputEnabled, for: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, activeModifiers: $activeModifiers, inputEnabled: inputEnabled)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var session: VNCSessionController?
        var activeModifiers: Binding<Set<String>>
        var inputEnabled: Bool
        private var desiredActive = false
        private weak var pendingResponderView: InvisibleTextField?

        init(session: VNCSessionController?, activeModifiers: Binding<Set<String>>, inputEnabled: Bool) {
            self.session = session
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
                sendKey(.delete)
            } else {
                for keyCode in VNCKeyCode.keyCodesFrom(characters: string) {
                    sendKey(keyCode)
                }
            }
            textField.text = " "
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            desiredActive = false
        }

        private func sendKey(_ keyCode: VNCKeyCode) {
            guard inputEnabled else { return }
            let modifiers = modifierKeyCodes(from: activeModifiers.wrappedValue)
            session?.sendKeyPress(keyCode, modifiers: modifiers)
            if !activeModifiers.wrappedValue.isEmpty {
                DispatchQueue.main.async {
                    self.activeModifiers.wrappedValue.removeAll()
                }
            }
        }

        private func modifierKeyCodes(from activeModifiers: Set<String>) -> [VNCKeyCode] {
            var keyCodes: [VNCKeyCode] = []
            if activeModifiers.contains("cmd") { keyCodes.append(.command) }
            if activeModifiers.contains("ctrl") { keyCodes.append(.control) }
            if activeModifiers.contains("opt") { keyCodes.append(.option) }
            if activeModifiers.contains("shift") { keyCodes.append(.shift) }
            return keyCodes
        }
    }
}
