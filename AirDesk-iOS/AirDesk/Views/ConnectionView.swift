import SwiftUI
import UIKit

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
    @State private var issueReportStatus: String?
    @State private var isShowingQRCodeScanner = false
    @State private var macDownloadLinkStatus: String?
    @State private var pairingCodePrompt = ""
    @FocusState private var focusedField: FocusField?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL

    private let macCompanionURL = URL(string: "https://hellox.ca/products/airdesk/")!
    private var isRegular: Bool { sizeClass == .regular }
    private var isConnectButtonDisabled: Bool {
        switch draft.mode {
        case .remoteAccess:
            if !appState.canStartRemoteAccessNow() {
                return false
            }
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
        case .remoteAccess:
            return appState.canStartRemoteAccessNow() ? "Connect with Mac Link" : "Unlock Remote Access"
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

                if shouldShowMacCompanionSetupHint {
                    macCompanionSetupHint
                }

                if draft.mode == .remoteAccess {
                    remoteAccessNotice
                    remoteAccessPlanSummary
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

    private var shouldShowMacCompanionSetupHint: Bool {
        (draft.mode == .airDesk || draft.mode == .remoteAccess) && !appState.hasCompletedMacCompanionSetup
    }

    private var macCompanionSetupHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "desktopcomputer.and.arrow.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Need the Mac app?")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("Only for first-time setup.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                Button("Get") {
                    openURL(macCompanionURL)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)

                Menu {
                    Button {
                        openURL(macCompanionURL)
                    } label: {
                        Label("Open Download Page", systemImage: "safari")
                    }

                    ShareLink(item: macCompanionURL) {
                        Label("Share Link to Mac", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        copyMacCompanionLink()
                    } label: {
                        Label("Copy Link", systemImage: "doc.on.doc")
                    }

                    Button {
                        appState.dismissMacCompanionSetupHint()
                        macDownloadLinkStatus = nil
                    } label: {
                        Label("Hide This Hint", systemImage: "eye.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.blue)
                        .frame(width: 36, height: 36)
                }
            }

            if let macDownloadLinkStatus {
                Text(macDownloadLinkStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.top, 2)
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
            Text("Remote can be slower than local Wi-Fi. Scan once, then reconnect from Saved Macs.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remoteAccessPlanSummary: some View {
        let summary = appState.remoteAccessUsageSummary()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: summary.canStart ? "checkmark.seal.fill" : "lock.fill")
                .foregroundColor(summary.canStart ? .green : .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(summary.plan.title): \(summary.plan.includedRemoteHoursText)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                Text("Used this month: \(summary.usedText). Remaining: \(summary.remainingText).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Button(summary.canStart ? "Plans" : "Unlock") {
                appState.presentRemoteAccessPlans(reason: summary.plan.allowsRemoteAccess ? .monthlyLimitReached : .subscriptionRequired)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(isRegular ? 14 : 12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
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
                HStack(spacing: 10) {
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
                savedRemoteConnectionsSection
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
        let canStartRemoteAccess = appState.canStartRemoteAccessNow()
        return Button(action: {
            if canStartRemoteAccess {
                isShowingQRCodeScanner = true
            } else {
                appState.presentRemoteAccessPlans()
            }
        }) {
            Label(canStartRemoteAccess ? "Scan Mac QR Code" : "Unlock Remote Access", systemImage: canStartRemoteAccess ? "qrcode.viewfinder" : "lock.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(isRegular ? 16 : 12)
                .background(Color.blue.opacity(0.12))
                .foregroundColor(.blue)
                .cornerRadius(12)
        }
    }

    private var savedRemoteConnectionsSection: some View {
        SavedRemoteConnectionsSection(
            store: appState.remoteConnectionStore,
            isRegular: isRegular,
            canStartRemoteAccess: appState.canStartRemoteAccessNow(),
            connect: connectToSavedRemoteConnection
        )
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = appState.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Button {
                        reportIssue(error)
                    } label: {
                        Label("Report Issue", systemImage: "paperplane")
                    }
                    .font(.caption.weight(.semibold))

                    if let issueReportStatus {
                        Text(issueReportStatus)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
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
        if draft.mode == .remoteAccess, !appState.canStartRemoteAccessNow() {
            appState.presentRemoteAccessPlans()
            return
        }
        submitConnection {
            draft.manualRequest()
        }
    }

    private func connectToSavedRemoteConnection(_ connection: SavedRemoteConnection) {
        if !appState.canStartRemoteAccessNow() {
            appState.presentRemoteAccessPlans()
            return
        }
        draft.setMode(.remoteAccess)
        draft.remoteAccessURL = connection.urlString
        draft.pairingCode = connection.pairingCode ?? ""
        submitConnection {
            draft.manualRequest()
        }
    }

    private func exportDiagnostics() {
        diagnosticsExport = DiagnosticsExport(url: AirDeskDiagnostics.shared.exportFile())
    }

    private func copyMacCompanionLink() {
        UIPasteboard.general.string = macCompanionURL.absoluteString
        macDownloadLinkStatus = "Link copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if macDownloadLinkStatus == "Link copied" {
                macDownloadLinkStatus = nil
            }
        }
    }

    private func reportIssue(_ error: String) {
        issueReportStatus = "Sending..."
        AirDeskDiagnostics.shared.record("Issue report requested from connection error")
        AirDeskDiagnostics.shared.uploadIssueReport(
            action: "connection_error",
            reason: "user_report",
            errorMessage: error,
            context: issueReportContext()
        ) { result in
            switch result {
            case .success(let reportID):
                issueReportStatus = "Sent \(reportID.prefix(8))"
            case .failure:
                issueReportStatus = "Could not send"
            }
        }
    }

    private func issueReportContext() -> [String: Any] {
        let remoteURL = draft.normalizedRemoteAccessURL
        let manualHost = draft.manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        var context: [String: Any] = [
            "selectedMode": draft.mode.rawValue,
            "connectionState": String(describing: appState.connectionState),
            "discoveredHostsCount": appState.discoveredHosts.count,
            "savedRemoteConnectionsCount": appState.remoteConnectionStore.connections.count,
            "hasPairingCode": !draft.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "hasVNCUsername": !draft.vncUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "hasVNCPassword": !draft.vncPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ]

        if !manualHost.isEmpty {
            context["manualHost"] = manualHost
            context["manualPort"] = draft.resolvedPort ?? draft.mode.defaultPort
        }

        if let remoteURL {
            context["remoteAccessScheme"] = remoteURL.scheme ?? ""
            context["remoteAccessHost"] = remoteURL.host ?? ""
            context["remoteAccessPort"] = remoteURL.port ?? (remoteURL.scheme == "ws" ? 80 : 443)
            context["remoteAccessPathPresent"] = !remoteURL.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return context
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

private struct SavedRemoteConnectionsSection: View {
    @ObservedObject var store: SavedRemoteConnectionStore
    let isRegular: Bool
    let canStartRemoteAccess: Bool
    let connect: (SavedRemoteConnection) -> Void
    @State private var renameTarget: SavedRemoteConnection?

    var body: some View {
        if !store.connections.isEmpty {
            content
                .sheet(item: $renameTarget) { connection in
                    RenameRemoteConnectionSheet(
                        connection: connection,
                        store: store,
                        isRegular: isRegular
                    )
                    .presentationDetents([.height(isRegular ? 340 : 300)])
                    .presentationDragIndicator(.visible)
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved Macs", systemImage: "bookmark")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(store.connections.enumerated()), id: \.element.id) { index, connection in
                    SavedRemoteConnectionRow(
                        connection: connection,
                        isRegular: isRegular,
                        primaryActionTitle: canStartRemoteAccess ? "Connect" : "Unlock",
                        connect: { connect(connection) },
                        rename: { renameTarget = connection },
                        copyLink: { copyLink(connection) },
                        remove: { store.remove(connection) }
                    )
                    if index < store.connections.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }

    private func copyLink(_ connection: SavedRemoteConnection) {
        UIPasteboard.general.string = connection.urlString
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

private struct SavedRemoteConnectionRow: View {
    let connection: SavedRemoteConnection
    let isRegular: Bool
    let primaryActionTitle: String
    let connect: () -> Void
    let rename: () -> Void
    let copyLink: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: isRegular ? 14 : 12) {
            Image(systemName: "desktopcomputer")
                .font(isRegular ? .title3 : .body)
                .foregroundColor(.blue)
                .frame(width: isRegular ? 34 : 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.name)
                    .font(isRegular ? .body.weight(.semibold) : .body.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(connection.urlString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("Remote")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 8)

            Button(primaryActionTitle, action: connect)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)

            Menu {
                Button(action: rename) {
                    Label("Rename", systemImage: "pencil")
                }
                Button(action: copyLink) {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                Button(role: .destructive, action: remove) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(isRegular ? 14 : 12)
    }
}

private struct RenameRemoteConnectionSheet: View {
    let connection: SavedRemoteConnection
    @ObservedObject var store: SavedRemoteConnectionStore
    let isRegular: Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var name: String

    init(connection: SavedRemoteConnection, store: SavedRemoteConnectionStore, isRegular: Bool) {
        self.connection = connection
        self.store = store
        self.isRegular = isRegular
        _name = State(initialValue: connection.name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved Mac Name")
                        .font(.subheadline.weight(.semibold))
                    Text("Use a name you recognize, such as Home Mac or Office Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Remote Mac", text: $name)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .font(.body)
                    .padding(isRegular ? 16 : 14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .focused($isNameFocused)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Link")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(connection.urlString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(isRegular ? 24 : 20)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Rename Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.rename(connection, to: trimmedName)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isNameFocused = true
                }
            }
        }
    }
}
