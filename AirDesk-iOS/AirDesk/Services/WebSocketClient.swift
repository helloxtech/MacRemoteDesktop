import Foundation
import QuartzCore

class WebSocketClient: NSObject {

    private let host: String
    private let port: Int
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var isReconnecting = false
    private var connectTimeoutWork: DispatchWorkItem?

    var onMonitorsReceived: (([MonitorInfo]) -> Void)?
    // timestampMs added so AppState can compute latency
    var onVideoFrame: ((Data, Int, Bool, UInt32) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onClipboardChanged: ((String) -> Void)?
    var onLatencyUpdate: ((Int) -> Void)?

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        super.init()
    }

    func connect() {
        // Reset reconnect counter so future failures can retry
        reconnectAttempts = 0
        // Cancel and invalidate previous session to prevent URLSession leak on reconnect
        connectTimeoutWork?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        guard let url = URL(string: "ws://\(host):\(port)") else { return }
        task = session?.webSocketTask(with: url)
        task?.resume()
        startReceiving()
        sendConnectMessage()

        // 10-second connection timeout — cancelled when screen_info arrives
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.handleDisconnect(URLError(.timedOut))
        }
        connectTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func disconnect() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        isReconnecting = false
        reconnectAttempts = maxReconnectAttempts   // prevent any pending reconnect
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    func requestStream(displayIndex: Int) { sendJSON(RequestStreamMessage(displayIndex: displayIndex)) }
    func sendMouseMessage(_ msg: MouseMessage) { sendJSON(msg) }
    func sendKeyboardMessage(_ msg: KeyboardMessage) { sendJSON(msg) }
    func sendClipboard(_ text: String) { sendJSON(ClipboardMessage(type: "clipboard_push", content: text)) }

    private func sendConnectMessage() { sendJSON(ConnectMessage()) }

    private func sendJSON<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        guard let task else {
            NSLog("[AirDesk] sendJSON: task is nil, message dropped!")
            return
        }
        task.send(.string(text)) { error in
            if let error { NSLog("[AirDesk] WebSocketClient send error: \(error)") }
        }
    }

    private func startReceiving() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.startReceiving()
            case .failure(let error):
                self.handleDisconnect(error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text): handleTextMessage(text)
        case .data(let data):   handleBinaryMessage(data)
        @unknown default:       break
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "screen_info":
            connectTimeoutWork?.cancel()
            connectTimeoutWork = nil
            if let msg = try? JSONDecoder().decode(ScreenInfoMessage.self, from: data) {
                onMonitorsReceived?(msg.monitors)
                if !msg.monitors.isEmpty { requestStream(displayIndex: 0) }
            }
        case "clipboard_changed":
            if let msg = try? JSONDecoder().decode(ClipboardMessage.self, from: data) {
                onClipboardChanged?(msg.content)
            }
        default:
            break
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        guard data.count > 7, data[0] == 0x01 else { return }

        let displayIndex = Int(data[1])
        // Parse 4-byte big-endian timestamp (bytes 2–5)
        let tsMs: UInt32 = data.withUnsafeBytes { bytes in
            let ptr = bytes.baseAddress!.advanced(by: 2).assumingMemoryBound(to: UInt8.self)
            return UInt32(ptr[0]) << 24 | UInt32(ptr[1]) << 16 | UInt32(ptr[2]) << 8 | UInt32(ptr[3])
        }
        let isKeyframe = (data[6] & 0x01) != 0
        let videoData = data.subdata(in: 7..<data.count)

        // Compute one-way latency estimate
        let nowMs = UInt32(CACurrentMediaTime() * 1000) & 0xFFFFFFFF
        let latency = Int(nowMs &- tsMs)
        if latency >= 0 && latency < 5000 { onLatencyUpdate?(latency) }

        onVideoFrame?(videoData, displayIndex, isKeyframe, tsMs)
    }

    private func handleDisconnect(_ error: Error?) {
        guard !isReconnecting else { return }
        onDisconnect?(error)
        attemptReconnect()
    }

    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts, !isReconnecting else { return }
        isReconnecting = true
        reconnectAttempts += 1
        let delay = Double(reconnectAttempts) * 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.isReconnecting = false
            self.connect()
        }
    }
}

extension WebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        reconnectAttempts = 0
        isReconnecting = false
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleDisconnect(nil)
    }
}
