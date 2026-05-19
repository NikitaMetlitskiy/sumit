import Foundation
import AuthenticationServices
import SwiftUI
import Combine

// MARK: — Supabase Auth Session
struct SupabaseSession: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userId: String
    let email: String?
    let fullName: String?

    /// Treat as expired 60s before actual expiry to give refresh some headroom.
    var isExpired: Bool { Date.now.addingTimeInterval(60) >= expiresAt }
}

// MARK: — AuthService
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isSignedIn: Bool = false
    @Published var userId: String = "local"
    @Published var userEmail: String? = nil
    @Published var userFullName: String? = nil

    private var supabaseURL: String { AppConfig.supabaseURL }
    private var supabaseKey: String { AppConfig.supabaseAnonKey }

    private let sessionKey = "supabase_session"          // Keychain key
    private let legacyDefaultsKey = "supabase_session"   // for one-time migration from UserDefaults

    /// Tracks an in-flight refresh so concurrent callers wait on the same Task.
    private var refreshTask: Task<Bool, Never>?

    private init() {
        migrateLegacySession()
        restoreSession()
    }

    /// Current access token (nil if not signed in)
    var accessToken: String? {
        guard isSignedIn else { return nil }
        return loadSession()?.accessToken
    }

    // MARK: — Sign in with Apple → Supabase
    /// `rawNonce` is the unhashed value used to seed `request.nonce = sha256(rawNonce)`.
    /// Supabase verifies that `sha256(rawNonce) == id_token.nonce` to prevent replay.
    func signInWithApple(identityToken: Data, fullName: PersonNameComponents?, rawNonce: String) async throws {
        guard let tokenString = String(data: identityToken, encoding: .utf8) else {
            throw AuthError.invalidToken
        }
        guard tokenString.split(separator: ".").count == 3 else { throw AuthError.invalidToken }

        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=id_token") else {
            throw AuthError.invalidURL
        }

        let body: [String: Any] = [
            "provider": "apple",
            "id_token": tokenString,
            "nonce": rawNonce
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthError.networkError }

        if http.statusCode >= 400 {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            Log.error("Auth error \(http.statusCode)")
            throw AuthError.serverError(http.statusCode, errorBody)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int,
              expiresIn > 0 else {
            throw AuthError.invalidResponse
        }

        let user = json["user"] as? [String: Any] ?? [:]
        let uid = user["id"] as? String ?? ""
        guard UUID(uuidString: uid) != nil else { throw AuthError.invalidResponse }

        let name: String?
        if let fn = fullName {
            let parts = [fn.givenName, fn.familyName].compactMap { $0 }
            name = parts.isEmpty ? nil : parts.joined(separator: " ")
        } else {
            name = nil
        }

        let email = user["email"] as? String

        let session = SupabaseSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date.now.addingTimeInterval(TimeInterval(expiresIn)),
            userId: uid,
            email: email,
            fullName: name
        )

        saveSession(session)
        applySession(session)

        if let name = name {
            Task { try? await updateProfile(fullName: name) }
        }
        Log.info("Signed in")
    }

    // MARK: — Refresh token (serialized: concurrent calls share one in-flight Task)
    @discardableResult
    func refreshSessionIfNeeded() async -> Bool {
        if let existing = refreshTask { return await existing.value }

        guard let session = loadSession(), session.isExpired else { return true }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            defer { Task { @MainActor in self.refreshTask = nil } }
            return await self.performRefresh(session: session)
        }
        refreshTask = task
        return await task.value
    }

    private func performRefresh(session: SupabaseSession) async -> Bool {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token") else {
            return false
        }

        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(supabaseKey, forHTTPHeaderField: "apikey")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                Log.warn("Token refresh failed — signing out")
                signOut()
                return false
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let newAccess = json["access_token"] as? String,
                  let newRefresh = json["refresh_token"] as? String,
                  let expiresIn = json["expires_in"] as? Int else {
                signOut()
                return false
            }

            let newSession = SupabaseSession(
                accessToken: newAccess,
                refreshToken: newRefresh,
                expiresAt: Date.now.addingTimeInterval(TimeInterval(expiresIn)),
                userId: session.userId,
                email: session.email,
                fullName: session.fullName
            )
            saveSession(newSession)
            applySession(newSession)
            Log.debug("Token refreshed")
            return true
        } catch {
            Log.error("Refresh error")
            return false
        }
    }

    // MARK: — Sign out
    /// `wipeLocalData` — when true, also clears SwiftData rows on the main context (caller-supplied closure).
    func signOut(localDataWipe: (() -> Void)? = nil) {
        if let token = accessToken {
            Task.detached { [supabaseURL = self.supabaseURL, supabaseKey = self.supabaseKey] in
                guard let url = URL(string: "\(supabaseURL)/auth/v1/logout") else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(supabaseKey, forHTTPHeaderField: "apikey")
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                _ = try? await URLSession.shared.data(for: req)
            }
        }

        KeychainHelper.remove(sessionKey)
        isSignedIn = false
        userId = "local"
        userEmail = nil
        userFullName = nil
        localDataWipe?()
        Log.info("Signed out")
    }

    // MARK: — Update profile
    private func updateProfile(fullName: String) async throws {
        guard let session = loadSession() else { return }
        var components = URLComponents(string: "\(supabaseURL)/rest/v1/profiles")
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(session.userId)")]
        guard let url = components?.url else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["full_name": fullName])
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: — Session persistence (Keychain)
    private func saveSession(_ session: SupabaseSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        KeychainHelper.set(data, for: sessionKey)
    }

    private func loadSession() -> SupabaseSession? {
        guard let data = KeychainHelper.get(sessionKey) else { return nil }
        return try? JSONDecoder().decode(SupabaseSession.self, from: data)
    }

    private func restoreSession() {
        guard let session = loadSession() else { return }
        if !session.isExpired {
            applySession(session)
        } else {
            applySession(session)  // still mark as signed-in; refresh will run on first foreground
            Task { await refreshSessionIfNeeded() }
        }
    }

    private func applySession(_ session: SupabaseSession) {
        isSignedIn = true
        userId = session.userId
        userEmail = session.email
        userFullName = session.fullName
    }

    /// One-time move from UserDefaults to Keychain for users updating from a previous build.
    private func migrateLegacySession() {
        guard KeychainHelper.get(sessionKey) == nil,
              let data = UserDefaults.standard.data(forKey: legacyDefaultsKey) else { return }
        KeychainHelper.set(data, for: sessionKey)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        Log.info("Migrated legacy session to Keychain")
    }
}

// MARK: — Errors
enum AuthError: LocalizedError {
    case invalidToken
    case invalidURL
    case networkError
    case serverError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidToken:     return L("auth_invalid_token")
        case .invalidURL:       return L("auth_invalid_url")
        case .networkError:     return L("auth_network_error")
        case .serverError:      return L("auth_server_error")
        case .invalidResponse:  return L("auth_invalid_response")
        }
    }
}

// MARK: — Apple Sign In Coordinator
/// Encapsulates nonce generation + sign-in flow. Caller invokes `start()` and provides
/// a completion handler. Coordinator owns the rawNonce until Supabase verification.
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    var onComplete: ((Result<Void, Error>) -> Void)?
    private var currentNonce: String?

    func startSignIn() {
        let nonce = SecurityHelper.randomNonce(length: 32)
        currentNonce = nonce
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = SecurityHelper.sha256Hex(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return UIWindow()
        }
        return window
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken,
              let nonce = currentNonce else {
            onComplete?(.failure(AuthError.invalidToken))
            return
        }

        Task { @MainActor in
            do {
                try await AuthService.shared.signInWithApple(
                    identityToken: identityToken,
                    fullName: credential.fullName,
                    rawNonce: nonce
                )
                onComplete?(.success(()))
            } catch {
                onComplete?(.failure(error))
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code == .canceled { return }
        onComplete?(.failure(error))
    }
}

// MARK: — Public helper to start a managed Apple sign-in from SwiftUI button
/// SwiftUI `SignInWithAppleButton` requires us to set `request.nonce` ourselves;
/// this helper wires the nonce and returns it for verification.
/// Used as `@State` in views since the rawNonce is short-lived.
@MainActor
final class AppleSignInRequestBuilder: ObservableObject {
    var rawNonce: String = ""

    func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = SecurityHelper.randomNonce(length: 32)
        rawNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = SecurityHelper.sha256Hex(nonce)
    }
}
