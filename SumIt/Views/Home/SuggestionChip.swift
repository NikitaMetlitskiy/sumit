import SwiftUI

/// Quick-tap chip that prefills the composer with an example expense.
struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(DS.Color.chip)
                        .overlay(
                            Capsule(style: .continuous).stroke(DS.Color.stroke, lineWidth: 0.5)
                        )
                )
                .dsComposerShadow()
        }
        .buttonStyle(.plain)
    }
}

struct SuggestionChipsBar: View {
    /// Localized suggestions. Caller injects the example list it wants to show.
    let suggestions: [String]
    let onTap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    SuggestionChip(text: s) { onTap(s) }
                }
            }
            .padding(.horizontal, DS.Space.l)
        }
    }

    /// Default examples in the user's current language. Picks 5 from the LocalizationManager.
    static func defaults() -> [String] {
        [
            L("home_chip_coffee"),
            L("home_chip_lunch_combo"),
            L("home_chip_uber"),
            L("home_chip_groceries"),
            L("home_chip_gym")
        ]
    }
}
