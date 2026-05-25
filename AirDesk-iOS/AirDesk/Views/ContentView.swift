import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.connectionState {
            case .disconnected:
                ConnectionView(draft: appState.connectionDraft)
            case .connecting:
                ConnectingView()
            case .connected:
                connectedRoot
            case .reconnecting:
                reconnectingRoot
            }
        }
    }

    @ViewBuilder
    private var connectedRoot: some View {
        if appState.sessionMode == .vnc {
            VNCRemoteDesktopView()
        } else {
            RemoteDesktopView()
        }
    }

    @ViewBuilder
    private var reconnectingRoot: some View {
        if appState.sessionMode == .vnc {
            VNCRemoteDesktopView()
        } else {
            ZStack(alignment: .top) {
                RemoteDesktopView()
                ReconnectingBanner()
            }
        }
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

struct ReconnectingBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text("Reconnecting...")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
            Button("Cancel") { appState.disconnect() }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white.opacity(0.82))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.black.opacity(0.82))
        .clipShape(Capsule())
        .padding(.top, 56)
    }
}
