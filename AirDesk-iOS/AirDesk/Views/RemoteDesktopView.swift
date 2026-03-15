import SwiftUI

struct RemoteDesktopView: View {
    @EnvironmentObject var appState: AppState
    @State private var keyboardVisible = false
    @State private var toolbarVisible = false
    @State private var activeModifiers: Set<String> = []

    private func toggleToolbar() {
        withAnimation(.easeInOut(duration: 0.25)) { toolbarVisible.toggle() }
    }

    private func sendKey(_ keyCode: Int) {
        let mods = Array(activeModifiers)
        appState.webSocketClient?.sendKeyboardMessage(
            KeyboardMessage(keyCode: keyCode, modifiers: mods, action: "down"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            appState.webSocketClient?.sendKeyboardMessage(
                KeyboardMessage(keyCode: keyCode, modifiers: mods, action: "up"))
        }
        activeModifiers.removeAll()
    }

    private func toggleModifier(_ mod: String) {
        if activeModifiers.contains(mod) {
            activeModifiers.remove(mod)
        } else {
            activeModifiers.insert(mod)
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Active monitor — direct embedding avoids UIPageViewController's
            // internal UIScrollView which steals pan/tap gestures from our VC.
            if let monitor = appState.monitors.first(where: { $0.id == appState.activeMonitorIndex })
                ?? appState.monitors.first {
                MonitorView(monitor: monitor, displayIndex: monitor.id)
                    .id(monitor.id)
                    .ignoresSafeArea()
            }
        }
        // Toggle pill — always visible, top-right
        .overlay(alignment: .topTrailing) {
            Button(action: toggleToolbar) {
                Image(systemName: toolbarVisible ? "chevron.down" : "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 28)
                    .background(.ultraThinMaterial)
                    .cornerRadius(14)
            }
            .padding(.trailing, 8)
            .padding(.top, 6)
        }
        // Top bar — toggled
        .overlay(alignment: .top) {
            if toolbarVisible {
                HStack(spacing: 6) {
                    topButton("xmark") { appState.disconnect() }

                    if appState.monitors.count > 1 {
                        ForEach(appState.monitors) { monitor in
                            topMonitorButton(monitor)
                        }
                    }

                    topButton("keyboard", highlight: keyboardVisible) { keyboardVisible.toggle() }

                    topButton("plus.magnifyingglass") { appState.activeMonitorVC?.toggleZoom() }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        // Bottom control panel — toggled
        .overlay(alignment: .bottom) {
            if toolbarVisible {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        iconButton("arrow.left") { sendKey(123) }
                        iconButton("arrow.down") { sendKey(125) }
                        iconButton("arrow.up") { sendKey(126) }
                        iconButton("arrow.right") { sendKey(124) }

                        separator

                        labelButton("↵") { sendKey(36) }
                        labelButton("Esc") { sendKey(53) }
                        labelButton("Tab") { sendKey(48) }

                        separator

                        modifierKey("⌘", mod: "cmd")
                        modifierKey("⌃", mod: "ctrl")
                        modifierKey("⌥", mod: "opt")
                        modifierKey("⇧", mod: "shift")

                        separator

                        iconButton("doc.on.clipboard") { appState.pushClipboardToMac() }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .background(.ultraThinMaterial)
                .cornerRadius(14)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(
            KeyboardInputView(isActive: $keyboardVisible, activeModifiers: $activeModifiers, client: appState.webSocketClient)
                .frame(width: 0, height: 0)
        )
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Top Bar Buttons

    private func topButton(_ icon: String, highlight: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(highlight ? .yellow : .white)
                .frame(width: 32, height: 28)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
        }
    }

    private func topMonitorButton(_ monitor: MonitorInfo) -> some View {
        let selected = appState.activeMonitorIndex == monitor.id
        return Button { appState.selectMonitor(monitor.id) } label: {
            HStack(spacing: 3) {
                Image(systemName: "display")
                    .font(.system(size: 9))
                Text("\(monitor.id + 1)")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(selected ? .black : .white)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial))
            .cornerRadius(14)
            .animation(.spring(response: 0.3), value: selected)
        }
    }

    // MARK: - Bottom Toolbar Buttons

    private func iconButton(_ icon: String, highlight: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(highlight ? .yellow : .white)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(highlight ? 0.18 : 0.06))
                .cornerRadius(8)
        }
    }

    private func labelButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(minWidth: 36, minHeight: 36)
                .padding(.horizontal, 2)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
        }
    }

    private func modifierKey(_ symbol: String, mod: String) -> some View {
        let active = activeModifiers.contains(mod)
        return Button { toggleModifier(mod) } label: {
            Text(symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(active ? .black : .white)
                .frame(width: 38, height: 36)
                .background(active ? Color.white : Color.white.opacity(0.06))
                .cornerRadius(8)
                .animation(.easeInOut(duration: 0.15), value: active)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 2)
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
