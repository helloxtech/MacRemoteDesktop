import AppKit
#if !APP_STORE
import Sparkle
#endif
import UniformTypeIdentifiers

class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu: NSMenu
#if !APP_STORE
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
#endif
    private var isSharing = false

    private let titleItem: NSMenuItem
    private let versionItem: NSMenuItem
#if !APP_STORE
    private let checkForUpdatesItem: NSMenuItem
#endif
    private let toggleItem: NSMenuItem
    private let tunnelToggleItem: NSMenuItem
    private let clientCountItem: NSMenuItem
    private let tunnelURLItem: NSMenuItem
    private let copyTunnelURLItem: NSMenuItem
    private let tunnelNoticeItem: NSMenuItem
    private let permissionSummaryItem: NSMenuItem
    private let screenRecordingItem: NSMenuItem
    private let accessibilityItem: NSMenuItem
    private let openScreenRecordingItem: NSMenuItem
    private let openAccessibilityItem: NSMenuItem
    private let refreshPermissionsItem: NSMenuItem
    private let pairingCodeItem: NSMenuItem
    private let regeneratePairingCodeItem: NSMenuItem
    private let resetTrustedDevicesItem: NSMenuItem
    private let exportDiagnosticsItem: NSMenuItem
    private let reportIssueItem: NSMenuItem

    private let server: WebSocketServer
    private let tunnel: CloudflareTunnelManager
    private let capture: ScreenCaptureManager
    private let bonjour: BonjourAdvertiser
    private let clipboard: ClipboardManager
    private let pairing: PairingManager
    private var currentTunnelURL: String?

    init(server: WebSocketServer, tunnel: CloudflareTunnelManager, capture: ScreenCaptureManager,
         bonjour: BonjourAdvertiser, clipboard: ClipboardManager, pairing: PairingManager) {
        self.server = server
        self.tunnel = tunnel
        self.capture = capture
        self.bonjour = bonjour
        self.clipboard = clipboard
        self.pairing = pairing

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()

        titleItem = NSMenuItem(title: "AirDesk", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        versionItem = NSMenuItem(title: AppVersion.menuTitle, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
#if !APP_STORE
        checkForUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
#endif

        toggleItem = NSMenuItem(title: "Start Sharing", action: #selector(toggleSharing), keyEquivalent: "s")
        clientCountItem = NSMenuItem(title: "No clients connected", action: nil, keyEquivalent: "")
        clientCountItem.isEnabled = false
        tunnelToggleItem = NSMenuItem(title: "Enable Remote Access (Tunnel)", action: #selector(toggleTunnel), keyEquivalent: "t")
        tunnelURLItem = NSMenuItem(title: "Tunnel: Not active", action: nil, keyEquivalent: "")
        tunnelURLItem.isEnabled = false
        copyTunnelURLItem = NSMenuItem(title: "Copy Tunnel URL", action: #selector(copyTunnelURL), keyEquivalent: "")
        copyTunnelURLItem.isHidden = true
        tunnelNoticeItem = NSMenuItem(title: "Note: Free tunnel relay can be slower, unavailable, or change URL.", action: nil, keyEquivalent: "")
        tunnelNoticeItem.isEnabled = false
        tunnelNoticeItem.isHidden = true
        permissionSummaryItem = NSMenuItem(title: "Setup: Checking...", action: nil, keyEquivalent: "")
        permissionSummaryItem.isEnabled = false
        screenRecordingItem = NSMenuItem(title: "Screen Recording: Checking...", action: nil, keyEquivalent: "")
        screenRecordingItem.isEnabled = false
        accessibilityItem = NSMenuItem(title: "Keyboard & Mouse: Checking...", action: nil, keyEquivalent: "")
        accessibilityItem.isEnabled = false
        openScreenRecordingItem = NSMenuItem(title: "Open Screen Recording Settings", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        openAccessibilityItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        refreshPermissionsItem = NSMenuItem(title: "Refresh Permission Status", action: #selector(refreshPermissions), keyEquivalent: "")
        pairingCodeItem = NSMenuItem(title: "Pairing Code: \(pairing.currentCode)", action: nil, keyEquivalent: "")
        pairingCodeItem.isEnabled = false
        regeneratePairingCodeItem = NSMenuItem(title: "Regenerate Pairing Code", action: #selector(regeneratePairingCode), keyEquivalent: "")
        resetTrustedDevicesItem = NSMenuItem(title: "Reset Trusted Devices", action: #selector(resetTrustedDevices), keyEquivalent: "")
        exportDiagnosticsItem = NSMenuItem(title: "Export Diagnostics...", action: #selector(exportDiagnostics), keyEquivalent: "")
        reportIssueItem = NSMenuItem(title: "Report Issue...", action: #selector(reportIssue), keyEquivalent: "")

        super.init()

#if !APP_STORE
        checkForUpdatesItem.target = self
#endif
        toggleItem.target = self
        tunnelToggleItem.target = self
        copyTunnelURLItem.target = self
        openScreenRecordingItem.target = self
        openAccessibilityItem.target = self
        refreshPermissionsItem.target = self
        regeneratePairingCodeItem.target = self
        resetTrustedDevicesItem.target = self
        exportDiagnosticsItem.target = self
        reportIssueItem.target = self

        menu.delegate = self
        menu.addItem(titleItem)
        menu.addItem(versionItem)
#if !APP_STORE
        menu.addItem(checkForUpdatesItem)
#endif
        menu.addItem(NSMenuItem.separator())
        menu.addItem(toggleItem)
        menu.addItem(clientCountItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(permissionSummaryItem)
        menu.addItem(screenRecordingItem)
        menu.addItem(accessibilityItem)
        menu.addItem(openScreenRecordingItem)
        menu.addItem(openAccessibilityItem)
        menu.addItem(refreshPermissionsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(pairingCodeItem)
        menu.addItem(regeneratePairingCodeItem)
        menu.addItem(resetTrustedDevicesItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(tunnelToggleItem)
        menu.addItem(tunnelURLItem)
        menu.addItem(copyTunnelURLItem)
        menu.addItem(tunnelNoticeItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(exportDiagnosticsItem)
        menu.addItem(reportIssueItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit AirDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.autoenablesItems = false
        updateIcon()
        updatePermissionItems()

        tunnel.urlHandler = { [weak self] url in
            DispatchQueue.main.async {
                if let url {
                    self?.currentTunnelURL = url
                    self?.tunnelURLItem.title = "Tunnel: \(url)"
                    self?.tunnelToggleItem.title = "Disable Remote Access"
                    self?.copyTunnelURLItem.isHidden = false
                    self?.tunnelNoticeItem.isHidden = false
                } else {
                    self?.currentTunnelURL = nil
                    self?.tunnelURLItem.title = "Tunnel: Not active"
                    self?.tunnelToggleItem.title = "Enable Remote Access (Tunnel)"
                    self?.copyTunnelURLItem.isHidden = true
                    self?.tunnelNoticeItem.isHidden = true
                }
            }
        }

        pairing.codeDidChange = { [weak self] code in
            self?.pairingCodeItem.title = "Pairing Code: \(code)"
        }
    }

    @objc private func toggleSharing() {
        isSharing ? stopSharing() : startSharing()
    }

    func startSharingAutomatically() {
        guard !isSharing else { return }
        startSharing()
    }

    @objc private func toggleTunnel() {
        // Tunnel only makes sense when sharing is active
        if !isSharing { startSharing() }
        guard isSharing else { return }
        if tunnel.isRunning {
            tunnel.stop()
        } else {
            guard confirmRemoteAccessNotice() else { return }
            tunnelToggleItem.title = "Starting Remote Access..."
            tunnelNoticeItem.isHidden = false
            if !tunnel.start() {
                showTunnelStartFailed()
            }
        }
    }

    private func confirmRemoteAccessNotice() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remote Access uses a free Cloudflare tunnel"
        alert.informativeText = "This tunnel is best effort. The relay URL can change, and speed or availability may be limited. If it stops working, try again later or use local Wi-Fi."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showTunnelStartFailed() {
        let alert = NSAlert()
        alert.messageText = "Remote Access could not start"
        alert.informativeText = "Install cloudflared with Homebrew first: brew install cloudflare/cloudflare/cloudflared"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func copyTunnelURL() {
        guard let currentTunnelURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentTunnelURL, forType: .string)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionItems()
    }

    @objc private func openScreenRecordingSettings() {
        PermissionChecker.openScreenRecordingSettings()
    }

    @objc private func openAccessibilitySettings() {
        PermissionChecker.openAccessibilitySettings()
    }

    @objc private func refreshPermissions() {
        updatePermissionItems()
        if isSharing, PermissionChecker.hasScreenRecordingPermission() {
            capture.startCapture()
        }
        server.broadcastPermissionStatus()
    }

    @objc private func regeneratePairingCode() {
        pairing.regenerateCode()
    }

    @objc private func resetTrustedDevices() {
        pairing.resetTrustedClients()
    }

    @objc private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AirDesk-Mac-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try AirDeskDiagnostics.shared.writeExport(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                AirDeskDiagnostics.shared.record("Diagnostics export failed: \(error.localizedDescription)")
            }
        }
    }

#if !APP_STORE
    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
#endif

    @objc private func reportIssue() {
        NSWorkspace.shared.open(AppSupport.reportIssueURL())
    }

    private func startSharing() {
        print("startSharing called")
        AirDeskDiagnostics.shared.record("Start sharing")
        server.start()
        bonjour.start()
        clipboard.start()

        if PermissionChecker.ensureScreenRecordingPermissionForSharing() {
            capture.startCapture()
        } else {
            AirDeskDiagnostics.shared.record("Sharing started without Screen Recording permission")
        }
        PermissionChecker.requestAccessibilityPermissionIfNeeded()
        isSharing = true
        toggleItem.title = "Stop Sharing"
        updateIcon()
        updatePermissionItems()
        server.broadcastPermissionStatus()
        print("startSharing done")
    }

    private func stopSharing() {
        AirDeskDiagnostics.shared.record("Stop sharing")
        server.stop()
        capture.stopCapture()
        bonjour.stop()
        clipboard.stop()
        tunnel.stop()
        isSharing = false
        toggleItem.title = "Start Sharing"
        updateIcon()
        updatePermissionItems()
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

    private func updatePermissionItems() {
        let status = PermissionChecker.currentStatusMessage()
        permissionSummaryItem.title = status.canControl ? "Setup: Ready" : "Setup: Needs Attention"
        screenRecordingItem.title = "Screen Recording: \(status.screenRecording ? "Granted" : "Missing")"
        accessibilityItem.title = "Keyboard & Mouse: \(status.accessibility ? "Granted" : "Missing")"
        openScreenRecordingItem.isHidden = status.screenRecording
        openAccessibilityItem.isHidden = status.accessibility
    }
}

private enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var display: String {
        "\(short) (\(build))"
    }

    static var menuTitle: String {
        "Version \(display)"
    }
}

private enum AppSupport {
    static func reportIssueURL() -> URL {
        var components = URLComponents(string: "https://github.com/helloxtech/MacRemoteDesktop/issues/new")!
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
        AirDesk version: \(AppVersion.display)
        macOS: \(os)

        What happened?


        What did you expect?


        Steps to reproduce:
        1.
        2.
        3.

        If possible, attach an AirDesk diagnostics export from the Mac menu.
        """
        components.queryItems = [
            URLQueryItem(name: "title", value: "AirDesk issue"),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url ?? URL(string: "https://github.com/helloxtech/MacRemoteDesktop/issues")!
    }
}
