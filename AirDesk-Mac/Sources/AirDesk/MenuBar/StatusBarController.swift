import AppKit

class StatusBarController: NSObject {

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var isSharing = false

    private let titleItem: NSMenuItem
    private let toggleItem: NSMenuItem
    private let tunnelToggleItem: NSMenuItem
    private let clientCountItem: NSMenuItem
    private let tunnelURLItem: NSMenuItem

    private let server: WebSocketServer
    private let tunnel: CloudflareTunnelManager
    private let capture: ScreenCaptureManager
    private let bonjour: BonjourAdvertiser
    private let clipboard: ClipboardManager

    init(server: WebSocketServer, tunnel: CloudflareTunnelManager, capture: ScreenCaptureManager,
         bonjour: BonjourAdvertiser, clipboard: ClipboardManager) {
        self.server = server
        self.tunnel = tunnel
        self.capture = capture
        self.bonjour = bonjour
        self.clipboard = clipboard

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()

        titleItem = NSMenuItem(title: "AirDesk", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false

        toggleItem = NSMenuItem(title: "Start Sharing", action: #selector(toggleSharing), keyEquivalent: "s")
        clientCountItem = NSMenuItem(title: "No clients connected", action: nil, keyEquivalent: "")
        clientCountItem.isEnabled = false
        tunnelToggleItem = NSMenuItem(title: "Enable Remote Access (Tunnel)", action: #selector(toggleTunnel), keyEquivalent: "t")
        tunnelURLItem = NSMenuItem(title: "Tunnel: Not active", action: nil, keyEquivalent: "")
        tunnelURLItem.isEnabled = false

        super.init()

        toggleItem.target = self
        tunnelToggleItem.target = self

        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(toggleItem)
        menu.addItem(clientCountItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(tunnelToggleItem)
        menu.addItem(tunnelURLItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit AirDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateIcon()

        tunnel.urlHandler = { [weak self] url in
            DispatchQueue.main.async {
                if let url {
                    self?.tunnelURLItem.title = "Tunnel: \(url)"
                    self?.tunnelToggleItem.title = "Disable Remote Access"
                } else {
                    self?.tunnelURLItem.title = "Tunnel: Not active"
                    self?.tunnelToggleItem.title = "Enable Remote Access (Tunnel)"
                }
            }
        }
    }

    @objc private func toggleSharing() {
        isSharing ? stopSharing() : startSharing()
    }

    @objc private func toggleTunnel() {
        // Tunnel only makes sense when sharing is active
        if !isSharing { startSharing() }
        tunnel.start()
    }

    private func startSharing() {
        server.start()
        capture.startCapture()
        bonjour.start()
        clipboard.start()
        isSharing = true
        toggleItem.title = "Stop Sharing"
        updateIcon()
    }

    private func stopSharing() {
        server.stop()
        capture.stopCapture()
        bonjour.stop()
        clipboard.stop()
        tunnel.stop()
        isSharing = false
        toggleItem.title = "Start Sharing"
        updateIcon()
    }

    func updateClientCount(_ count: Int) {
        DispatchQueue.main.async {
            self.clientCountItem.title = count == 0
                ? "No clients connected"
                : "\(count) client\(count > 1 ? "s" : "") connected"
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        // Different icon for active vs idle — fixed copy-paste bug
        let symbolName = isSharing ? "desktopcomputer.and.arrow.down" : "desktopcomputer"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AirDesk")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !isSharing
    }
}
