import Foundation
import UIKit

struct DiscoveredHost: Identifiable, Hashable {
    let id: UUID
    let name: String
    let host: String
    let port: Int

    init(name: String, host: String, port: Int) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
    }
}

struct MonitorInfo: Identifiable, Codable, Hashable {
    let id: Int
    let width: Int
    let height: Int
    let scaleFactor: Float
    let name: String

    var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }
}

struct ScreenInfoMessage: Codable {
    let type: String
    let monitors: [MonitorInfo]
}

struct ConnectMessage: Codable {
    let type: String
    let clientName: String
    let clientVersion: String

    init() {
        type = "connect"
        clientName = UIDevice.current.name
        clientVersion = "1.0"
    }
}

struct RequestStreamMessage: Codable {
    let type: String
    let displayIndex: Int
    let fps: Int
    let quality: String

    init(displayIndex: Int, fps: Int = 30, quality: String = "high") {
        type = "request_stream"
        self.displayIndex = displayIndex
        self.fps = fps
        self.quality = quality
    }
}

struct MouseMessage: Codable {
    let type: String
    let x: Float
    let y: Float
    let action: String
    let scrollDeltaX: Float?
    let scrollDeltaY: Float?
    let displayIndex: Int

    init(x: Float, y: Float, action: String, displayIndex: Int, scrollDeltaX: Float? = nil, scrollDeltaY: Float? = nil) {
        type = "mouse"
        self.x = x
        self.y = y
        self.action = action
        self.displayIndex = displayIndex
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
    }
}

struct KeyboardMessage: Codable {
    let type: String
    let keyCode: Int
    let modifiers: [String]
    let action: String

    init(keyCode: Int, modifiers: [String], action: String) {
        type = "key"
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }
}
