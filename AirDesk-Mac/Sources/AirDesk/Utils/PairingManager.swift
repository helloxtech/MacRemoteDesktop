import Foundation
import Security
import AirDeskProtocol

final class PairingManager {
    private let defaults = UserDefaults.standard
    private let pairingCodeKey = "airdesk.pairing.currentCode.v1"
    private let trustedClientsKey = "airdesk.pairing.trustedClients.v2"
    private let queue = DispatchQueue(label: "airdesk.pairing")
    private(set) var currentCode: String
    var codeDidChange: ((String) -> Void)?

    private struct TrustedClient: Codable {
        let clientName: String
        let secret: String
        let pairedAt: Date
    }

    init() {
        if let savedCode = defaults.string(forKey: pairingCodeKey),
           Self.isValidCode(savedCode) {
            currentCode = savedCode
        } else {
            currentCode = Self.generateCode()
            defaults.set(currentCode, forKey: pairingCodeKey)
        }
    }

    func authorize(_ message: ConnectMessage) -> PairingStatusMessage {
        queue.sync {
            guard !message.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                AirDeskDiagnostics.shared.record("Rejected client with missing identity: \(message.clientName)")
                return PairingStatusMessage(
                    paired: false,
                    message: "Pairing required. Enter the code shown in the AirDesk Mac menu."
                )
            }

            var trusted = trustedClients()
            if let client = trusted[message.clientID], Self.hasValidProof(message, secret: client.secret) {
                AirDeskDiagnostics.shared.record("Trusted client connected: \(message.clientName)")
                return PairingStatusMessage(paired: true, message: "Paired")
            }

            let submittedCode = message.pairingCode?.filter(\.isNumber) ?? ""
            guard submittedCode == currentCode else {
                AirDeskDiagnostics.shared.record("Rejected unpaired client: \(message.clientName)")
                return PairingStatusMessage(
                    paired: false,
                    message: "Pairing required. Enter the code shown in the AirDesk Mac menu."
                )
            }

            let secret = Self.generateSecret()
            trusted[message.clientID] = TrustedClient(
                clientName: message.clientName,
                secret: secret,
                pairedAt: Date()
            )
            saveTrustedClients(trusted)
            AirDeskDiagnostics.shared.record("Paired new client: \(message.clientName)")
            return PairingStatusMessage(paired: true, message: "Paired", authToken: secret)
        }
    }

    func regenerateCode() {
        queue.sync {
            rotateCodeOnQueue()
        }
    }

    func resetTrustedClients() {
        queue.sync {
            saveTrustedClients([:])
            rotateCodeOnQueue()
            AirDeskDiagnostics.shared.record("Trusted clients reset")
        }
    }

    private func rotateCodeOnQueue() {
        currentCode = Self.generateCode()
        defaults.set(currentCode, forKey: pairingCodeKey)
        let code = currentCode
        DispatchQueue.main.async { [weak self] in
            self?.codeDidChange?(code)
        }
    }

    private func trustedClients() -> [String: TrustedClient] {
        guard let data = defaults.data(forKey: trustedClientsKey),
              let clients = try? JSONDecoder().decode([String: TrustedClient].self, from: data) else {
            return [:]
        }
        return clients
    }

    private func saveTrustedClients(_ clients: [String: TrustedClient]) {
        guard let data = try? JSONEncoder().encode(clients) else { return }
        defaults.set(data, forKey: trustedClientsKey)
    }

    private static func generateCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private static func isValidCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy(\.isNumber)
    }

    private static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
        }
        return "\(UUID().uuidString)-\(UUID().uuidString)"
    }

    private static func hasValidProof(_ message: ConnectMessage, secret: String) -> Bool {
        guard let nonce = message.clientNonce, !nonce.isEmpty,
              let submittedProof = message.authProof, !submittedProof.isEmpty else { return false }
        let expectedProof = AirDeskAuthProof.make(clientID: message.clientID, nonce: nonce, secret: secret)
        return timingSafeEqual(submittedProof, expectedProof)
    }

    private static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
