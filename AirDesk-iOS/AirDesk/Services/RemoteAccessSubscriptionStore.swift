import Foundation
import StoreKit

@MainActor
final class RemoteAccessSubscriptionStore: ObservableObject {
    @Published private(set) var products: [RemoteAccessPlan: Product] = [:]
    @Published private(set) var activePlan: RemoteAccessPlan = .free
    @Published private(set) var isLoading = false
    @Published var message: String?

    private var updatesTask: Task<Void, Never>?

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self.refreshEntitlements()
            }
        }

        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let productIDs = RemoteAccessPlan.allCases.compactMap(\.productID)
            let fetchedProducts = try await Product.products(for: productIDs)
            products = Dictionary(uniqueKeysWithValues: fetchedProducts.compactMap { product in
                guard let plan = RemoteAccessPlan(planProductID: product.id) else { return nil }
                return (plan, product)
            })
            message = nil
        } catch {
            message = "Plans could not load. Check your connection and try again."
        }
    }

    func purchase(_ plan: RemoteAccessPlan) async {
        guard let product = products[plan] else {
            message = "This plan is not available yet. Please try again later."
            await loadProducts()
            return
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verified(verification)
                await transaction.finish()
                await refreshEntitlements()
                message = nil
            case .pending:
                message = "Purchase is pending approval."
            case .userCancelled:
                break
            @unknown default:
                message = "Purchase could not be completed."
            }
        } catch {
            message = "Purchase could not be completed. Please try again."
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = activePlan.allowsRemoteAccess ? nil : "No active Remote Access subscription was found."
        } catch {
            message = "Purchases could not be restored. Please try again."
        }
    }

    func displayPrice(for plan: RemoteAccessPlan) -> String {
        guard plan != .free else { return plan.fallbackPriceText }
        guard let product = products[plan] else { return plan.fallbackPriceText }
        return "\(product.displayPrice)/month"
    }

    func refreshEntitlements() async {
        var bestPlan = RemoteAccessPlan.free

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  let plan = RemoteAccessPlan(planProductID: transaction.productID),
                  plan.monthlyRemoteAccessLimitSeconds > bestPlan.monthlyRemoteAccessLimitSeconds else {
                continue
            }
            bestPlan = plan
        }

        activePlan = bestPlan
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe): return safe
        case .unverified:
            throw StoreError.failedVerification
        }
    }

    private enum StoreError: Error {
        case failedVerification
    }
}

extension RemoteAccessPlan {
    init?(planProductID: String) {
        guard let plan = Self.allCases.first(where: { $0.productID == planProductID }) else {
            return nil
        }
        self = plan
    }
}
