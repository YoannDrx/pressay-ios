import Foundation

/// The Pro subscriptions, shared with the Mac App Store app by the universal purchase. The prices
/// are never written anywhere in this repository: the interface shows StoreKit's.
public enum ProductCatalog {
    public static let monthly = "app.pressay.desktop.mas.pro.monthly"
    public static let annual = "app.pressay.desktop.mas.pro.annual"
    public static let all = [annual, monthly]

    public static func isKnown(_ productID: String) -> Bool {
        all.contains(productID)
    }
}

/// What to do with a verified StoreKit transaction once the cloud answered: the rule behind
/// "finish only what the server has recorded".
public enum TransactionDecision: Equatable, Sendable {
    /// The cloud recorded it: `finish()` it.
    case finish
    /// The user must confirm that this purchase belongs to this account, then deliver again.
    case askToLink
    /// Stays unfinished: StoreKit redelivers it and the next launch retries.
    case retryLater
    /// Retrying cannot help: a Sandbox purchase on an account not allowed to use it, or a purchase
    /// owned by another account. Shown, and left unfinished.
    case rejected(String)

    public static func after(_ failure: CloudFailure?) -> TransactionDecision {
        guard let failure else { return .finish }
        switch failure.code {
        case "app_store_account_mismatch", "app_store_account_token_missing":
            return .askToLink
        case "app_store_sandbox_not_allowed", "app_store_purchase_already_linked", "apple_customer_conflict", "unknown_app_store_product":
            return .rejected(failure.code)
        default:
            return .retryLater
        }
    }
}
