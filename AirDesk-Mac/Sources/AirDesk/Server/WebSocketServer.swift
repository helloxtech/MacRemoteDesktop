import Foundation
import Network

class WebSocketServer: NSObject, H264EncoderDelegate {

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let port: UInt16
    private let serverQueue = DispatchQueue(label: "airdesk.server")

    weak var inputDelegate: InputInjector?
    var clientChangeHandler: ((Int) -> Void)?
    var monitorInfoProvider: (() -> [MonitorInfo])?

    init(port: UInt16) {
        self.port = port
        super.init()
    }

    func start() {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        listener.start(queue: serverQueue)
        print("AirDesk WebSocket server started on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)
        clientChangeHandler?(connections.count)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed, .cancelled:
                self.connections.removeAll { $0 === connection }
                self.clientChangeHandler?(self.connections.count)
            default:
                break
            }
        }

        connection.start(queue: serverQueue)
        receive(from: connection)
    }

    private func receive(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty,
               let context = context,
               let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .text:
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleTextMessage(text, from: connection)
                    }
                default:
                    break
                }
            }
            if error == nil {
                self.receive(from: connection)
            }
        }
    }

    private func handleTextMessage(_ text: String, from connection: NWConnection) {
        let message = parseIncomingMessage(text)
        switch message {
        case .connect:
            sendScreenInfo(to: connection)
        case .mouse(let msg):
            inputDelegate?.handleMouseMessage(msg)
        case .keyboard(let msg):
            inputDelegate?.handleKeyboardMessage(msg)
        case .requestStream(let msg):
            print("Client requested stream for display \(msg.displayIndex) at \(msg.fps)fps")
        case .unknown:
            break
        }
    }

    private func sendScreenInfo(to connection: NWConnection) {
        let monitors = monitorInfoProvider?() ?? []
        let msg = ScreenInfoMessage(monitors: monitors)
        guard let data = try? JSONEncoder().encode(msg),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text, to: connection)
    }

    private func sendText(_ text: String, to connection: NWConnection) {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func sendBinary(_ data: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    // MARK: - H264EncoderDelegate

    func didEncodeFrame(_ data: Data, isKeyframe: Bool, displayIndex: Int, timestamp: Double) {
        let tsMs = UInt32(timestamp * 1000) & 0xFFFFFFFF
        let header = VideoFrameHeader(displayIndex: displayIndex, timestampMs: tsMs, isKeyframe: isKeyframe)
        let frame = header.buildFrame(with: data)

        serverQueue.async { [weak self] in
            self?.connections.forEach { self?.sendBinary(frame, to: $0) }
        }
    }
}
