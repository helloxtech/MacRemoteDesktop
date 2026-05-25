import SwiftUI
import UIKit
import AirDeskProtocol

struct RemoteDesktopView: View {
    @EnvironmentObject var appState: AppState
    @State private var keyboardVisible = false
    @State private var keyboardInset: CGFloat = 0
    @State private var toolbarVisible = true
    @State private var activeModifiers: Set<String> = []
    @State private var controlMode: RemoteControlMode = .touch
    @State private var diagnosticsExport: RemoteDiagnosticsExport?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isRegular: Bool { sizeClass == .regular }
    private var inputReady: Bool { appState.permissionStatus.canControl }
    private var effectiveTopInset: CGFloat {
        let windowInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
        return max(windowInset, 44)
    }
    private var effectiveBottomInset: CGFloat {
        let windowInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
        return max(windowInset, 8)
    }

    private func toggleToolbar() {
        withAnimation(.easeInOut(duration: 0.2)) { toolbarVisible.toggle() }
    }

    private func updateKeyboardInset(from note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        let safeBottom = window?.safeAreaInsets.bottom ?? 0
        let windowHeight = window?.bounds.height ?? UIScreen.main.bounds.height
        let overlap = max(0, windowHeight - frame.minY - safeBottom)
        guard abs(keyboardInset - overlap) > 0.5 else { return }
        withAnimation(.easeOut(duration: min(duration, 0.25))) {
            keyboardInset = overlap
        }
    }

    private func resetKeyboardInset() {
        guard keyboardInset != 0 else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            keyboardInset = 0
        }
    }

    private func closeRemote() {
        keyboardVisible = false
        toolbarVisible = true
        activeModifiers.removeAll()
        appState.disconnect()
    }

    private func sendKey(_ keyCode: Int) {
        guard inputReady else { return }
        let mods = Array(activeModifiers)
        let targetClient = appState.webSocketClient
        targetClient?.sendKeyboardMessage(
            KeyboardMessage(keyCode: keyCode, modifiers: mods, action: "down"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
            targetClient?.sendKeyboardMessage(
                KeyboardMessage(keyCode: keyCode, modifiers: mods, action: "up"))
        }
        activeModifiers.removeAll()
    }

    private func toggleModifier(_ mod: String) {
        guard inputReady else { return }
        if activeModifiers.contains(mod) {
            activeModifiers.remove(mod)
        } else {
            activeModifiers.insert(mod)
        }
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.black

                if let monitor = appState.monitors.first(where: { $0.id == appState.activeMonitorIndex })
                    ?? appState.monitors.first {
                    MonitorView(
                        monitor: monitor,
                        displayIndex: monitor.id,
                        controlMode: controlMode,
                        inputEnabled: inputReady
                    )
                        .id(monitor.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Group {
                    if toolbarVisible {
                        topChrome
                    } else {
                        toolbarRevealButton
                    }
                }
                .ignoresSafeArea(edges: .top)
                .padding(.top, effectiveTopInset + (isRegular ? 6 : 10))
            }
            .overlay(alignment: .bottom) {
                if toolbarVisible {
                    bottomToolbar
                        .ignoresSafeArea(edges: .bottom)
                        .padding(.bottom, effectiveBottomInset + keyboardInset + (isRegular ? 2 : 8))
                }
            }
            .overlay(
                KeyboardInputView(
                    isActive: $keyboardVisible,
                    activeModifiers: $activeModifiers,
                    client: appState.webSocketClient,
                    inputEnabled: inputReady
                )
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            )
            .statusBar(hidden: true)
            .hidePersistentSystemOverlays()
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                updateKeyboardInset(from: note)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                resetKeyboardInset()
            }
            .onChange(of: inputReady) { ready in
                if !ready {
                    keyboardVisible = false
                    activeModifiers.removeAll()
                }
            }
            .sheet(item: $diagnosticsExport) { export in
                DiagnosticsShareSheet(url: export.url)
            }
        }
        .ignoresSafeArea()
    }

    private var topChrome: some View {
        VStack(spacing: isRegular ? 8 : 6) {
            HStack(spacing: isRegular ? 10 : 6) {
                topButton("xmark", action: closeRemote)

                if appState.monitors.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: isRegular ? 8 : 5) {
                            ForEach(appState.monitors) { monitor in
                                topMonitorButton(monitor)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

                LatencyBadge(ms: appState.latencyMs, fps: appState.decodedFPS)

                topButton(toolbarVisible ? "chevron.down" : "ellipsis", action: toggleToolbar)
            }

            if appState.isHostLocked {
                Text(appState.hostStatusMessage ?? "Mac is locked")
                    .font(.system(size: isRegular ? 13 : 11, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, isRegular ? 8 : 6)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.72))
                    .clipShape(Capsule())
                    .padding(.horizontal, isRegular ? 8 : 6)
            }

            if !appState.permissionStatus.canControl {
                permissionBanner
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, isRegular ? 8 : 6)
        .padding(.bottom, isRegular ? 4 : 2)
    }

    private var permissionBanner: some View {
        HStack(spacing: isRegular ? 10 : 7) {
            Image(systemName: appState.permissionStatus.canView ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: isRegular ? 15 : 12, weight: .semibold))
                .foregroundColor(.yellow)

            Text(appState.permissionStatus.message)
                .font(.system(size: isRegular ? 13 : 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                let action = appState.permissionStatus.screenRecording
                    ? "open_accessibility_settings"
                    : "open_screen_recording_settings"
                appState.webSocketClient?.sendSystemAction(action)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape.fill")
                    Text("Fix")
                }
                .font(.system(size: isRegular ? 12 : 10, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, isRegular ? 10 : 8)
                .frame(height: isRegular ? 30 : 26)
                .background(Color.yellow)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, isRegular ? 12 : 9)
        .padding(.vertical, isRegular ? 8 : 7)
        .background(Color.black.opacity(0.82))
        .overlay(
            RoundedRectangle(cornerRadius: isRegular ? 14 : 12)
                .stroke(Color.yellow.opacity(0.45), lineWidth: 1)
        )
        .cornerRadius(isRegular ? 14 : 12)
        .padding(.horizontal, isRegular ? 8 : 6)
    }

    private var toolbarRevealButton: some View {
        HStack {
            Spacer()
            Button(action: toggleToolbar) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: isRegular ? 18 : 16, weight: .semibold))
                    Text("Tools")
                        .font(.system(size: isRegular ? 14 : 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, isRegular ? 12 : 10)
                .frame(height: isRegular ? 36 : 32)
                .background(Color.black.opacity(0.82))
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, isRegular ? 8 : 6)
    }

    private var bottomToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isRegular ? 8 : 5) {
                controlModePicker
                separator

                iconButton("keyboard", highlight: keyboardVisible, enabled: inputReady) { keyboardVisible.toggle() }
                iconButton("plus.magnifyingglass") { appState.activeMonitorVC?.toggleZoom() }
                iconButton("square.on.square", enabled: inputReady) { appState.webSocketClient?.sendSystemAction("mission_control") }

                separator

                iconButton("arrow.left", enabled: inputReady) { sendKey(123) }
                iconButton("arrow.down", enabled: inputReady) { sendKey(125) }
                iconButton("arrow.up", enabled: inputReady) { sendKey(126) }
                iconButton("arrow.right", enabled: inputReady) { sendKey(124) }

                separator

                labelButton("↵", enabled: inputReady) { sendKey(36) }
                labelButton("Esc", enabled: inputReady) { sendKey(53) }
                labelButton("Tab", enabled: inputReady) { sendKey(48) }

                separator

                modifierKey("⌘", mod: "cmd", enabled: inputReady)
                modifierKey("⌃", mod: "ctrl", enabled: inputReady)
                modifierKey("⌥", mod: "opt", enabled: inputReady)
                modifierKey("⇧", mod: "shift", enabled: inputReady)

                separator

                iconButton("doc.on.clipboard") { appState.pushClipboardToMac() }
                iconButton("doc.text.magnifyingglass") { exportDiagnostics() }
            }
            .padding(.horizontal, isRegular ? 12 : 8)
            .padding(.vertical, isRegular ? 8 : 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 0)
    }

    private var controlModePicker: some View {
        HStack(spacing: 3) {
            ForEach(RemoteControlMode.allCases) { mode in
                let selected = controlMode == mode
                Button { controlMode = mode } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: isRegular ? 13 : 11, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: isRegular ? 12 : 10, weight: .semibold))
                    }
                    .foregroundColor(selected ? .black : .white)
                    .frame(minWidth: isRegular ? 76 : 62, minHeight: isRegular ? 38 : 32)
                    .padding(.horizontal, isRegular ? 4 : 3)
                    .background(selected ? Color.white : Color.clear)
                    .cornerRadius(isRegular ? 8 : 7)
                }
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.08))
        .cornerRadius(isRegular ? 10 : 8)
    }

    private func topButton(_ icon: String, highlight: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: isRegular ? 15 : 12, weight: .semibold))
                .foregroundColor(highlight ? .yellow : .white)
                .frame(width: isRegular ? 40 : 32, height: isRegular ? 34 : 28)
                .background(Color.white.opacity(0.10))
                .cornerRadius(isRegular ? 17 : 14)
        }
    }

    private func topMonitorButton(_ monitor: MonitorInfo) -> some View {
        let selected = appState.activeMonitorIndex == monitor.id
        return Button { appState.selectMonitor(monitor.id) } label: {
            HStack(spacing: isRegular ? 4 : 3) {
                Image(systemName: "display")
                    .font(.system(size: isRegular ? 11 : 9))
                Text("\(monitor.id + 1)")
                    .font(.system(size: isRegular ? 13 : 11, weight: .semibold))
            }
            .foregroundColor(selected ? .black : .white)
            .padding(.horizontal, isRegular ? 10 : 7)
            .frame(height: isRegular ? 34 : 28)
            .background(selected ? Color.white : Color.white.opacity(0.10))
            .cornerRadius(isRegular ? 17 : 14)
        }
    }

    private func iconButton(_ icon: String, highlight: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: { if enabled { action() } }) {
            Image(systemName: icon)
                .font(.system(size: isRegular ? 17 : 13, weight: .semibold))
                .foregroundColor(enabled ? (highlight ? .yellow : .white) : .white.opacity(0.35))
                .frame(width: isRegular ? 46 : 36, height: isRegular ? 44 : 36)
                .background(Color.white.opacity(enabled ? (highlight ? 0.18 : 0.08) : 0.04))
                .cornerRadius(isRegular ? 10 : 8)
        }
        .disabled(!enabled)
    }

    private func labelButton(_ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: { if enabled { action() } }) {
            Text(label)
                .font(.system(size: isRegular ? 16 : 12, weight: .semibold))
                .foregroundColor(enabled ? .white : .white.opacity(0.35))
                .frame(minWidth: isRegular ? 48 : 36, minHeight: isRegular ? 44 : 36)
                .padding(.horizontal, 2)
                .background(Color.white.opacity(enabled ? 0.08 : 0.04))
                .cornerRadius(isRegular ? 10 : 8)
        }
        .disabled(!enabled)
    }

    private func modifierKey(_ symbol: String, mod: String, enabled: Bool = true) -> some View {
        let active = activeModifiers.contains(mod)
        return Button { toggleModifier(mod) } label: {
            Text(symbol)
                .font(.system(size: isRegular ? 20 : 15, weight: .semibold))
                .foregroundColor(enabled ? (active ? .black : .white) : .white.opacity(0.35))
                .frame(width: isRegular ? 48 : 38, height: isRegular ? 44 : 36)
                .background(enabled ? (active ? Color.white : Color.white.opacity(0.08)) : Color.white.opacity(0.04))
                .cornerRadius(isRegular ? 10 : 8)
        }
        .disabled(!enabled)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: isRegular ? 30 : 22)
            .padding(.horizontal, isRegular ? 4 : 2)
    }

    private func exportDiagnostics() {
        diagnosticsExport = RemoteDiagnosticsExport(url: AirDeskDiagnostics.shared.exportFile())
    }
}

private struct RemoteDiagnosticsExport: Identifiable {
    let id = UUID()
    let url: URL
}

private extension View {
    @ViewBuilder
    func hidePersistentSystemOverlays() -> some View {
        if #available(iOS 16.0, *) {
            self.persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }
}

struct LatencyBadge: View {
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
            Text("\(Int(fps.rounded()))fps")
                .font(.caption.weight(.medium))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.white.opacity(0.10))
        .cornerRadius(14)
    }
}
