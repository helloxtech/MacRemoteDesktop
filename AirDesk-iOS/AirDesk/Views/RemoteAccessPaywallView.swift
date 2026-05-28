import SwiftUI

struct RemoteAccessPaywallView: View {
    let presentation: RemoteAccessPaywallPresentation
    @ObservedObject var appState: AppState
    @ObservedObject var subscriptionStore: RemoteAccessSubscriptionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    usageSummary
                    planList
                    restoreButton
                    finePrint
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Remote Access Plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await subscriptionStore.loadProducts()
                await subscriptionStore.refreshEntitlements()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect away from local Wi-Fi", systemImage: "globe")
                .font(.title3.weight(.semibold))
            Text(presentation.message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var usageSummary: some View {
        let summary = appState.remoteAccessUsageSummary()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Current plan")
                    .foregroundColor(.secondary)
                Spacer()
                Text(summary.plan.title)
                    .fontWeight(.semibold)
            }
            HStack {
                Text("Used this month")
                    .foregroundColor(.secondary)
                Spacer()
                Text(summary.usedText)
                    .fontWeight(.semibold)
            }
            HStack {
                Text("Remaining")
                    .foregroundColor(.secondary)
                Spacer()
                Text(summary.remainingText)
                    .fontWeight(.semibold)
            }
        }
        .font(.subheadline)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var planList: some View {
        VStack(spacing: 10) {
            ForEach(RemoteAccessPlan.allCases) { plan in
                planRow(plan)
            }
        }
    }

    private func planRow(_ plan: RemoteAccessPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.title)
                        .font(.headline)
                    Text(plan.includedRemoteHoursText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(subscriptionStore.displayPrice(for: plan))
                    .font(.subheadline.weight(.semibold))
            }

            if plan == .free {
                Text("Local Wi-Fi and VNC connections remain available without a subscription.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if subscriptionStore.activePlan == plan {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.green)
            } else {
                Button(action: { purchase(plan) }) {
                    Text("Choose \(plan.title)")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(subscriptionStore.isLoading)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var restoreButton: some View {
        Button(action: restorePurchases) {
            Text("Restore Purchases")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.12))
                .foregroundColor(.blue)
                .cornerRadius(10)
        }
    }

    private var finePrint: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = subscriptionStore.message {
                Text(message)
                    .foregroundColor(.orange)
            }
            Text("Remote Access time is counted only while a remote session is connected on this device. Local network connections are unlimited.")
            Text("Subscriptions renew monthly through Apple and can be managed in App Store settings.")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func purchase(_ plan: RemoteAccessPlan) {
        Task {
            await subscriptionStore.purchase(plan)
            if appState.remoteAccessUsageSummary().canStart {
                dismiss()
            }
        }
    }

    private func restorePurchases() {
        Task {
            await subscriptionStore.restorePurchases()
            if appState.remoteAccessUsageSummary().canStart {
                dismiss()
            }
        }
    }
}
