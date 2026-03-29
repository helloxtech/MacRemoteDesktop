import Foundation

// MARK: - Outgoing (Mac → iOS)

struct ScreenInfoMessage: Codable {
    let type: String
    let monitors: [MonitorInfo]

    init(monitors: [MonitorInfo]) {
        self.type = "screen_info"
        self.monitors = monitors
    }
}

struct MonitorInfo: Codable {
    let id: Int
    let width: Int
    let height: Int
    let scaleFactor: Float
    let name: String
}

// MARK: - Incoming (iOS → Mac)

enum IncomingMessage {
    case connect(ConnectMessage)
    case requestStream(RequestStreamMessage)
    case mouse(MouseMessage)
    case keyboard(KeyboardMessage)
    case clipboard(ClipboardMessage)
    case systemAction(SystemActionMessage)
    case unknown
}

struct ConnectMessage: Codable {
    let type: String
    let clientName: String
    let clientVersion: String
}

struct RequestStreamMessage: Codable {
    let type: String
    let displayIndex: Int
    let fps: Int
    let quality: String
}

struct MouseMessage: Codable {
    let type: String
    let x: Float
    let y: Float
    let action: String      // "move", "click", "rightClick", "scroll", "drag", "dragEnd"
    let scrollDeltaX: Float?
    let scrollDeltaY: Float?
    let displayIndex: Int
}

struct KeyboardMessage: Codable {
    let type: String
    let keyCode: Int
    let modifiers: [String]
    let action: String      // "down", "up"
}

struct ClipboardMessage: Codable {
    let type: String   // "clipboard_changed" (Mac→iOS) or "clipboard_push" (iOS→Mac)
    let content: String
}

struct SystemActionMessage: Codable {
    let type: String
    let action: String  // "mission_control"
}

// MARK: - Lock Status (Mac → iOS)  ← NEW
struct LockStatusMessage: Codable {
    let type: String = "lock_status"
    let isLocked: Bool
    let message: String
}

@MainActor
final class LockStatusMonitor {
    static let shared = LockStatusMonitor()

    private(set) var isLocked = false
    private var observers: [Any] = []

    private init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(isLocked: true)
            }
        })
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(isLocked: false)
            }
        })
    }

    private func update(isLocked: Bool) {
        self.isLocked = isLocked
        NotificationCenter.default.post(name: .screenLockStatusChanged, object: isLocked)
    }
}

extension Notification.Name {
    static let screenLockStatusChanged = Notification.Name("screenLockStatusChanged")
}

// MARK: - Binary Video Frame Header

struct VideoFrameHeader {
    static let messageType: UInt8 = 0x01
    // Layout: [type:1][displayIndex:1][timestampMs:4 BE][flags:1][h264Data...]
    static let headerSize = 7

    let displayIndex: Int
    let timestampMs: UInt32
    let isKeyframe: Bool

    func buildFrame(with videoData: Data) -> Data {
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

// MARK: - Message Parser

func parseIncomingMessage(_ text: String) -> IncomingMessage {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else { return .unknown }

    let decoder = JSONDecoder()
    guard let msgData = text.data(using: .utf8) else { return .unknown }

    switch type {
    case "connect":
        if let msg = try? decoder.decode(ConnectMessage.self, from: msgData) { return .connect(msg) }
    case "request_stream":
        if let msg = try? decoder.decode(RequestStreamMessage.self, from: msgData) { return .requestStream(msg) }
    case "mouse":
        if let msg = try? decoder.decode(MouseMessage.self, from: msgData) { return .mouse(msg) }
    case "key":
        if let msg = try? decoder.decode(KeyboardMessage.self, from: msgData) { return .keyboard(msg) }
    case "clipboard_push":
        if let msg = try? decoder.decode(ClipboardMessage.self, from: msgData) { return .clipboard(msg) }
    case "system_action":
        if let msg = try? decoder.decode(SystemActionMessage.self, from: msgData) { return .systemAction(msg) }
    default:
        break
    }
    return .unknown
}
