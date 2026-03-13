import SwiftUI

@main
struct AirDeskApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    appState.startDiscovery()
                }
        }
    }
}
