import SwiftUI

/// Shown when there are no chat messages yet. Greets the user by name + orb.
struct EmptyHomeView: View {
    let userName: String

    private var greeting: String {
        let name = userName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            return L("home_greeting_anon")
        }
        return String(format: L("home_greeting_named"), name)
    }

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Spacer()
            OrbView()
            Text(greeting)
                .font(.system(size: 17))
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
                .padding(.horizontal, DS.Space.xl)
            Spacer()
        }
    }
}

#Preview {
    EmptyHomeView(userName: "Jane")
}
