import Foundation
import UIKit
import Combine
import AirDeskProtocol

struct DiscoveredHost: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int

    init(name: String, host: String, port: Int) {
        self.name = name
        self.host = host
        self.port = port
        self.id = "\(name)|\(host)|\(port)"
    }
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    case airDesk
    case remoteAccess
    case vnc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airDesk: return "Local"
        case .remoteAccess: return "Remote"
        case .vnc: return "VNC"
        }
    }

    var iconName: String {
        switch self {
        case .airDesk: return "bolt.horizontal.circle"
        case .remoteAccess: return "globe"
        case .vnc: return "rectangle.connected.to.line.below"
        }
    }

    var defaultPort: Int {
        switch self {
        case .airDesk: return 7890
        case .remoteAccess: return 443
        case .vnc: return 5900
        }
    }

    var helperText: String {
        switch self {
        case .airDesk:
            return "Connect to a Mac on the same Wi-Fi using AirDesk streaming and pairing."
        case .remoteAccess:
            return "Use this when your iPhone is away from the same Wi-Fi as your Mac. Scan once, then reconnect from the saved Mac."
        case .vnc:
            return "Compatibility mode for Macs with Screen Sharing or another VNC server enabled."
        }
    }
}

struct PairingChallenge: Identifiable, Equatable {
    let id = UUID()
    let hostName: String
    let mode: ConnectionMode
    let message: String
}

struct ConnectionRequest {
    let mode: ConnectionMode
    let host: DiscoveredHost
    let pairingCode: String?
    let vncUsername: String?
    let vncPassword: String?
    let remoteWebSocketURL: URL?

    init(
        mode: ConnectionMode,
        host: DiscoveredHost,
        pairingCode: String?,
        vncUsername: String?,
        vncPassword: String?,
        remoteWebSocketURL: URL? = nil
    ) {
        self.mode = mode
        self.host = host
        self.pairingCode = pairingCode
        self.vncUsername = vncUsername
        self.vncPassword = vncPassword
        self.remoteWebSocketURL = remoteWebSocketURL
    }

    func withPairingCode(_ code: String?) -> ConnectionRequest {
        ConnectionRequest(
            mode: mode,
            host: host,
            pairingCode: code,
            vncUsername: vncUsername,
            vncPassword: vncPassword,
            remoteWebSocketURL: remoteWebSocketURL
        )
    }
}

enum RemoteAccessURLNormalizer {
    static func webSocketURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let valueWithScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: valueWithScheme),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            components.scheme = scheme
        default:
            return nil
        }

        guard let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }
}

enum AirDeskConnectLink {
    static func request(from url: URL) -> ConnectionRequest? {
        guard url.scheme?.lowercased() == "airdesk",
              url.host?.lowercased() == "connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let pairing = firstValue(named: ["pairing", "pairingCode", "code"], in: queryItems)

        if let remoteParam = firstValue(named: ["url"], in: queryItems),
           let remoteURL = RemoteAccessURLNormalizer.webSocketURL(from: remoteParam) {
            return remoteAccessRequest(remoteURL: remoteURL, pairing: pairing)
        }

        guard let hostParam = firstValue(named: ["host"], in: queryItems),
              let portString = firstValue(named: ["port"], in: queryItems),
              let port = Int(portString) else {
            return nil
        }

        let host = DiscoveredHost(name: hostParam, host: hostParam, port: port)
        return ConnectionRequest(
            mode: .airDesk,
            host: host,
            pairingCode: normalizedPairing(pairing),
            vncUsername: nil,
            vncPassword: nil
        )
    }

    static func displayRemoteAccessURL(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "airdesk",
              url.host?.lowercased() == "connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let remoteParam = firstValue(named: ["url"], in: components.queryItems ?? []),
              RemoteAccessURLNormalizer.webSocketURL(from: remoteParam) != nil else {
            return nil
        }
        return remoteParam
    }

    private static func remoteAccessRequest(remoteURL: URL, pairing: String?) -> ConnectionRequest {
        let hostName = remoteURL.host ?? remoteURL.absoluteString
        let port = remoteURL.port ?? (remoteURL.scheme == "ws" ? 80 : 443)
        let host = DiscoveredHost(name: hostName, host: hostName, port: port)
        return ConnectionRequest(
            mode: .remoteAccess,
            host: host,
            pairingCode: normalizedPairing(pairing),
            vncUsername: nil,
            vncPassword: nil,
            remoteWebSocketURL: remoteURL
        )
    }

    private static func firstValue(named names: [String], in queryItems: [URLQueryItem]) -> String? {
        for name in names {
            if let value = queryItems.first(where: { $0.name == name })?.value {
                return value
            }
        }
        return nil
    }

    private static func normalizedPairing(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return String(digits.prefix(6))
    }
}

struct VNCDisplayInfo: Identifiable, Equatable {
    let id: UInt32
    let frame: CGRect
    let index: Int

    var title: String {
        index == 0 ? "Desktop" : "Display \(index + 1)"
    }

    var aspectRatio: CGFloat {
        guard frame.height > 0 else { return 16.0 / 10.0 }
        return frame.width / frame.height
    }

    init(id: UInt32, frame: CGRect, index: Int = 0) {
        self.id = id
        self.frame = frame
        self.index = index
    }
}

@MainActor
final class ConnectionDraft: ObservableObject {
    @Published var mode: ConnectionMode = .airDesk
    @Published var manualIP = ""
    @Published var manualPort = String(ConnectionMode.airDesk.defaultPort)
    @Published var remoteAccessURL = ""
    @Published var pairingCode = ""
    @Published var vncUsername = ""
    @Published var vncPassword = ""

    func setMode(_ newMode: ConnectionMode) {
        let oldMode = mode
        let trimmedPort = manualPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldReplacePort = trimmedPort.isEmpty || trimmedPort == String(oldMode.defaultPort)
        mode = newMode
        if shouldReplacePort {
            manualPort = String(newMode.defaultPort)
        }
    }

    func sanitizePairingCode() {
        let digits = pairingCode.filter(\.isNumber)
        let sanitized = String(digits.prefix(6))
        if pairingCode != sanitized {
            pairingCode = sanitized
        }
    }

    var resolvedPort: Int? {
        let trimmedPort = manualPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPort.isEmpty else { return mode.defaultPort }
        return Int(trimmedPort)
    }

    func requestForDiscoveredHost(_ host: DiscoveredHost) -> ConnectionRequest? {
        guard mode != .remoteAccess else { return remoteAccessRequest() }
        let port = mode == .airDesk ? host.port : (resolvedPort ?? mode.defaultPort)
        let resolvedHost = DiscoveredHost(name: host.name, host: host.host, port: port)
        return makeRequest(for: resolvedHost)
    }

    func applyDiscoveredHost(_ host: DiscoveredHost) {
        manualIP = host.host
        if mode == .airDesk {
            manualPort = String(host.port)
            return
        }

        let trimmedPort = manualPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPort.isEmpty || Int(trimmedPort) == nil {
            manualPort = String(mode.defaultPort)
        }
    }

    func manualRequest() -> ConnectionRequest? {
        if mode == .remoteAccess {
            return remoteAccessRequest()
        }

        let trimmedIP = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty, let port = resolvedPort else { return nil }
        return makeRequest(for: DiscoveredHost(name: trimmedIP, host: trimmedIP, port: port))
    }

    var normalizedRemoteAccessURL: URL? {
        RemoteAccessURLNormalizer.webSocketURL(from: remoteAccessURL)
    }

    private func remoteAccessRequest() -> ConnectionRequest? {
        guard let url = normalizedRemoteAccessURL else { return nil }
        let hostName = url.host ?? url.absoluteString
        let port = url.port ?? (url.scheme == "ws" ? 80 : 443)
        let host = DiscoveredHost(name: hostName, host: hostName, port: port)
        return ConnectionRequest(
            mode: .remoteAccess,
            host: host,
            pairingCode: normalizedPairingCode,
            vncUsername: nil,
            vncPassword: nil,
            remoteWebSocketURL: url
        )
    }

    private func makeRequest(for host: DiscoveredHost) -> ConnectionRequest {
        let trimmedUsername = vncUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = vncPassword.isEmpty ? nil : vncPassword
        return ConnectionRequest(
            mode: mode,
            host: host,
            pairingCode: normalizedPairingCode,
            vncUsername: trimmedUsername.isEmpty ? nil : trimmedUsername,
            vncPassword: password
        )
    }

    private var normalizedPairingCode: String? {
        let digits = pairingCode.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return String(digits.prefix(6))
    }
}

extension MonitorInfo {
    var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }
}

enum RemoteControlMode: String, CaseIterable, Identifiable {
    case touch
    case scroll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .touch: return "Control"
        case .scroll: return "Scroll"
        }
    }

    var iconName: String {
        switch self {
        case .touch: return "cursorarrow.click"
        case .scroll: return "arrow.up.arrow.down"
        }
    }
}
