import SwiftUI

struct RemoteDesktopView: View {
    @EnvironmentObject var appState: AppState
    @State private var showMonitorPicker = false
    @State private var keyboardVisible = false

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

                    // Keyboard toggle
                    Button(action: { keyboardVisible.toggle() }) {
                        Image(systemName: "keyboard")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(keyboardVisible ? .yellow : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                    }

                    // Paste to Mac
                    Button(action: { appState.pushClipboardToMac() }) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                    }

                    // Latency badge
                    LatencyBadge(ms: appState.latencyMs)
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
        .overlay(
            KeyboardInputView(isActive: $keyboardVisible, client: appState.webSocketClient)
                .frame(width: 0, height: 0)
        )
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct LatencyBadge: View {
    let ms: Int

    private var color: Color {
        if ms == 0 { return .green }
        if ms < 50 { return .green }
        if ms < 150 { return .yellow }
        return .red
    }

    private var label: String {
        ms == 0 ? "—" : "\(ms)ms"
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .animation(.easeInOut(duration: 0.3), value: ms)
    }
}
