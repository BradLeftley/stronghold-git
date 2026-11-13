import StrongholdCore
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text("Stronghold")
                .font(.largeTitle.weight(.semibold))
            Text("A native Git client for macOS.")
                .foregroundStyle(.secondary)

            OpenRepositoryButton()
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)

            gitStatus
                .font(.callout)
                .padding(.top, 4)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("welcome")
    }

    @ViewBuilder private var gitStatus: some View {
        switch model.gitState {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready(let version):
            Label("Using Git \(version.description)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("gitVersion")
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .accessibilityIdentifier("gitUnavailable")
        }
    }
}
