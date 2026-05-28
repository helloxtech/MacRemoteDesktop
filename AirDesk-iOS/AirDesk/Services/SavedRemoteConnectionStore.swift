import Combine
import Foundation

struct SavedRemoteConnection: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let urlString: String
    let pairingCode: String?
    let lastUsedAt: Date

    init(urlString: String, pairingCode: String?, name: String? = nil, lastUsedAt: Date = Date()) {
        let cleanedURL = Self.cleanedURL(urlString)
        self.id = Self.identifier(for: cleanedURL)
        self.name = Self.displayName(from: name, urlString: cleanedURL)
        self.urlString = cleanedURL
        self.pairingCode = Self.normalizedPairingCode(pairingCode)
        self.lastUsedAt = lastUsedAt
    }

    private static func cleanedURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func identifier(for urlString: String) -> String {
        let valueWithScheme = urlString.contains("://") ? urlString : "https://\(urlString)"
        guard var components = URLComponents(string: valueWithScheme),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return urlString.lowercased()
        }

        switch scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            components.scheme = scheme
        default:
            break
        }

        components.host = host
        return components.string?.lowercased() ?? urlString.lowercased()
    }

    private static func displayName(from name: String?, urlString: String) -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }

        let valueWithScheme = urlString.contains("://") ? urlString : "https://\(urlString)"
        if let host = URLComponents(string: valueWithScheme)?.host, !host.isEmpty {
            return host
        }
        return "Remote Mac"
    }

    private static func normalizedPairingCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return String(digits.prefix(6))
    }
}

final class SavedRemoteConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedRemoteConnection]

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    init(
        defaults: UserDefaults = .standard,
        key: String = "airdesk.remoteAccess.savedConnections.v1",
        limit: Int = 5
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        self.connections = Self.loadConnections(from: defaults, key: key)
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func save(urlString: String, pairingCode: String?, name: String? = nil, now: Date = Date()) {
        let connection = SavedRemoteConnection(
            urlString: urlString,
            pairingCode: pairingCode,
            name: name,
            lastUsedAt: now
        )
        guard !connection.urlString.isEmpty else { return }

        var updated = connections.filter { $0.id != connection.id }
        updated.insert(connection, at: 0)
        connections = Array(updated.prefix(limit))
        persist()
    }

    func remove(_ connection: SavedRemoteConnection) {
        connections.removeAll { $0.id == connection.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadConnections(from defaults: UserDefaults, key: String) -> [SavedRemoteConnection] {
        guard let data = defaults.data(forKey: key),
              let connections = try? JSONDecoder().decode([SavedRemoteConnection].self, from: data) else {
            return []
        }
        return connections
    }
}
