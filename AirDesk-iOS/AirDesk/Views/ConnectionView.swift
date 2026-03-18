import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var manualIP = ""
    @State private var manualPort = "7890"
    @FocusState private var ipFieldFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: isRegular ? 36 : 28) {
                        // Hero
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
                                        HostRow(host: host, isRegular: isRegular) {
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
                                        .disableAutocorrection(true)
                                        .focused($ipFieldFocused)
                                }
                                .padding(isRegular ? 16 : 12)

                                Divider().padding(.leading)

                                HStack {
                                    Text("Port")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    TextField("7890", text: $manualPort)
                                        .multilineTextAlignment(.trailing)
                                        .keyboardType(.numberPad)
                                }
                                .padding(isRegular ? 16 : 12)
                            }
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(12)

                            Button(action: connectManually) {
                                Text("Connect")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(isRegular ? 16 : 12)
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
                    .frame(maxWidth: isRegular ? 560 : .infinity)
                    .frame(maxWidth: .infinity) // center the constrained content
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
    var isRegular: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: isRegular ? 18 : 14) {
                Image(systemName: "desktopcomputer")
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
        }
    }
}
