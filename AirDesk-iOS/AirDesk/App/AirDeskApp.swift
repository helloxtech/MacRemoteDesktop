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
                    appState.startStoreServices()
                    appState.startDiscovery()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        // Recover the live session (decoder + socket) after the app
                        // returns from the background, and refresh discovery when idle.
                        appState.handleAppDidBecomeActive()
                    }
                }
                .onOpenURL { url in
                    guard let request = AirDeskConnectLink.request(from: url) else { return }
                    appState.connect(using: request)
                }
        }
    }
}
