import CryptoKit
import Foundation

public struct MonitorInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public let width: Int
    public let height: Int
    public let scaleFactor: Float
    public let name: String

    public init(id: Int, width: Int, height: Int, scaleFactor: Float, name: String) {
        self.id = id
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.name = name
    }
}

public struct ScreenInfoMessage: Codable, Sendable {
    public let type: String
    public let monitors: [MonitorInfo]

    public init(type: String = "screen_info", monitors: [MonitorInfo]) {
        self.type = type
        self.monitors = monitors
    }
}

public struct ConnectMessage: Codable, Sendable {
    public let type: String
    public let clientName: String
    public let clientVersion: String
    public let clientID: String
    public let pairingCode: String?
    public let clientNonce: String?
    public let authProof: String?

    public init(
        type: String = "connect",
        clientName: String,
        clientVersion: String,
        clientID: String,
        pairingCode: String? = nil,
        clientNonce: String? = nil,
        authProof: String? = nil
    ) {
        self.type = type
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.clientID = clientID
        self.pairingCode = pairingCode
        self.clientNonce = clientNonce
        self.authProof = authProof
    }
}

public struct PairingStatusMessage: Codable, Sendable {
    public let type: String
    public let paired: Bool
    public let message: String
    public let authToken: String?

    public init(type: String = "pairing_status", paired: Bool, message: String, authToken: String? = nil) {
        self.type = type
        self.paired = paired
        self.message = message
        self.authToken = authToken
    }
}

public enum AirDeskAuthProof {
    public static func make(clientID: String, nonce: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let payload = Data("\(clientID):\(nonce)".utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(signature).base64EncodedString()
    }
}

public struct RequestStreamMessage: Codable, Sendable {
    public let type: String
    public let displayIndex: Int
    public let fps: Int
    public let quality: String

    public init(type: String = "request_stream", displayIndex: Int, fps: Int = 30, quality: String = "high") {
        self.type = type
        self.displayIndex = displayIndex
        self.fps = fps
        self.quality = quality
    }
}

public struct MouseMessage: Codable, Sendable {
    public let type: String
    public let x: Float
    public let y: Float
    public let action: String
    public let scrollDeltaX: Float?
    public let scrollDeltaY: Float?
    public let displayIndex: Int

    public init(
        type: String = "mouse",
        x: Float,
        y: Float,
        action: String,
        displayIndex: Int,
        scrollDeltaX: Float? = nil,
        scrollDeltaY: Float? = nil
    ) {
        self.type = type
        self.x = x
        self.y = y
        self.action = action
        self.displayIndex = displayIndex
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
    }
}

public struct KeyboardMessage: Codable, Sendable {
    public let type: String
    public let keyCode: Int
    public let modifiers: [String]
    public let action: String

    public init(type: String = "key", keyCode: Int, modifiers: [String], action: String) {
        self.type = type
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }
}

public struct ClipboardMessage: Codable, Sendable {
    public let type: String
    public let content: String

    public init(type: String, content: String) {
        self.type = type
        self.content = content
    }
}

public struct SystemActionMessage: Codable, Sendable {
    public let type: String
    public let action: String

    public init(type: String = "system_action", action: String) {
        self.type = type
        self.action = action
    }
}

public struct LockStatusMessage: Codable, Sendable {
    public let type: String
    public let isLocked: Bool
    public let message: String

    public init(type: String = "lock_status", isLocked: Bool, message: String) {
        self.type = type
        self.isLocked = isLocked
        self.message = message
    }
}

public struct PermissionStatusMessage: Codable, Equatable, Sendable {
    public let type: String
    public let screenRecording: Bool
    public let accessibility: Bool
    public let canView: Bool
    public let canControl: Bool
    public let message: String

    public init(
        type: String = "permission_status",
        screenRecording: Bool,
        accessibility: Bool,
        canView: Bool,
        canControl: Bool,
        message: String
    ) {
        self.type = type
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.canView = canView
        self.canControl = canControl
        self.message = message
    }

    public static let controlReady = PermissionStatusMessage(
        screenRecording: true,
        accessibility: true,
        canView: true,
        canControl: true,
        message: "Control ready"
    )
}

public enum IncomingMessage: Sendable {
    case connect(ConnectMessage)
    case requestStream(RequestStreamMessage)
    case mouse(MouseMessage)
    case keyboard(KeyboardMessage)
    case clipboard(ClipboardMessage)
    case systemAction(SystemActionMessage)
    case unknown
}

public func parseIncomingMessage(_ text: String) -> IncomingMessage {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else { return .unknown }

    let decoder = JSONDecoder()

    switch type {
    case "connect":
        if let msg = try? decoder.decode(ConnectMessage.self, from: data) { return .connect(msg) }
    case "request_stream":
        if let msg = try? decoder.decode(RequestStreamMessage.self, from: data) { return .requestStream(msg) }
    case "mouse":
        if let msg = try? decoder.decode(MouseMessage.self, from: data) { return .mouse(msg) }
    case "key":
        if let msg = try? decoder.decode(KeyboardMessage.self, from: data) { return .keyboard(msg) }
    case "clipboard_push":
        if let msg = try? decoder.decode(ClipboardMessage.self, from: data) { return .clipboard(msg) }
    case "system_action":
        if let msg = try? decoder.decode(SystemActionMessage.self, from: data) { return .systemAction(msg) }
    default:
        break
    }
    return .unknown
}

public struct VideoFrameHeader: Sendable {
    public static let messageType: UInt8 = 0x01
    public static let headerSize = 7

    public let displayIndex: Int
    public let timestampMs: UInt32
    public let isKeyframe: Bool

    public init(displayIndex: Int, timestampMs: UInt32, isKeyframe: Bool) {
        self.displayIndex = displayIndex
        self.timestampMs = timestampMs
        self.isKeyframe = isKeyframe
    }

    public func buildFrame(with videoData: Data) -> Data {
        var frame = Data(capacity: Self.headerSize + videoData.count)
        frame.append(Self.messageType)
        frame.append(UInt8(displayIndex))
        let ts = timestampMs.bigEndian
        withUnsafeBytes(of: ts) { frame.append(contentsOf: $0) }
        frame.append(isKeyframe ? 0x01 : 0x00)
        frame.append(videoData)
        return frame
    }
}
