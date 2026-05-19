import SwiftUI
import SwiftData

// MARK: — Shared chat building blocks
//
// `ChatRootView` itself was removed during the Figma redesign — the home screen
// is now `HomeView`. This file keeps the small, reusable pieces that the new
// home consumes: message bubbles, typing indicator, day divider, and the
// currency picker sheet used from the home header.

// MARK: — Date divider (uses Formatters for locale-aware output)
struct DateDividerView: View {
    let date: Date
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Text(Formatters.dayDivider(date))
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground).opacity(0.8))
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .id(localization.current)
    }
}

// MARK: — Message bubble
struct MessageBubbleView: View {
    let message: ChatMessage
    var store: AppStore? = nil
    var isUser: Bool { message.role == .user }
    private var avatar: UIImage? { store?.userAvatar }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 50) }
            if !isUser {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 28, height: 28)
                    .overlay(
                        Image("SplashLogo")
                            .resizable().scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                    )
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 4) {
                    if let imgData = message.imageData, let uiImg = UIImage(data: imgData) {
                        Image(uiImage: uiImg)
                            .resizable().scaledToFill()
                            .frame(maxWidth: 200, maxHeight: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    // User content as plain text; assistant content as LocalizedStringKey so
                    // `**bold**` markdown still renders for our reply templates.
                    if isUser {
                        Text(message.content).font(.system(size: 15))
                    } else {
                        Text(LocalizedStringKey(message.content)).font(.system(size: 15))
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(isUser ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundColor(isUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if isUser {
                if let img = avatar {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                } else {
                    Circle().fill(Color(.tertiarySystemFill)).frame(width: 28, height: 28)
                        .overlay(Image(systemName: "person.fill").font(.system(size: 12)).foregroundColor(.secondary))
                }
            }
        }
    }
}

// MARK: — Typing indicator
struct TypingIndicatorView: View {
    @State private var animated = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 28, height: 28)
                .overlay(
                    Image("SplashLogo")
                        .resizable().scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                )
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        .offset(y: animated ? -4 : 0)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: animated)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 50)
        }
        .onAppear { animated = true }
    }
}

// MARK: — Currency picker (sheet)
struct CurrencyPickerSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            List {
                ForEach(CurrencyService.supported, id: \.code) { item in
                    Button {
                        store.displayCurrency = item.code
                        store.saveSettings(displayCurrency: item.code)
                        dismiss()
                    } label: {
                        HStack {
                            Text(item.flag).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.code).font(.system(size: 15, weight: .medium))
                                Text(item.name).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if store.displayCurrency == item.code {
                                Image(systemName: "checkmark").foregroundColor(Color.accentColor).fontWeight(.semibold)
                            }
                        }.foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle(L("currency"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("close")) { dismiss() } } }
        }
    }
}
