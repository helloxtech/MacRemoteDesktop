import SwiftUI

struct RemoteDesktopView: View {
    @EnvironmentObject var appState: AppState
    @State private var showMonitorPicker = false
    @State private var keyboardVisible = false
    @State private var toolbarOpacity: Double = 1.0
    @State private var toolbarFadeTask: Task<Void, Never>?

    private func resetFadeTimer() {
        withAnimation(.easeInOut(duration: 0.2)) { toolbarOpacity = 1.0 }
        toolbarFadeTask?.cancel()
        toolbarFadeTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.6)) { toolbarOpacity = 0.12 }
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Monitor page view
            if !appState.monitors.isEmpty {
                TabView(selection: $appState.activeMonitorIndex) {
                    ForEach(appState.monitors) { monitor in
                        MonitorView(monitor: monitor, displayIndex: monitor.id, onInteraction: resetFadeTimer)
                            .tag(monitor.id)
                            .ignoresSafeArea()
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
        }
        // Toolbar overlay — placed OUTSIDE ZStack so its UIKit views are guaranteed above MonitorView
        .overlay {
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

                    // Latency + FPS badges
                    LatencyBadge(ms: appState.latencyMs, fps: appState.decodedFPS)
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
            .opacity(toolbarOpacity)
        }
        .overlay(
            KeyboardInputView(isActive: $keyboardVisible, client: appState.webSocketClient)
                .frame(width: 0, height: 0)
        )
        .onAppear { resetFadeTimer() }
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
    let fps: Double

    private var color: Color {
        if ms == 0 { return .green }
        if ms < 50 { return .green }
        if ms < 150 { return .yellow }
        return .red
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            if ms > 0 {
                Text("\(ms)ms")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
            }
            if fps > 0 {
                Text("·")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                Text("\(Int(fps.rounded()))fps")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.8))
            }
            if ms == 0 && fps == 0 {
                Text("—")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .animation(.easeInOut(duration: 0.3), value: ms)
    }
}
