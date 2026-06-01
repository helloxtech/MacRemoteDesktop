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
        .sheet(item: $appState.remoteAccessPaywall) { presentation in
            RemoteAccessPaywallView(
                presentation: presentation,
                appState: appState,
                subscriptionStore: appState.remoteAccessSubscriptions
            )
        }
    }

    @ViewBuilder
    private var connectedRoot: some View {
        if appState.sessionMode == .vnc {
            VNCRemoteDesktopView()
        } else if shouldShowNativeCanvas {
            RemoteDesktopView()
        } else {
            ConnectingView()
        }
    }

    @ViewBuilder
    private var reconnectingRoot: some View {
        if appState.sessionMode == .vnc {
            VNCRemoteDesktopView()
        } else if shouldShowNativeCanvas {
            ZStack(alignment: .top) {
                RemoteDesktopView()
                ConnectionStatusOverlay(kind: .reconnecting)
            }
        } else {
            ConnectingView()
        }
    }

    private var shouldShowNativeCanvas: Bool {
        RemoteCanvasPresentation.shouldShowNativeCanvas(
            hasMonitorInfo: !appState.monitors.isEmpty,
            hasReceivedFrame: appState.hasReceivedNativeFrame
        )
    }
}

struct ConnectingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let kind: ConnectionStatusKind = appState.sessionMode == .remoteAccess ? .remoteConnecting : .localConnecting
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ConnectionStatusCard(
                content: ConnectionStatusPresentation.content(
                    for: kind,
                    hostName: appState.selectedHost?.name
                ),
                showsCancel: true,
                cancel: { appState.disconnect() }
            )
            .padding(.horizontal, 24)
        }
    }
}

struct ConnectionStatusOverlay: View {
    @EnvironmentObject var appState: AppState
    let kind: ConnectionStatusKind

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
            ConnectionStatusCard(
                content: ConnectionStatusPresentation.content(
                    for: kind,
                    hostName: appState.selectedHost?.name
                ),
                showsCancel: true,
                cancel: { appState.disconnect() }
            )
            .padding(.horizontal, 24)
        }
    }
}

private struct ConnectionStatusCard: View {
    let content: ConnectionStatusContent
    let showsCancel: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .scaleEffect(1.35)
                .tint(.blue)
                .padding(.bottom, 2)

            VStack(spacing: 8) {
                Text(content.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)

                Text(content.message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(content.steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 10) {
                        Image(systemName: index == 0 ? "arrow.triangle.2.circlepath" : "circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(index == 0 ? .blue : .secondary.opacity(0.65))
                        Text(step)
                            .font(.subheadline.weight(index == 0 ? .semibold : .regular))
                            .foregroundColor(index == 0 ? .primary : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.tertiarySystemGroupedBackground))
            .cornerRadius(10)

            if showsCancel {
                Button("Cancel", action: cancel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.blue)
            }
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
    }
}
