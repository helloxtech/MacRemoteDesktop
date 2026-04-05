import SwiftUI

@main
struct AirDeskApp: App {

    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

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
                    // airdesk://connect?host=x.x.x.x&port=7890
                    guard url.scheme == "airdesk", url.host == "connect",
                          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let hostParam = comps.queryItems?.first(where: { $0.name == "host" })?.value,
                          let portStr = comps.queryItems?.first(where: { $0.name == "port" })?.value,
                          let port = Int(portStr) else { return }
                    let host = DiscoveredHost(name: hostParam, host: hostParam, port: port)
                    appState.connect(to: host)
                }
        }
    }
}
