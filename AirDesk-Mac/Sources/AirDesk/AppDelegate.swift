import AppKit
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController!
    private var webSocketServer: WebSocketServer!
    private var screenCaptureManager: ScreenCaptureManager!
    private var h264Encoder: H264Encoder!
    private var inputInjector: InputInjector!
    private var bonjourAdvertiser: BonjourAdvertiser!
    private var cloudflareTunnelManager: CloudflareTunnelManager!
    private var clipboardManager: ClipboardManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        inputInjector = InputInjector()
        h264Encoder = H264Encoder()
        webSocketServer = WebSocketServer(port: 7890)
        screenCaptureManager = ScreenCaptureManager()
        bonjourAdvertiser = BonjourAdvertiser(port: 7890)
        cloudflareTunnelManager = CloudflareTunnelManager()
        clipboardManager = ClipboardManager()

        // Bonjour is started only when the user enables sharing (inside StatusBarController)
        statusBarController = StatusBarController(
            server: webSocketServer,
            tunnel: cloudflareTunnelManager,
            capture: screenCaptureManager,
            bonjour: bonjourAdvertiser,
            clipboard: clipboardManager
        )

        h264Encoder.delegate = webSocketServer
        screenCaptureManager.delegate = h264Encoder
        webSocketServer.inputDelegate = inputInjector
        webSocketServer.encoder = h264Encoder
        webSocketServer.clipboardDelegate = clipboardManager
        webSocketServer.monitorInfoProvider = { [weak self] in
            self?.screenCaptureManager.currentMonitorInfos() ?? []
        }
        screenCaptureManager.monitorConfigurationDidChange = { [weak self] monitors in
            self?.h264Encoder.resetAllSessions()
            self?.webSocketServer.handleMonitorConfigurationChange(monitors)
        }
        webSocketServer.clientChangeHandler = { [weak self] count in
            DispatchQueue.main.async {
                self?.statusBarController.updateClientCount(count)
            }
        }
        clipboardManager.server = webSocketServer
        if InstallReminder.shouldAutoStartSharing() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.statusBarController.startSharingAutomatically()
            }
        }
        InstallReminder.scheduleIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenCaptureManager.stopCapture()
        webSocketServer.stop()
        bonjourAdvertiser.stop()
        cloudflareTunnelManager.stop()
        clipboardManager.stop()
    }
}

private enum InstallReminder {
    private static let lastShownSignatureKey = "airdesk.installReminder.lastShownSignature"

    static func shouldAutoStartSharing() -> Bool {
        isInstalledInApplications(Bundle.main.bundleURL.resolvingSymlinksInPath())
    }

    static func scheduleIfNeeded() {
        if shouldAutoStartSharing()
            && (!PermissionChecker.hasScreenRecordingPermission() || !PermissionChecker.hasAccessibilityPermission()) {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            presentIfNeeded()
        }
    }

    private static func presentIfNeeded() {
        guard let scenario = currentScenario() else { return }
        let signature = scenario.signature
        guard UserDefaults.standard.string(forKey: lastShownSignatureKey) != signature else { return }
        UserDefaults.standard.set(signature, forKey: lastShownSignatureKey)
        showAlert(for: scenario)
    }

    private static func currentScenario() -> Scenario? {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()

        if shouldRecommendApplications(for: bundleURL) {
            return .moveToApplications
        }

        if let mountedVolume = mountedInstallerVolume(excluding: bundleURL) {
            return .ejectInstaller(volumeURL: mountedVolume)
        }

        if let installerArchive = downloadedInstallerArchive() {
            return .cleanupArchive(archiveURL: installerArchive)
        }

        return nil
    }

    private static func shouldRecommendApplications(for bundleURL: URL) -> Bool {
        let path = bundleURL.path
        return path.hasPrefix("/Volumes/")
            || path.contains("/AppTranslocation/")
            || !isInstalledInApplications(bundleURL)
    }

    private static func isInstalledInApplications(_ bundleURL: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        let applicationRoots = [
            "/Applications/",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/"
        ]
        return applicationRoots.contains { path.hasPrefix($0) }
    }

    private static func mountedInstallerVolume(excluding bundleURL: URL) -> URL? {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let volumes = try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let currentBundlePath = bundleURL.standardizedFileURL.path
        return volumes.first { volumeURL in
            let candidateApp = volumeURL.appendingPathComponent("AirDesk.app")
            return FileManager.default.fileExists(atPath: candidateApp.path)
                && candidateApp.standardizedFileURL.path != currentBundlePath
        }
    }

    private static func downloadedInstallerArchive() -> URL? {
        let searchDirectories = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        ]

        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let candidates = searchDirectories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        return candidates
            .filter { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                let ext = url.pathExtension.lowercased()
                return name.contains("airdesk") && (ext == "dmg" || ext == "zip")
            }
            .sorted {
                let leftDate = (try? $0.resourceValues(forKeys: resourceKeys).contentModificationDate) ?? .distantPast
                let rightDate = (try? $1.resourceValues(forKeys: resourceKeys).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .first
    }

    private static func showAlert(for scenario: Scenario) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .informational

            switch scenario {
            case .moveToApplications:
                alert.messageText = "Move AirDesk to Applications"
                alert.informativeText = "AirDesk works best from your Applications folder.\n\nIf you're launching it from the installer or a temporary location, copy AirDesk to Applications first. After that, you can eject the installer disk image or delete the downloaded installer."
                alert.addButton(withTitle: "Open Applications")
                alert.addButton(withTitle: "Later")

                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
                }

            case .ejectInstaller(let volumeURL):
                alert.messageText = "Installer Disk Image Still Mounted"
                alert.informativeText = "AirDesk is already installed. You can eject the installer disk image now."
                alert.addButton(withTitle: "Eject Installer")
                alert.addButton(withTitle: "Later")

                if alert.runModal() == .alertFirstButtonReturn {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                    process.arguments = ["eject", volumeURL.path]
                    do {
                        try process.run()
                    } catch {
                        print("[AirDesk] Failed to eject installer volume: \(error)")
                    }
                }

            case .cleanupArchive(let archiveURL):
                alert.messageText = "Installer Download Can Be Deleted"
                alert.informativeText = "AirDesk is already installed in Applications. If you don't need the installer anymore, you can delete the downloaded package."
                alert.addButton(withTitle: "Show Installer")
                alert.addButton(withTitle: "Later")

                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
                }
            }
        }
    }

    private enum Scenario {
        case moveToApplications
        case ejectInstaller(volumeURL: URL)
        case cleanupArchive(archiveURL: URL)

        var signature: String {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            switch self {
            case .moveToApplications:
                return "move|\(version)|\(Bundle.main.bundleURL.standardizedFileURL.path)"
            case .ejectInstaller(let volumeURL):
                return "eject|\(version)|\(volumeURL.standardizedFileURL.path)"
            case .cleanupArchive(let archiveURL):
                return "cleanup|\(version)|\(archiveURL.standardizedFileURL.path)"
            }
        }
    }
}
