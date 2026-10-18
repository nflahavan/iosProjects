import SwiftUI

/// The placeholder screen, until the real app replaces it.
///
/// Shows the version and build so a TestFlight install can be told apart from
/// the one before it at a glance.
struct HelloView: View {
    private var build: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(number))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Hello, Risu")
                .font(.largeTitle.weight(.bold))
            Text(build)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    HelloView()
}
