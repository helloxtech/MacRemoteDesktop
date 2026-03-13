import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var manualIP = ""
    @State private var manualPort = "7890"
    @FocusState private var ipFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        // Hero
                        VStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 56, weight: .thin))
                                .foregroundStyle(
                                    LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                            Text("AirDesk")
                                .font(.largeTitle.bold())
                            Text("Remote Desktop for Mac")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 32)

                        // Discovered Macs
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
                            }
                            .padding(.horizontal, 4)

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
                                        HostRow(host: host) {
                                            appState.connect(to: host)
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

                        // Manual Connection
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Manual Connection", systemImage: "network")
                                .font(.headline)
                                .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                HStack {
                                    Text("IP Address")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    TextField("e.g. 192.168.1.10", text: $manualIP)
                                        .multilineTextAlignment(.trailing)
                                        .keyboardType(.numbersAndPunctuation)
                                        .autocorrectionDisabled()
                                        .focused($ipFieldFocused)
                                }
                                .padding()

                                Divider().padding(.leading)

                                HStack {
                                    Text("Port")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    TextField("7890", text: $manualPort)
                                        .multilineTextAlignment(.trailing)
                                        .keyboardType(.numberPad)
                                }
                                .padding()
                            }
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(12)

                            Button(action: connectManually) {
                                Text("Connect")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(manualIP.isEmpty ? Color.gray : Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                            .disabled(manualIP.isEmpty)
                        }
                        .padding(.horizontal)

                        // Error message
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

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
    }

    private func connectManually() {
        ipFieldFocused = false
        guard !manualIP.isEmpty, let port = Int(manualPort) else { return }
        let host = DiscoveredHost(name: manualIP, host: manualIP, port: port)
        appState.connect(to: host)
    }
}

struct HostRow: View {
    let host: DiscoveredHost
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.body.weight(.medium))
                        .foregroundColor(.primary)
                    Text(host.host)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.tertiaryLabel)
            }
            .padding()
        }
    }
}
