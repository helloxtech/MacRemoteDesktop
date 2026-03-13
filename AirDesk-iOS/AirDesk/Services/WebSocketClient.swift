import Foundation

class WebSocketClient: NSObject {

    private let host: String
    private let port: Int
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    var onMonitorsReceived: (([MonitorInfo]) -> Void)?
    var onVideoFrame: ((Data, Int, Bool) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        super.init()
    }

    func connect() {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        guard let url = URL(string: "ws://\(host):\(port)") else { return }
        task = session?.webSocketTask(with: url)
        task?.resume()
        startReceiving()
        sendConnectMessage()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session = nil
    }

    func requestStream(displayIndex: Int) {
        let msg = RequestStreamMessage(displayIndex: displayIndex)
        sendJSON(msg)
    }

    func sendMouseMessage(_ msg: MouseMessage) {
        sendJSON(msg)
    }

    func sendKeyboardMessage(_ msg: KeyboardMessage) {
        sendJSON(msg)
    }

    private func sendConnectMessage() {
        sendJSON(ConnectMessage())
    }

    private func sendJSON<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error = error { print("WebSocketClient send error: \(error)") }
        }
    }

    private func startReceiving() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
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
        case .string(let text):
            handleTextMessage(text)
        case .data(let data):
            handleBinaryMessage(data)
        @unknown default:
            break
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "screen_info" {
            if let msg = try? JSONDecoder().decode(ScreenInfoMessage.self, from: data) {
                onMonitorsReceived?(msg.monitors)
                // Request stream for first display
                if !msg.monitors.isEmpty {
                    requestStream(displayIndex: 0)
                }
            }
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        guard data.count > 7 else { return }

        let messageType = data[0]
        guard messageType == 0x01 else { return }  // video frame

        let displayIndex = Int(data[1])
        let flags = data[6]
        let isKeyframe = (flags & 0x01) != 0
        let videoData = data.subdata(in: 7..<data.count)

        onVideoFrame?(videoData, displayIndex, isKeyframe)
    }

    private func handleDisconnect(_ error: Error?) {
        onDisconnect?(error)
        attemptReconnect()
    }

    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else { return }
        reconnectAttempts += 1
        let delay = Double(reconnectAttempts) * 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
}

extension WebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        reconnectAttempts = 0
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onDisconnect?(nil)
    }
}
