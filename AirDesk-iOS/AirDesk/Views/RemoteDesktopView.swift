import SwiftUI

struct RemoteDesktopView: View {
    @EnvironmentObject var appState: AppState
    @State private var showMonitorPicker = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Monitor page view
            if !appState.monitors.isEmpty {
                TabView(selection: $appState.activeMonitorIndex) {
                    ForEach(appState.monitors) { monitor in
                        MonitorView(monitor: monitor, displayIndex: monitor.id)
                            .tag(monitor.id)
                            .ignoresSafeArea()
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }

            // Top toolbar overlay
            VStack {
                HStack {
                    Button(action: { appState.disconnect() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text("Disconnect")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                    }

                    Spacer()

                    if appState.monitors.count > 1 {
                        Text(appState.monitors[safe: appState.activeMonitorIndex]?.name ?? "Display")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                    }

                    Spacer()

                    // Latency badge
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text("Local")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                // Page dots for multi-monitor
                if appState.monitors.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(appState.monitors) { monitor in
                            Circle()
                                .fill(appState.activeMonitorIndex == monitor.id ? Color.white : Color.white.opacity(0.4))
                                .frame(width: appState.activeMonitorIndex == monitor.id ? 8 : 6,
                                       height: appState.activeMonitorIndex == monitor.id ? 8 : 6)
                                .onTapGesture { appState.selectMonitor(monitor.id) }
                                .animation(.spring(response: 0.3), value: appState.activeMonitorIndex)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
