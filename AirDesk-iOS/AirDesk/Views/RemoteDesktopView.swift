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

                if !appState.hasReceivedNativeFrame {
                    waitingForFrameOverlay
                }
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                // Single, always-visible header row: close · screen switcher ·
                // latency · toolbar toggle. The screen switcher stays reachable
                // here regardless of whether the bottom toolbar is shown.
                VStack(spacing: isRegular ? 8 : 6) {
                    topBar
                    if appState.isHostLocked {
                        hostLockedBanner
                    }
                    if !appState.permissionStatus.canControl {
                        permissionBanner
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
                .padding(.horizontal, isRegular ? 8 : 6)
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

    private var topBar: some View {
        HStack(spacing: isRegular ? 8 : 5) {
            topButton("xmark", action: closeRemote)

            if appState.monitors.count > 1 {
                screenStepButton("chevron.left") { stepMonitor(by: -1) }
                    .accessibilityLabel("Previous screen")

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: isRegular ? 8 : 5) {
                            ForEach(sortedMonitors) { monitor in
                                screenChip(monitor).id(monitor.id)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .onChange(of: appState.activeMonitorIndex) { idx in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Switch Mac screen")

                screenStepButton("chevron.right") { stepMonitor(by: 1) }
                    .accessibilityLabel("Next screen")
            } else {
                Spacer(minLength: 0)
            }

            LatencyBadge(ms: appState.latencyMs, fps: appState.decodedFPS)

            topButton(toolbarVisible ? "chevron.down" : "chevron.up", action: toggleToolbar)
        }
        .padding(.horizontal, isRegular ? 8 : 6)
        .padding(.vertical, isRegular ? 5 : 4)
        .background(Color.black.opacity(0.55))
        .overlay(
            Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1)
        )
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 3)
    }

    private var hostLockedBanner: some View {
        Text(appState.hostStatusMessage ?? "Mac is locked")
            .font(.system(size: isRegular ? 13 : 11, weight: .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, isRegular ? 12 : 9)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.72))
            .clipShape(Capsule())
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
        .background(Color.black.opacity(0.58))
        .overlay(
            RoundedRectangle(cornerRadius: isRegular ? 18 : 14)
                .stroke(Color.white.opacity(0.20), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: isRegular ? 18 : 14))
        .shadow(color: .black.opacity(0.50), radius: 10, x: 0, y: 4)
        .padding(.horizontal, isRegular ? 8 : 6)
        .padding(.bottom, 0)
    }

    private var controlModePicker: some View {
        HStack(spacing: 3) {
            ForEach(RemoteControlMode.allCases) { mode in
                let selected = controlMode == mode
                Button {
                    guard controlMode != mode else { return }
                    controlMode = mode
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: isRegular ? 13 : 11, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: isRegular ? 12 : 10, weight: .semibold))
                    }
                    .foregroundColor(remoteButtonForeground(active: selected))
                    .frame(minWidth: isRegular ? 76 : 68, minHeight: isRegular ? 44 : 44)
                    .padding(.horizontal, isRegular ? 4 : 3)
                    .background(remoteButtonFill(active: selected))
                    .overlay(
                        RoundedRectangle(cornerRadius: isRegular ? 8 : 7)
                            .stroke(remoteButtonStroke(active: selected), lineWidth: 1)
                    )
                    .cornerRadius(isRegular ? 8 : 7)
                }
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: isRegular ? 10 : 8)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(isRegular ? 10 : 8)
    }

    private func remoteButtonFill(active: Bool = false, highlighted: Bool = false, enabled: Bool = true) -> Color {
        guard enabled else { return Color.black.opacity(0.42) }
        if highlighted { return Color.yellow.opacity(0.92) }
        if active { return Color.blue.opacity(0.94) }
        return Color.black.opacity(0.74)
    }

    private func remoteButtonStroke(active: Bool = false, highlighted: Bool = false, enabled: Bool = true) -> Color {
        guard enabled else { return Color.white.opacity(0.12) }
        if highlighted { return Color.yellow.opacity(0.85) }
        if active { return Color.cyan.opacity(0.80) }
        return Color.white.opacity(0.28)
    }

    private func remoteButtonForeground(active: Bool = false, highlighted: Bool = false, enabled: Bool = true) -> Color {
        guard enabled else { return Color.white.opacity(0.42) }
        return highlighted ? .black : .white
    }

    private func topButton(_ icon: String, highlight: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: isRegular ? 15 : 12, weight: .semibold))
                .foregroundColor(remoteButtonForeground(highlighted: highlight))
                .frame(width: isRegular ? 40 : 32, height: isRegular ? 34 : 28)
                .background(remoteButtonFill(highlighted: highlight))
                .overlay(
                    Capsule().stroke(remoteButtonStroke(highlighted: highlight), lineWidth: 1)
                )
                .cornerRadius(isRegular ? 17 : 14)
                .shadow(color: .black.opacity(0.42), radius: 5, x: 0, y: 2)
        }
    }

    // MARK: - Screen switcher

    private var sortedMonitors: [MonitorInfo] {
        appState.monitors.sorted { $0.id < $1.id }
    }

    private func stepMonitor(by delta: Int) {
        let mons = sortedMonitors
        guard !mons.isEmpty else { return }
        let currentPos = mons.firstIndex { $0.id == appState.activeMonitorIndex } ?? 0
        let nextPos = (currentPos + delta + mons.count) % mons.count
        let target = mons[nextPos].id
        guard target != appState.activeMonitorIndex else { return }
        appState.selectMonitor(target)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func screenChip(_ monitor: MonitorInfo) -> some View {
        let selected = appState.activeMonitorIndex == monitor.id
        let position = (sortedMonitors.firstIndex { $0.id == monitor.id } ?? monitor.id) + 1
        return Button {
            appState.selectMonitor(monitor.id)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: isRegular ? 5 : 4) {
                Image(systemName: "display")
                    .font(.system(size: isRegular ? 12 : 10, weight: .semibold))
                Text("Screen \(position)")
                    .font(.system(size: isRegular ? 13 : 11, weight: .semibold))
                    .fixedSize()
            }
            .foregroundColor(remoteButtonForeground(active: selected))
            .padding(.horizontal, isRegular ? 12 : 9)
            .frame(height: isRegular ? 34 : 30)
            .background(remoteButtonFill(active: selected))
            .overlay(Capsule().stroke(remoteButtonStroke(active: selected), lineWidth: 1))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.42), radius: 5, x: 0, y: 2)
        }
    }

    private func screenStepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: isRegular ? 14 : 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: isRegular ? 34 : 30, height: isRegular ? 34 : 30)
                .background(Color.black.opacity(0.55))
                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                .clipShape(Circle())
        }
    }

    private func iconButton(_ icon: String, highlight: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: { if enabled { action() } }) {
            Image(systemName: icon)
                .font(.system(size: isRegular ? 17 : 13, weight: .semibold))
                .foregroundColor(remoteButtonForeground(highlighted: highlight, enabled: enabled))
                .frame(width: isRegular ? 46 : 44, height: 44)
                .background(remoteButtonFill(highlighted: highlight, enabled: enabled))
                .overlay(
                    RoundedRectangle(cornerRadius: isRegular ? 10 : 8)
                        .stroke(remoteButtonStroke(highlighted: highlight, enabled: enabled), lineWidth: 1)
                )
                .cornerRadius(isRegular ? 10 : 8)
                .shadow(color: .black.opacity(0.42), radius: 5, x: 0, y: 2)
        }
        .disabled(!enabled)
    }

    private func labelButton(_ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: { if enabled { action() } }) {
            Text(label)
                .font(.system(size: isRegular ? 16 : 12, weight: .semibold))
                .foregroundColor(remoteButtonForeground(enabled: enabled))
                .frame(minWidth: isRegular ? 48 : 44, minHeight: 44)
                .padding(.horizontal, 2)
                .background(remoteButtonFill(enabled: enabled))
                .overlay(
                    RoundedRectangle(cornerRadius: isRegular ? 10 : 8)
                        .stroke(remoteButtonStroke(enabled: enabled), lineWidth: 1)
                )
                .cornerRadius(isRegular ? 10 : 8)
                .shadow(color: .black.opacity(0.42), radius: 5, x: 0, y: 2)
        }
        .disabled(!enabled)
    }

    private func modifierKey(_ symbol: String, mod: String, enabled: Bool = true) -> some View {
        let active = activeModifiers.contains(mod)
        return Button { toggleModifier(mod) } label: {
            Text(symbol)
                .font(.system(size: isRegular ? 20 : 15, weight: .semibold))
                .foregroundColor(remoteButtonForeground(active: active, enabled: enabled))
                .frame(width: isRegular ? 48 : 44, height: 44)
                .background(remoteButtonFill(active: active, enabled: enabled))
                .overlay(
                    RoundedRectangle(cornerRadius: isRegular ? 10 : 8)
                        .stroke(remoteButtonStroke(active: active, enabled: enabled), lineWidth: 1)
                )
                .cornerRadius(isRegular ? 10 : 8)
                .shadow(color: .black.opacity(0.42), radius: 5, x: 0, y: 2)
        }
        .disabled(!enabled)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.28))
            .frame(width: 1, height: isRegular ? 30 : 22)
            .padding(.horizontal, isRegular ? 4 : 2)
    }

    private var waitingForFrameOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text("Connecting...")
                .font(.headline)
                .foregroundColor(.white)
            Text("Waiting for the Mac screen.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
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
        .background(Color.black.opacity(0.74))
        .overlay(
            Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.42), radius: 5, x: 0, y: 2)
    }
}
