import SwiftUI

struct ConnectionView: View {
    private enum FocusField: Hashable {
        case ipAddress
        case port
        case remoteAccessURL
        case pairingCode
        case vncUsername
        case vncPassword
    }

    @EnvironmentObject var appState: AppState
    @ObservedObject var draft: ConnectionDraft
    @State private var diagnosticsExport: DiagnosticsExport?
    @State private var isShowingQRCodeScanner = false
    @State private var pairingCodePrompt = ""
    @FocusState private var focusedField: FocusField?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isRegular: Bool { sizeClass == .regular }
    private var isConnectButtonDisabled: Bool {
        switch draft.mode {
        case .remoteAccess:
            return draft.remoteAccessURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .vnc:
            return draft.manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draft.vncPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .airDesk:
            return draft.manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var manualSectionTitle: String {
        switch draft.mode {
        case .airDesk: return "Local Connection"
        case .remoteAccess: return "Remote Access"
        case .vnc: return "Manual Connection"
        }
    }

    private var connectButtonTitle: String {
        switch draft.mode {
        case .airDesk: return "Connect Locally"
        case .remoteAccess: return "Connect to My Mac"
        case .vnc: return "Connect with VNC"
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: isRegular ? 36 : 28) {
                        hero
                        connectionModeCard
                        if draft.mode != .remoteAccess {
                            nearbyHostsSection
                        }
                        manualConnectionSection
                        errorSection
                        Spacer(minLength: 40)
                    }
                    .frame(maxWidth: isRegular ? 560 : .infinity)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .sheet(item: $diagnosticsExport) { export in
                DiagnosticsShareSheet(url: export.url)
            }
            .sheet(isPresented: $isShowingQRCodeScanner) {
                QRCodeScannerSheet(onCode: handleScannedCode)
            }
            .sheet(
                item: Binding(
                    get: { appState.pairingChallenge },
                    set: { appState.pairingChallenge = $0 }
                )
            ) { challenge in
                PairingCodeSheet(
                    challenge: challenge,
                    pairingCode: $pairingCodePrompt,
                    isRegular: isRegular,
                    submit: submitPairingCode,
                    cancel: {
                        pairingCodePrompt = ""
                        appState.cancelPairingChallenge()
                    }
                )
                .presentationDetents([.height(isRegular ? 360 : 320)])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: appState.pairingChallenge?.id) { challengeID in
                if challengeID != nil {
                    pairingCodePrompt = ""
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: isRegular ? 12 : 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: isRegular ? 80 : 56, weight: .thin))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("AirDesk")
                .font(isRegular ? .system(size: 44, weight: .bold) : .largeTitle.bold())
            Text("Remote Desktop for Mac")
                .font(isRegular ? .body : .subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, isRegular ? 60 : 32)
    }

    private var connectionModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connection Mode", systemImage: draft.mode.iconName)
                .font(.headline)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12) {
                Picker("Connection Mode", selection: Binding(get: { draft.mode }, set: { draft.setMode($0) })) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(draft.mode.helperText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if draft.mode == .remoteAccess {
                    remoteAccessNotice
                }

                if draft.mode == .vnc {
                    vncSetupGuide
                }
            }
            .padding(isRegular ? 16 : 12)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
        .padding(.horizontal)
    }

    private var vncSetupGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Set up your Mac for VNC", systemImage: "list.bullet.rectangle")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 8) {
                VNCSetupStep(number: 1, text: "On the Mac, open System Settings > General > Sharing.")
                VNCSetupStep(number: 2, text: "If Remote Management is on, turn it off, then turn on Screen Sharing.")
                VNCSetupStep(number: 3, text: "Open Screen Sharing options. Allow your Mac user, then set Computer Settings > VNC viewers may control screen with password.")
                VNCSetupStep(number: 4, text: "In AirDesk, use the Mac IP address, port 5900, and that VNC password.")
            }
        }
        .padding(isRegular ? 14 : 12)
        .background(Color.blue.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.18), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private var remoteAccessNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.orange)
            Text("Remote access can be slower than local Wi-Fi. If it stops working, open AirDesk on your Mac and scan the new QR code, or use Local when you are nearby.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nearbyHostsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Nearby Macs", systemImage: "wifi")
                    .font(.headline)
                Spacer()
                Button(action: { appState.startDiscovery() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                Button(action: exportDiagnostics) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 4)

            if draft.mode == .vnc {
                Text("Uses the discovered Mac address with your selected VNC port.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }

            if appState.discoveredHosts.isEmpty {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Scanning local network...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appState.discoveredHosts.enumerated()), id: \.element.id) { index, host in
                        HostRow(host: host, isRegular: isRegular, mode: draft.mode) {
                            connectToNearbyHost(host)
                        }
                        if index < appState.discoveredHosts.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
        }
        .padding(.horizontal)
    }

    private var manualConnectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(manualSectionTitle, systemImage: draft.mode == .remoteAccess ? "globe" : "network")
                .font(.headline)
                .padding(.horizontal, 4)

            if draft.mode == .remoteAccess {
                scanQRCodeButton
            }

            VStack(spacing: 0) {
                if draft.mode == .remoteAccess {
                    HStack {
                        Text("Mac Link")
                            .foregroundColor(.secondary)
                        Spacer()
                        TextField("Scan or paste link", text: $draft.remoteAccessURL)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .focused($focusedField, equals: .remoteAccessURL)
                    }
                    .padding(isRegular ? 16 : 12)

                    Divider().padding(.leading)

                    HStack {
                        Text("Security Code")
                            .foregroundColor(.secondary)
                        Spacer()
                        TextField("Auto-filled by QR", text: $draft.pairingCode)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focusedField, equals: .pairingCode)
                            .onChange(of: draft.pairingCode) { _ in
                                draft.sanitizePairingCode()
                            }
                    }
                    .padding(isRegular ? 16 : 12)
                } else {
                    HStack {
                        Text("IP Address")
                            .foregroundColor(.secondary)
                        Spacer()
                        TextField("e.g. 192.168.1.10", text: $draft.manualIP)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .focused($focusedField, equals: .ipAddress)
                    }
                    .padding(isRegular ? 16 : 12)

                    Divider().padding(.leading)

                    HStack {
                        Text("Port")
                            .foregroundColor(.secondary)
                        Spacer()
                        TextField(String(draft.mode.defaultPort), text: $draft.manualPort)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .port)
                    }
                    .padding(isRegular ? 16 : 12)

                    Divider().padding(.leading)

                    if draft.mode == .airDesk {
                        HStack {
                            Text("Pairing Code")
                                .foregroundColor(.secondary)
                            Spacer()
                            TextField("Required first time", text: $draft.pairingCode)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                .focused($focusedField, equals: .pairingCode)
                                .onChange(of: draft.pairingCode) { _ in
                                    draft.sanitizePairingCode()
                                }
                        }
                        .padding(isRegular ? 16 : 12)
                    } else {
                        HStack {
                            Text("Username")
                                .foregroundColor(.secondary)
                            Spacer()
                            TextField("Leave blank for VNC password", text: $draft.vncUsername)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .focused($focusedField, equals: .vncUsername)
                        }
                        .padding(isRegular ? 16 : 12)

                        Divider().padding(.leading)

                        HStack {
                            Text("Password")
                                .foregroundColor(.secondary)
                            Spacer()
                            SecureField("Required", text: $draft.vncPassword)
                                .multilineTextAlignment(.trailing)
                                .textContentType(.password)
                                .focused($focusedField, equals: .vncPassword)
                        }
                        .padding(isRegular ? 16 : 12)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)

            if draft.mode == .vnc {
                Text("Leave Username empty to use the VNC password from macOS Remote Management.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }

            Button(action: connectManually) {
                Text(connectButtonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(isRegular ? 16 : 12)
                    .background(isConnectButtonDisabled ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(isConnectButtonDisabled)
        }
        .padding(.horizontal)
    }

    private var scanQRCodeButton: some View {
        Button(action: { isShowingQRCodeScanner = true }) {
            Label("Scan QR Code from Mac", systemImage: "qrcode.viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(isRegular ? 16 : 12)
                .background(Color.blue.opacity(0.12))
                .foregroundColor(.blue)
                .cornerRadius(12)
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = appState.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(8)
            .padding(.horizontal)
        }
    }

    private func connectToNearbyHost(_ host: DiscoveredHost) {
        draft.applyDiscoveredHost(host)
        AirDeskDiagnostics.shared.record("Nearby host tapped \(host.name) at \(host.host):\(draft.manualPort)")
        submitConnection {
            draft.manualRequest()
        }
    }

    private func connectManually() {
        submitConnection {
            draft.manualRequest()
        }
    }

    private func exportDiagnostics() {
        diagnosticsExport = DiagnosticsExport(url: AirDeskDiagnostics.shared.exportFile())
    }

    private func handleScannedCode(_ code: String) {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedCode),
              let request = AirDeskConnectLink.request(from: url),
              request.mode == .remoteAccess else {
            appState.errorMessage = "Scan the QR code shown by AirDesk on your Mac."
            return
        }

        draft.setMode(.remoteAccess)
        draft.remoteAccessURL = AirDeskConnectLink.displayRemoteAccessURL(from: url)
            ?? request.remoteWebSocketURL?.absoluteString
            ?? ""
        draft.pairingCode = request.pairingCode ?? ""
        focusedField = nil
        appState.errorMessage = nil
        appState.connect(using: request)
    }

    private func submitPairingCode() {
        let digits = pairingCodePrompt.filter(\.isNumber)
        guard digits.count == 6 else {
            appState.errorMessage = "Enter the six-digit pairing code shown in the AirDesk Mac menu."
            return
        }
        let code = String(digits.prefix(6))
        draft.pairingCode = code
        pairingCodePrompt = ""
        appState.submitPairingCode(code)
    }

    private func submitConnection(_ requestBuilder: @escaping () -> ConnectionRequest?) {
        focusedField = nil
        DispatchQueue.main.async {
            guard validateInputsIfNeeded() else { return }
            guard let request = requestBuilder() else { return }
            if shouldPromptForLocalPairing(request) {
                appState.requestPairingCode(for: request)
                return
            }
            appState.connect(using: request)
        }
    }

    private func shouldPromptForLocalPairing(_ request: ConnectionRequest) -> Bool {
        guard request.mode == .airDesk else { return false }
        guard !AirDeskClientIdentity.hasStoredSecret else { return false }
        let code = request.pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return code.isEmpty
    }

    private func validateInputsIfNeeded() -> Bool {
        if draft.mode == .remoteAccess {
            guard draft.normalizedRemoteAccessURL != nil else {
                appState.errorMessage = "Scan the QR code from your Mac, or paste the setup link shown there."
                return false
            }
            return true
        }

        guard draft.mode == .vnc else { return true }

        let trimmedPassword = draft.vncPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            appState.errorMessage = "Enter the VNC password before connecting."
            return false
        }

        return true
    }
}

private struct DiagnosticsExport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct VNCSetupStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue)
                .clipShape(Circle())

            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PairingCodeSheet: View {
    let challenge: PairingChallenge
    @Binding var pairingCode: String
    let isRegular: Bool
    let submit: () -> Void
    let cancel: () -> Void
    @FocusState private var isPairingCodeFocused: Bool

    private var sanitizedCode: String {
        String(pairingCode.filter(\.isNumber).prefix(6))
    }

    private var canSubmit: Bool {
        sanitizedCode.count == 6
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Pair \(challenge.hostName)", systemImage: "lock.shield")
                        .font(isRegular ? .title3.weight(.semibold) : .headline)
                    Text("Enter the six-digit code shown in the AirDesk menu on your Mac. After this, this iPhone will be trusted for future local connections.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Pairing Code")
                        .foregroundColor(.secondary)
                    Spacer()
                    TextField("123456", text: $pairingCode)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title3.monospacedDigit())
                        .focused($isPairingCodeFocused)
                        .onChange(of: pairingCode) { _ in
                            sanitizePairingCode()
                        }
                        .submitLabel(.go)
                }
                .padding(isRegular ? 16 : 14)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)

                Text(challenge.message)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(isRegular ? 24 : 20)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Pairing Required")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: submit)
                        .disabled(!canSubmit)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isPairingCodeFocused = true
                }
            }
        }
    }

    private func sanitizePairingCode() {
        let sanitized = sanitizedCode
        if pairingCode != sanitized {
            pairingCode = sanitized
        }
    }
}

struct HostRow: View {
    let host: DiscoveredHost
    var isRegular: Bool = false
    var mode: ConnectionMode = .airDesk
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: isRegular ? 18 : 14) {
                Image(systemName: mode == .vnc ? "rectangle.connected.to.line.below" : "desktopcomputer")
                    .font(isRegular ? .title : .title2)
                    .foregroundColor(.blue)
                    .frame(width: isRegular ? 44 : 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(isRegular ? .body.weight(.semibold) : .body.weight(.medium))
                        .foregroundColor(.primary)
                    Text(host.host)
                        .font(isRegular ? .subheadline : .caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
            .padding(isRegular ? 16 : 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
