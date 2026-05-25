import SwiftUI
import UIKit
import RoyalVNCKit

struct VNCRemoteDesktopView: View {
    @EnvironmentObject var appState: AppState
    @State private var keyboardVisible = false
    @State private var keyboardInset: CGFloat = 0
    @State private var toolbarVisible = true
    @State private var activeModifiers: Set<String> = []
    @State private var controlMode: RemoteControlMode = .touch
    @State private var diagnosticsExport: VNCDiagnosticsExport?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isRegular: Bool { sizeClass == .regular }
    private var selectedDisplay: VNCDisplayInfo? {
        if let activeID = appState.activeVNCDisplayID,
           let display = appState.vncDisplays.first(where: { $0.id == activeID }) {
            return display
        }
        return appState.vncDisplays.first
    }
    private var inputReady: Bool {
        appState.vncSessionController != nil && appState.vncFramebufferSize != .zero
    }
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

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.black

                VNCMonitorView(
                    remoteImage: nil,
                    remoteSize: appState.vncFramebufferImageSize == .zero ? appState.vncFramebufferSize : appState.vncFramebufferImageSize,
                    desktopSize: appState.vncFramebufferSize,
                    renderRevision: appState.vncFrameRevision,
                    selectedDisplay: selectedDisplay,
                    imageCoversSelectedDisplay: appState.vncFramebufferImageCoversSelectedDisplay,
                    controlMode: controlMode,
                    inputEnabled: inputReady,
                    session: appState.vncSessionController
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                if !appState.vncHasFramebuffer {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Waiting for VNC desktop…")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
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
                VNCKeyboardInputView(
                    isActive: $keyboardVisible,
                    activeModifiers: $activeModifiers,
                    session: appState.vncSessionController,
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
        HStack(spacing: isRegular ? 10 : 6) {
            topButton("xmark", action: closeRemote)

            if appState.vncDisplays.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: isRegular ? 8 : 5) {
                        ForEach(appState.vncDisplays) { display in
                            topDisplayButton(display)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: ConnectionMode.vnc.iconName)
                        .font(.system(size: isRegular ? 12 : 10, weight: .semibold))
                    Text(appState.selectedHost?.name ?? "VNC")
                        .font(.system(size: isRegular ? 13 : 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, isRegular ? 12 : 10)
                .frame(height: isRegular ? 34 : 28)
                .background(Color.white.opacity(0.10))
                .cornerRadius(isRegular ? 17 : 14)
            }

            Spacer(minLength: 0)

            topButton(toolbarVisible ? "chevron.down" : "ellipsis", action: toggleToolbar)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, isRegular ? 8 : 6)
        .padding(.bottom, isRegular ? 4 : 2)
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
                iconButton("plus.magnifyingglass") { appState.activeVNCMonitorVC?.toggleZoom() }

                separator

                iconButton("arrow.left", enabled: inputReady) { sendKey(.leftArrow) }
                iconButton("arrow.down", enabled: inputReady) { sendKey(.downArrow) }
                iconButton("arrow.up", enabled: inputReady) { sendKey(.upArrow) }
                iconButton("arrow.right", enabled: inputReady) { sendKey(.rightArrow) }

                separator

                labelButton("↵", enabled: inputReady) { sendKey(.return) }
                labelButton("Esc", enabled: inputReady) { sendKey(.escape) }
                labelButton("Tab", enabled: inputReady) { sendKey(.tab) }

                separator

                modifierKey("⌘", mod: "cmd", enabled: inputReady)
                modifierKey("⌃", mod: "ctrl", enabled: inputReady)
                modifierKey("⌥", mod: "opt", enabled: inputReady)
                modifierKey("⇧", mod: "shift", enabled: inputReady)

                separator

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

    private func toggleToolbar() {
        withAnimation(.easeInOut(duration: 0.2)) { toolbarVisible.toggle() }
    }

    private func closeRemote() {
        keyboardVisible = false
        toolbarVisible = true
        activeModifiers.removeAll()
        appState.disconnect()
    }

    private func sendKey(_ key: VNCKeyCode) {
        guard inputReady else { return }
        appState.vncSessionController?.sendKeyPress(key, modifiers: activeModifierKeyCodes())
        activeModifiers.removeAll()
    }

    private func activeModifierKeyCodes() -> [VNCKeyCode] {
        var keys: [VNCKeyCode] = []
        if activeModifiers.contains("cmd") { keys.append(.command) }
        if activeModifiers.contains("ctrl") { keys.append(.control) }
        if activeModifiers.contains("opt") { keys.append(.option) }
        if activeModifiers.contains("shift") { keys.append(.shift) }
        return keys
    }

    private func toggleModifier(_ mod: String) {
        guard inputReady else { return }
        if activeModifiers.contains(mod) {
            activeModifiers.remove(mod)
        } else {
            activeModifiers.insert(mod)
        }
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

    private func topDisplayButton(_ display: VNCDisplayInfo) -> some View {
        let isSelected = appState.activeVNCDisplayID == display.id || (appState.activeVNCDisplayID == nil && appState.vncDisplays.first?.id == display.id)
        return Button {
            appState.selectVNCDisplay(display.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: isRegular ? 12 : 10, weight: .semibold))
                Text(display.title)
                    .font(.system(size: isRegular ? 12 : 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? .black : .white)
            .padding(.horizontal, isRegular ? 12 : 10)
            .frame(height: isRegular ? 34 : 28)
            .background(isSelected ? Color.white : Color.white.opacity(0.10))
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

    private func exportDiagnostics() {
        diagnosticsExport = VNCDiagnosticsExport(url: AirDeskDiagnostics.shared.exportFile())
    }
}

private struct VNCDiagnosticsExport: Identifiable {
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
