import PressayAccount
import SwiftUI

/// The sentence for a failure code. Everything unknown reads the same, without inventing a cause.
enum AccountMessages {
    static func message(for failure: CloudFailure) -> LocalizedStringKey {
        #if PRESSAY_SYNC
        if let message = syncMessages[failure.code] { return message }
        #endif
        return messages[failure.code] ?? "account.error.generic"
    }

    private static var messages: [String: LocalizedStringKey] {
        [
            "cloud_network_unavailable": "account.error.network",
            "cloud_unavailable": "account.error.network",
            "device_limit_reached": "account.deviceLimit.body",
            "device_revoked": "account.deviceRevoked.body",
            "device_not_active": "account.deviceRevoked.body",
            "account_not_active": "account.error.accountInactive",
            "account_not_found": "account.error.accountInactive",
            "cloud_session_expired": "account.sessionExpired",
            "cloud_auth_denied": "account.error.signIn",
            "cloud_auth_state_mismatch": "account.error.signIn",
            "cloud_auth_callback_invalid": "account.error.signIn",
            "cloud_keychain_unavailable": "account.error.keychain",
            "cloud_not_connected": "pro.signInFirst",
            "app_store_sandbox_not_allowed": "pro.error.sandbox",
            "app_store_purchase_already_linked": "pro.error.otherAccount",
            "apple_customer_conflict": "pro.error.otherAppleAccount",
            "storekit_unverified": "pro.error.unverified",
            "storekit_purchase_failed": "pro.error.purchase",
        ]
    }
}

extension View {
    /// Shows `AccountModel.failure`, whichever screen raised it.
    func accountFailureAlert(_ account: AccountModel) -> some View {
        modifier(AccountFailureAlert(account: account))
    }
}

private struct AccountFailureAlert: ViewModifier {
    @Bindable var account: AccountModel

    func body(content: Content) -> some View {
        content.alert(
            "account.error.title",
            isPresented: Binding(get: { account.failure != nil }, set: { if !$0 { account.failure = nil } })
        ) {
            Button("common.ok") { account.failure = nil }
        } message: {
            if let failure = account.failure {
                Text(AccountMessages.message(for: failure))
            }
        }
    }
}
