import AuthenticationServices
import PressayAccount
import SwiftUI

/// The icon takes the colour of the text, not the accent colour of the form.
private struct SignInLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}

/// Sign in through the Pressay website, in `ASWebAuthenticationSession`. Apple comes first with
/// the same prominence as the others (App Review 4.8) and, like them, needs no entitlement: the
/// web issuer runs every provider, and this bundle shares its App ID with the Mac App Store app.
struct SignInButtons: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.webAuthenticationSession) private var webAuthentication

    var body: some View {
        VStack(spacing: 12) {
            Button {
                signIn(.apple)
            } label: {
                Label("account.signIn.apple", systemImage: "apple.logo")
                    .labelStyle(SignInLabelStyle())
                    .foregroundStyle(Color(.systemBackground))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .accessibilityIdentifier("signInApple")

            Button {
                signIn(.google)
            } label: {
                Label("account.signIn.google", systemImage: "globe")
                    .labelStyle(SignInLabelStyle())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .accessibilityIdentifier("signInGoogle")

            Button("account.signIn.other") { signIn(nil) }
                .buttonStyle(.borderless)
                .font(.footnote)
                .accessibilityIdentifier("signInOther")
        }
        .disabled(account.isWorking)
    }

    private func signIn(_ provider: SignInProvider?) {
        Task {
            await account.signIn(provider: provider) { url in
                try await webAuthentication.authenticate(
                    using: url,
                    callback: .customScheme(CloudConfiguration.callbackScheme),
                    preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
            }
        }
    }
}
