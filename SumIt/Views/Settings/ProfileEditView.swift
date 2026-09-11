import SwiftUI
import SwiftData
import PhotosUI
import AuthenticationServices

struct ProfileEditView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var auth: AuthService = .shared
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var signInError: String? = nil
    @State private var showSignOutConfirm = false
    @StateObject private var signInBuilder = AppleSignInRequestBuilder()

    var body: some View {
        NavigationView {
            Form {
                avatarSection
                Section(L("name")) { TextField(L("your_name"), text: $name) }
                accountSection
            }
            .navigationTitle(L("profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("save")) {
                        store.saveSettings(userName: name.isEmpty ? nil : name, avatar: image)
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear { name = store.userName }
            .onChange(of: item) {
                Task {
                    if let d = try? await item?.loadTransferable(type: Data.self),
                       let img = UIImage(data: d) { image = img }
                }
            }
        }
    }

    @ViewBuilder
    private var avatarSection: some View {
        // Resolve MainActor state once at the View-body level. PhotosPicker's label
        // closure is treated as Sendable under Swift 6 and can't pull from MainActor
        // properties directly, but it can capture this already-resolved UIImage value.
        let displayedImage: UIImage? = image ?? store.userAvatar
        Section(L("profile_photo")) {
            HStack {
                Spacer()
                PhotosPicker(selection: $item, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        Group {
                            if let img = displayedImage {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 88, height: 88).clipShape(Circle())
                            } else if name.isEmpty {
                                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 88, height: 88)
                                    .overlay(Image(systemName: "person.fill").font(.title).foregroundColor(Color.accentColor))
                            } else {
                                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 88, height: 88)
                                    .overlay(Text(String(name.prefix(1)))
                                        .font(.largeTitle.weight(.semibold))
                                        .foregroundColor(Color.accentColor))
                            }
                        }
                        Circle().fill(Color.accentColor).frame(width: 26, height: 26)
                            .overlay(Image(systemName: "camera.fill").font(.system(size: 11)).foregroundColor(.white))
                    }
                }
                Spacer()
            }.listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section(L("account_sync")) {
            if auth.isSignedIn {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.icloud.fill").foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("sync_enabled")).font(.system(size: 14, weight: .medium))
                        if let email = auth.userEmail {
                            Text(email).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Button(role: .destructive) {
                    showSignOutConfirm = true
                } label: {
                    Label(L("sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .confirmationDialog(L("sign_out_wipe_q"), isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                    Button(L("sign_out_keep"), role: .none) {
                        auth.signOut()
                    }
                    Button(L("sign_out_wipe"), role: .destructive) {
                        auth.signOut { store.wipeLocalUserData() }
                    }
                    Button(L("cancel"), role: .cancel) {}
                } message: {
                    Text(L("sign_out_wipe_msg"))
                }
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.icloud").foregroundColor(.orange)
                        Text(L("sign_in_sync"))
                            .font(.system(size: 13)).foregroundColor(.secondary)
                    }
                    SignInWithAppleButton(.signIn) { request in
                        signInBuilder.configure(request)
                    } onCompletion: { result in
                        handleAppleSignIn(result, rawNonce: signInBuilder.rawNonce)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if let err = signInError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                }
            }
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>, rawNonce: String) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken else {
                signInError = L("token_error"); return
            }
            signInError = nil
            Task {
                do {
                    try await AuthService.shared.signInWithApple(
                        identityToken: identityToken,
                        fullName: credential.fullName,
                        rawNonce: rawNonce
                    )

                    if name.isEmpty, let fn = credential.fullName {
                        let parts = [fn.givenName, fn.familyName].compactMap { $0 }
                        let appleName = parts.joined(separator: " ")
                        if !appleName.isEmpty {
                            name = appleName
                            store.saveSettings(userName: appleName)
                        }
                    }

                    // Signing in no longer rewrites the owner of the
                    // device-only rows. Handing whatever was recorded before
                    // sign-in to whichever account happens to sign in next is a
                    // guess about whose money it is, and it is not reversible
                    // once those rows have been uploaded under that owner.
                    //
                    // They stay on the device under the `local` owner, hidden
                    // from this account, and an issue records that they are
                    // waiting. Task 18 provides the explicit import, where the
                    // owner sees exactly what would move before it moves.
                    store.recordLocalDataAwaitingImport(ownerID: AuthService.shared.userId)

                    // The bounded, identity-based change feed, not the old
                    // 1,000-row fetch that compared identifiers as strings and
                    // duplicated every row Swift had written in uppercase.
                    await store.syncNow()
                } catch {
                    signInError = error.localizedDescription
                }
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            signInError = error.localizedDescription
        }
    }
}
