import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.connectionState {
            case .disconnected:
                ConnectionView()
            case .connecting:
                ConnectingView()
            case .connected:
                RemoteDesktopView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.connectionState)
    }
}

struct ConnectingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("Connecting to \(appState.selectedHost?.name ?? "Mac")...")
                    .foregroundColor(.white)
                    .font(.headline)
                Button("Cancel") { appState.disconnect() }
                    .foregroundColor(.gray)
            }
        }
    }
}
