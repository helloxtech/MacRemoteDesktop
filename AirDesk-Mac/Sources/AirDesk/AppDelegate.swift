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
        PermissionChecker.requestPermissionsIfNeeded()

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
            self?.screenCaptureManager.monitorInfos ?? []
        }
        webSocketServer.clientChangeHandler = { [weak self] count in
            DispatchQueue.main.async {
                self?.statusBarController.updateClientCount(count)
            }
        }
        clipboardManager.server = webSocketServer
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenCaptureManager.stopCapture()
        webSocketServer.stop()
        bonjourAdvertiser.stop()
        cloudflareTunnelManager.stop()
        clipboardManager.stop()
    }
}
