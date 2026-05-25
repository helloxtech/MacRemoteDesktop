import SwiftUI

@main
struct AirDeskApp: App {

    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AirDeskDiagnostics.shared.installLifecycleObservers()
        AirDeskDiagnostics.shared.record("App launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    appState.startDiscovery()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active && appState.connectionState == .disconnected {
                        appState.startDiscovery()
                    }
                }
                .onOpenURL { url in
                    // Local:  airdesk://connect?host=x.x.x.x&port=7890
                    // Remote: airdesk://connect?url=https://example.trycloudflare.com
                    guard url.scheme == "airdesk", url.host == "connect",
                          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                    let pairing = comps.queryItems?.first(where: { $0.name == "pairing" })?.value

                    if let remoteParam = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                       let remoteURL = RemoteAccessURLNormalizer.webSocketURL(from: remoteParam) {
                        let hostName = remoteURL.host ?? remoteURL.absoluteString
                        let port = remoteURL.port ?? (remoteURL.scheme == "ws" ? 80 : 443)
                        let host = DiscoveredHost(name: hostName, host: hostName, port: port)
                        appState.connect(using: ConnectionRequest(
                            mode: .remoteAccess,
                            host: host,
                            pairingCode: pairing,
                            vncUsername: nil,
                            vncPassword: nil,
                            remoteWebSocketURL: remoteURL
                        ))
                        return
                    }

                    guard let hostParam = comps.queryItems?.first(where: { $0.name == "host" })?.value,
                          let portStr = comps.queryItems?.first(where: { $0.name == "port" })?.value,
                          let port = Int(portStr) else { return }
                    let host = DiscoveredHost(name: hostParam, host: hostParam, port: port)
                    appState.connect(to: host, pairingCode: pairing)
                }
        }
    }
}
