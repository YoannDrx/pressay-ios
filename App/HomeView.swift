import SwiftUI

/// First screen. Onboarding and the dictation home replace it in lots I2 and I4.
struct HomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("home.title")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("home.tagline")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text("home.comingSoon")
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: .rect(cornerRadius: 16))
            Spacer()
            Text(versionLabel)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return String(format: String(localized: "home.version"), version, build)
    }
}

#Preview {
    HomeView()
}
