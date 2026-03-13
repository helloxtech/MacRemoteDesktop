import AppKit

class StatusBarController: NSObject {

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var isSharing = false

    private let titleItem: NSMenuItem
    private let toggleItem: NSMenuItem
    private let clientCountItem: NSMenuItem
    private let tunnelURLItem: NSMenuItem

    private let server: WebSocketServer
    private let tunnel: CloudflareTunnelManager
    private let capture: ScreenCaptureManager

    init(server: WebSocketServer, tunnel: CloudflareTunnelManager, capture: ScreenCaptureManager) {
        self.server = server
        self.tunnel = tunnel
        self.capture = capture

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()

        titleItem = NSMenuItem(title: "AirDesk", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false

        toggleItem = NSMenuItem(title: "Start Sharing", action: #selector(toggleSharing), keyEquivalent: "")
        clientCountItem = NSMenuItem(title: "No clients connected", action: nil, keyEquivalent: "")
        clientCountItem.isEnabled = false
        tunnelURLItem = NSMenuItem(title: "Tunnel: Not active", action: nil, keyEquivalent: "")
        tunnelURLItem.isEnabled = false

        super.init()

        toggleItem.target = self

        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(toggleItem)
        menu.addItem(clientCountItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(tunnelURLItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit AirDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateIcon()

        tunnel.urlHandler = { [weak self] url in
            DispatchQueue.main.async {
                self?.tunnelURLItem.title = url != nil ? "Tunnel: \(url!)" : "Tunnel: Not active"
            }
        }
    }

    @objc private func toggleSharing() {
        isSharing ? stopSharing() : startSharing()
    }

    private func startSharing() {
        server.start()
        capture.startCapture()
        isSharing = true
        toggleItem.title = "Stop Sharing"
        updateIcon()
    }

    private func stopSharing() {
        server.stop()
        capture.stopCapture()
        isSharing = false
        toggleItem.title = "Start Sharing"
        updateIcon()
    }

    func updateClientCount(_ count: Int) {
        clientCountItem.title = count == 0 ? "No clients connected" : "\(count) client\(count > 1 ? "s" : "") connected"
    }

    private func updateIcon() {
        if let button = statusItem.button {
            let imageName = isSharing ? "desktopcomputer" : "desktopcomputer"
            let image = NSImage(systemSymbolName: imageName, accessibilityDescription: "AirDesk")
            image?.isTemplate = true
            button.image = image
            button.appearsDisabled = !isSharing
        }
    }
}
