import AppKit
import CoreImage
#if !APP_STORE
import Sparkle
#endif
import UniformTypeIdentifiers

class StatusBarController: NSObject, NSMenuDelegate, NSWindowDelegate {

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
    private let showTunnelQRCodeItem: NSMenuItem
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
    private var shouldShowTunnelQRCodeWhenReady = false
    private var qrPanel: NSPanel?
    private var currentSetupLinkForPanel: String?

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
        showTunnelQRCodeItem = NSMenuItem(title: "Show Connect QR Code...", action: #selector(showTunnelQRCode), keyEquivalent: "")
        showTunnelQRCodeItem.isHidden = true
        tunnelNoticeItem = NSMenuItem(title: "Note: Keep Remote Access on to keep this link active.", action: nil, keyEquivalent: "")
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
        showTunnelQRCodeItem.target = self
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
        menu.addItem(showTunnelQRCodeItem)
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
                    self?.showTunnelQRCodeItem.isHidden = false
                    self?.copyTunnelURLItem.isHidden = false
                    self?.tunnelNoticeItem.isHidden = false
                    if self?.shouldShowTunnelQRCodeWhenReady == true {
                        self?.shouldShowTunnelQRCodeWhenReady = false
                        self?.showTunnelQRCode()
                    }
                } else {
                    self?.currentTunnelURL = nil
                    self?.tunnelURLItem.title = "Tunnel: Not active"
                    self?.tunnelToggleItem.title = "Enable Remote Access (Tunnel)"
                    self?.showTunnelQRCodeItem.isHidden = true
                    self?.copyTunnelURLItem.isHidden = true
                    self?.tunnelNoticeItem.isHidden = true
                    self?.shouldShowTunnelQRCodeWhenReady = false
                    self?.closeTunnelQRCodePanel()
                }
            }
        }

        pairing.codeDidChange = { [weak self] code in
            DispatchQueue.main.async {
                self?.pairingCodeItem.title = "Pairing Code: \(code)"
                if self?.qrPanel != nil, self?.currentTunnelURL != nil {
                    self?.showTunnelQRCode()
                }
            }
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
            shouldShowTunnelQRCodeWhenReady = true
            showTunnelQRCodeStartingPanel()
            if !tunnel.start() {
                shouldShowTunnelQRCodeWhenReady = false
                closeTunnelQRCodePanel()
                showTunnelStartFailed()
            }
        }
    }

    private func confirmRemoteAccessNotice() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remote Access may be slower"
        alert.informativeText = "Remote Access lets you connect when you are away from the same Wi-Fi. Scan once from your iPhone to save this Mac for next time. Keep Remote Access on to keep the same link active."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Turn On Remote Access")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showTunnelStartFailed() {
        let alert = NSAlert()
        alert.messageText = "Remote Access could not start"
        alert.informativeText = "AirDesk could not find its bundled tunnel helper. Reinstall AirDesk from the official website, then try Remote Access again."
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

    @objc private func showTunnelQRCode() {
        guard let setupURL = currentRemoteSetupURL else {
            showTunnelQRCodeStartingPanel()
            return
        }
        let setupLink = setupURL.absoluteString

        qrPanel?.close()
        currentSetupLinkForPanel = setupLink

        let panel = makeTunnelQRCodePanel(setupLink: setupLink)
        qrPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func showTunnelQRCodeStartingPanel() {
        qrPanel?.close()
        currentSetupLinkForPanel = nil

        let panel = makeTunnelQRCodePanel(setupLink: nil)
        qrPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeTunnelQRCodePanel(setupLink: String?) -> NSPanel {
        let contentSize = NSSize(width: 392, height: 620)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = setupLink == nil ? "Starting Remote Access" : "Scan to Connect"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = self

        let root = NSView(frame: NSRect(origin: .zero, size: contentSize))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let appIconView = NSImageView(image: NSApp.applicationIconImage)
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            appIconView.widthAnchor.constraint(equalToConstant: 64),
            appIconView.heightAnchor.constraint(equalToConstant: 64)
        ])

        let titleLabel = NSTextField(labelWithString: setupLink == nil ? "Starting Remote Access" : "Scan to Connect")
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let messageText = setupLink == nil
            ? "Keep this window open. The QR code will appear as soon as the secure link is ready."
            : "Open AirDesk on iPhone and scan this QR code. After the first successful connection, the iPhone saves this Mac for next time."
        let messageLabel = NSTextField(wrappingLabelWithString: messageText)
        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 15, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let qrView: NSView
        if let setupLink, let qrImage = QRCodeGenerator.image(for: setupLink, size: 232) {
            let imageView = NSImageView(image: qrImage)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 232),
                imageView.heightAnchor.constraint(equalToConstant: 232)
            ])
            qrView = imageView
        } else if setupLink == nil {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .large
            progress.startAnimation(nil)
            progress.translatesAutoresizingMaskIntoConstraints = false

            let statusLabel = NSTextField(wrappingLabelWithString: "Creating secure link...")
            statusLabel.alignment = .center
            statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            statusLabel.widthAnchor.constraint(equalToConstant: 220).isActive = true

            let placeholderStack = NSStackView(views: [progress, statusLabel])
            placeholderStack.orientation = .vertical
            placeholderStack.alignment = .centerX
            placeholderStack.spacing = 14
            placeholderStack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                placeholderStack.widthAnchor.constraint(equalToConstant: 232),
                placeholderStack.heightAnchor.constraint(equalToConstant: 232)
            ])
            qrView = placeholderStack
        } else {
            let fallbackLabel = NSTextField(wrappingLabelWithString: "QR code could not be generated. Use Copy Setup Link instead.")
            fallbackLabel.alignment = .center
            fallbackLabel.textColor = .secondaryLabelColor
            fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                fallbackLabel.widthAnchor.constraint(equalToConstant: 232),
                fallbackLabel.heightAnchor.constraint(equalToConstant: 232)
            ])
            qrView = fallbackLabel
        }

        let pairingLabel = NSTextField(labelWithString: "Pairing Code: \(pairing.currentCode)")
        pairingLabel.alignment = .center
        pairingLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        pairingLabel.lineBreakMode = .byTruncatingTail

        let copyButton = NSButton(title: setupLink == nil ? "Preparing Setup Link..." : "Copy Setup Link", target: self, action: #selector(copyRemoteSetupLinkFromPanel))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .large
        copyButton.keyEquivalent = "\r"
        copyButton.isEnabled = setupLink != nil
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            copyButton.widthAnchor.constraint(equalToConstant: 320),
            copyButton.heightAnchor.constraint(equalToConstant: 40)
        ])

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeTunnelQRCodePanel))
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .large
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 320),
            closeButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        stack.addArrangedSubview(appIconView)
        stack.setCustomSpacing(18, after: appIconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.setCustomSpacing(18, after: messageLabel)
        stack.addArrangedSubview(qrView)
        stack.addArrangedSubview(pairingLabel)
        stack.setCustomSpacing(18, after: pairingLabel)
        stack.addArrangedSubview(copyButton)
        stack.addArrangedSubview(closeButton)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        ])

        panel.contentView = root
        return panel
    }

    @objc private func copyRemoteSetupLinkFromPanel() {
        guard let currentSetupLinkForPanel else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentSetupLinkForPanel, forType: .string)
    }

    @objc private func closeTunnelQRCodePanel() {
        qrPanel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow == qrPanel else { return }
        qrPanel = nil
        currentSetupLinkForPanel = nil
    }

    private var currentRemoteSetupURL: URL? {
        guard let currentTunnelURL else { return nil }
        var components = URLComponents()
        components.scheme = "airdesk"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "url", value: currentTunnelURL),
            URLQueryItem(name: "pairing", value: pairing.currentCode)
        ]
        return components.url
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

private enum QRCodeGenerator {
    static func image(for text: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let scale = size / outputImage.extent.width
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
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
