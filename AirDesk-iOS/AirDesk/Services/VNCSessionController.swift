import Foundation
import CoreGraphics
import RoyalVNCKit

final class VNCSessionController: NSObject {
    typealias StateHandler = (VNCConnection.Status, Error?) -> Void
    typealias SizeHandler = (CGSize) -> Void
    typealias DisplayLayoutHandler = (CGSize, [VNCDisplayInfo]) -> Void
    typealias FramebufferHandler = (CGImage, CGSize, Bool) -> Void

    var onStateChanged: StateHandler?
    var onDesktopSizeChanged: SizeHandler?
    var onDisplayLayoutChanged: DisplayLayoutHandler?
    var onFramebufferUpdated: FramebufferHandler?

    private let host: String
    private let port: Int
    private let username: String?
    private let password: String?

    private var connection: VNCConnection?
    private var isIntentionalDisconnect = false
    private var latestFramebufferSize: CGSize = .zero
    private let framePublishQueue = DispatchQueue(label: "airdesk.vnc.framebuffer", qos: .userInitiated)
    private var latestPendingFramebuffer: VNCFramebuffer?
    private var framePublishScheduled = false
    private var lastPublishedFrameTime: CFAbsoluteTime = 0
    private var lastPublishedDisplays: [VNCDisplayInfo] = []

    init(host: String, port: Int, username: String?, password: String?) {
        self.host = host
        self.port = port
        self.username = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        super.init()
    }

    func connect() {
        isIntentionalDisconnect = false
        let authenticationPreference: VNCConnection.Settings.AuthenticationPreference =
            if let username, !username.isEmpty {
                .preferUsernamePassword
            } else {
                .preferVNCPassword
            }
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: host,
            port: UInt16(clamping: port),
            isShared: true,
            isScalingEnabled: false,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            authenticationPreference: authenticationPreference,
            frameEncodings: .default
        )
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        self.connection = connection
        AirDeskDiagnostics.shared.record(
            "Opening VNC connection to \(host):\(port) using \(authenticationPreference == .preferUsernamePassword ? "username/password" : "VNC password") preference"
        )
        connection.connect()
    }

    func disconnect() {
        isIntentionalDisconnect = true
        connection?.disconnect()
        connection?.delegate = nil
        connection = nil
        framePublishQueue.async { [weak self] in
            self?.latestPendingFramebuffer = nil
            self?.framePublishScheduled = false
            self?.lastPublishedFrameTime = 0
        }
    }

    func shouldDisplay(error: Error?) -> Bool {
        guard let error else { return false }
        guard let vncError = error as? VNCError else { return true }
        return vncError.shouldDisplayToUser
    }

    func userFacingError(from error: Error?) -> String {
        guard let error else { return "The VNC connection closed." }

        if let vncError = error as? VNCError {
            switch vncError {
            case .authentication:
                if error.localizedDescription.localizedCaseInsensitiveContains("No authentication data was provided") {
                    return "Enter the VNC password before connecting."
                }
                return "VNC authentication failed. Check the Screen Sharing username and password on the Mac."
            case .connection(let connectionError):
                switch connectionError {
                case .failed(let underlyingError):
                    if let message = hintForUnderlyingConnectionError(underlyingError) {
                        return message
                    }
                case .closedDuringHandshake(_, let underlyingError):
                    if let message = hintForUnderlyingConnectionError(underlyingError) {
                        return message
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        if let message = hintForUnderlyingConnectionError(error) {
            return message
        }

        return error.localizedDescription
    }

    func movePointer(to normalizedPoint: CGPoint) {
        guard let point = absolutePoint(from: normalizedPoint) else { return }
        connection?.mouseMove(x: point.x, y: point.y)
    }

    func leftClick(at normalizedPoint: CGPoint) {
        guard let point = absolutePoint(from: normalizedPoint) else { return }
        connection?.mouseButtonDown(.left, x: point.x, y: point.y)
        connection?.mouseButtonUp(.left, x: point.x, y: point.y)
    }

    func doubleClick(at normalizedPoint: CGPoint) {
        guard let point = absolutePoint(from: normalizedPoint) else { return }
        for _ in 0..<2 {
            connection?.mouseButtonDown(.left, x: point.x, y: point.y)
            connection?.mouseButtonUp(.left, x: point.x, y: point.y)
        }
    }

    func rightClick(at normalizedPoint: CGPoint) {
        guard let point = absolutePoint(from: normalizedPoint) else { return }
        connection?.mouseButtonDown(.right, x: point.x, y: point.y)
        connection?.mouseButtonUp(.right, x: point.x, y: point.y)
    }

    func dragBegan(at normalizedPoint: CGPoint) {
        guard let point = absolutePoint(from: normalizedPoint) else { return }
        connection?.mouseButtonDown(.left, x: point.x, y: point.y)
    }

    func dragChanged(to normalizedPoint: CGPoint) {
        guard let point = absolutePoint(from: normalizedPoint) else { return }
        connection?.mouseMove(x: point.x, y: point.y)
    }

    func dragEnded(at normalizedPoint: CGPoint) {
        guard let point = absolutePoint(from: normalizedPoint) else { return }
        connection?.mouseButtonUp(.left, x: point.x, y: point.y)
    }

    func scroll(horizontalSteps: Int, verticalSteps: Int, at normalizedPoint: CGPoint) {
        guard let point = absolutePoint(from: normalizedPoint) else { return }
        if horizontalSteps < 0 {
            for _ in 0..<abs(horizontalSteps) {
                connection?.mouseWheel(.left, x: point.x, y: point.y, steps: 1)
            }
        } else if horizontalSteps > 0 {
            for _ in 0..<horizontalSteps {
                connection?.mouseWheel(.right, x: point.x, y: point.y, steps: 1)
            }
        }

        if verticalSteps < 0 {
            for _ in 0..<abs(verticalSteps) {
                connection?.mouseWheel(.up, x: point.x, y: point.y, steps: 1)
            }
        } else if verticalSteps > 0 {
            for _ in 0..<verticalSteps {
                connection?.mouseWheel(.down, x: point.x, y: point.y, steps: 1)
            }
        }
    }

    func sendKeyPress(_ key: VNCKeyCode, modifiers: [VNCKeyCode] = []) {
        let deduplicatedModifiers = uniqueModifiers(modifiers)
        for modifier in deduplicatedModifiers {
            connection?.keyDown(modifier)
        }
        connection?.keyDown(key)
        connection?.keyUp(key)
        for modifier in deduplicatedModifiers.reversed() {
            connection?.keyUp(modifier)
        }
    }

    func setActiveDisplay(_ display: VNCDisplayInfo?) {
        _ = display
        connection?.clearFramebufferRequestRegion()
    }

    private func uniqueModifiers(_ keys: [VNCKeyCode]) -> [VNCKeyCode] {
        var seen = Set<UInt32>()
        var unique: [VNCKeyCode] = []
        for key in keys {
            if seen.insert(key.rawValue).inserted {
                unique.append(key)
            }
        }
        return unique
    }

    private func absolutePoint(from normalizedPoint: CGPoint) -> (x: UInt16, y: UInt16)? {
        guard latestFramebufferSize.width > 1, latestFramebufferSize.height > 1 else { return nil }

        let clampedX = max(0, min(1, normalizedPoint.x))
        let clampedY = max(0, min(1, normalizedPoint.y))

        let maxX = min(CGFloat(UInt16.max), latestFramebufferSize.width - 1)
        let maxY = min(CGFloat(UInt16.max), latestFramebufferSize.height - 1)

        let x = UInt16(max(0, min(CGFloat(UInt16.max), round(clampedX * maxX))))
        let y = UInt16(max(0, min(CGFloat(UInt16.max), round(clampedY * maxY))))
        return (x, y)
    }

    private func publishFramebuffer(_ framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        latestFramebufferSize = size
        publishDisplayLayout(for: framebuffer, size: size)
        scheduleFramebufferPublish(framebuffer)
    }

    private func publishDisplayLayout(for framebuffer: VNCFramebuffer, size: CGSize) {
        let displays = displayInfo(from: framebuffer, desktopSize: size)
        guard displays != lastPublishedDisplays else { return }

        lastPublishedDisplays = displays
        DispatchQueue.main.async { [weak self] in
            self?.onDesktopSizeChanged?(size)
            self?.onDisplayLayoutChanged?(size, displays)
        }
    }

    private func displayInfo(from framebuffer: VNCFramebuffer, desktopSize: CGSize) -> [VNCDisplayInfo] {
        if desktopSize.width <= 0 || desktopSize.height <= 0 {
            return []
        }

        return [
            VNCDisplayInfo(
                id: 0,
                frame: CGRect(origin: .zero, size: desktopSize),
                index: 0
            )
        ]
    }

    private func scheduleFramebufferPublish(_ framebuffer: VNCFramebuffer) {
        framePublishQueue.async { [weak self] in
            guard let self else { return }

            self.latestPendingFramebuffer = framebuffer
            guard !self.framePublishScheduled else { return }
            self.framePublishScheduled = true

            let targetFrameInterval = 1.0 / 20.0
            let now = CFAbsoluteTimeGetCurrent()
            let delay = max(0, targetFrameInterval - (now - self.lastPublishedFrameTime))

            self.framePublishQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }

                let pendingFramebuffer = self.latestPendingFramebuffer
                self.latestPendingFramebuffer = nil
                self.framePublishScheduled = false
                self.lastPublishedFrameTime = CFAbsoluteTimeGetCurrent()

                guard let pendingFramebuffer else { return }

                let image = pendingFramebuffer.cgImage
                guard let image else { return }

                let publishedSize = pendingFramebuffer.cgSize

                DispatchQueue.main.async { [weak self] in
                    self?.onFramebufferUpdated?(image, publishedSize, false)
                }
            }
        }
    }

    private func hintForUnderlyingConnectionError(_ error: Error?) -> String? {
        guard let error else { return nil }

        let nsError = error as NSError
        let message = [
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 61 || message.contains("connection refused") {
            return "VNC is not reachable on the Mac. Turn on Screen Sharing in macOS Settings and confirm port 5900 is open."
        }

        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 60 || message.contains("timed out") {
            return "The VNC connection timed out. Confirm the iPhone and Mac are on the same network and that Screen Sharing is enabled on the Mac."
        }

        if message.contains("authentication") || message.contains("permission denied") {
            return "VNC authentication failed. Check the Screen Sharing username and password on the Mac."
        }

        return nil
    }
}

extension VNCSessionController: VNCConnectionDelegate {
    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        if isIntentionalDisconnect, connectionState.status == .disconnected {
            return
        }

        if connectionState.status == .disconnected {
            framePublishQueue.async { [weak self] in
                self?.latestPendingFramebuffer = nil
                self?.framePublishScheduled = false
                self?.lastPublishedFrameTime = 0
            }
            lastPublishedDisplays = []
        }

        AirDeskDiagnostics.shared.record("VNC state: \(connectionState.status) \(connectionState.error?.localizedDescription ?? "")")
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(connectionState.status, connectionState.error)
        }
    }

    func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType, completion: @escaping (VNCCredential?) -> Void) {
        AirDeskDiagnostics.shared.record(
            "VNC credential requested for \(authenticationType) usernamePresent=\(!(username?.isEmpty ?? true)) passwordPresent=\(!(password?.isEmpty ?? true))"
        )
        let credential: VNCCredential?
        if authenticationType.requiresUsername {
            guard let username, !username.isEmpty, let password, !password.isEmpty else {
                AirDeskDiagnostics.shared.record("VNC credential request could not be satisfied for \(authenticationType)")
                credential = nil
                completion(credential)
                return
            }
            credential = VNCUsernamePasswordCredential(username: username, password: password)
        } else if authenticationType.requiresPassword {
            guard let password, !password.isEmpty else {
                AirDeskDiagnostics.shared.record("VNC password request arrived with no password available")
                credential = nil
                completion(credential)
                return
            }
            credential = VNCPasswordCredential(password: password)
        } else {
            credential = nil
        }

        completion(credential)
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        publishFramebuffer(framebuffer)
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        publishFramebuffer(framebuffer)
    }

    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        publishFramebuffer(framebuffer)
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        // Cursor updates are intentionally ignored for the first compatibility pass.
    }
}
