import Foundation
@preconcurrency import GoogleSignIn
import UIKit

enum GoogleAuthError: LocalizedError {
    case notConfigured
    case noPresentingController
    case notSignedIn
    case missingUserID
    case missingToken

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Add your Google iOS OAuth client ID to Info.plist before connecting."
        case .noPresentingController:
            "The Google sign-in screen could not be presented."
        case .notSignedIn:
            "Connect your Google account first."
        case .missingUserID:
            "Google did not return a user identifier."
        case .missingToken:
            "Google did not return an access token."
        }
    }
}

@MainActor
final class GoogleAuthService: ObservableObject {
    static let driveReadOnlyScope = "https://www.googleapis.com/auth/drive.readonly"
    static let driveAppDataScope = "https://www.googleapis.com/auth/drive.appdata"

    @Published private(set) var isSignedIn = false
    @Published private(set) var email: String?
    @Published private(set) var userID: String?
    @Published private(set) var isRestoring = true

    var isConfigured: Bool {
        guard let clientID = Self.clientID else { return false }
        return !clientID.contains("YOUR_IOS_CLIENT_ID")
    }

    private static var clientID: String? {
        Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
    }

    init() {
        if let clientID = Self.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    func restore() async {
        defer { isRestoring = false }
        guard isConfigured else {
            apply(user: nil)
            return
        }
        do {
            let userBox = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UnsafeSendableBox<GIDGoogleUser?>, Error>) in
                GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: UnsafeSendableBox(user))
                    }
                }
            }
            apply(user: userBox.value)
        } catch {
            apply(user: nil)
        }
    }

    func signIn(hint: String? = nil) async throws {
        guard isConfigured else { throw GoogleAuthError.notConfigured }
        guard let presenter = UIApplication.shared.topViewController else {
            throw GoogleAuthError.noPresentingController
        }

        let result = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<GIDSignInResult, Error>) in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: hint,
                additionalScopes: [Self.driveReadOnlyScope, Self.driveAppDataScope]
            ) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: GoogleAuthError.notSignedIn)
                }
            }
        }
        apply(user: result.user)
    }

    func switchAccount(hint: String? = nil) async throws {
        GIDSignIn.sharedInstance.signOut()
        apply(user: nil)
        try await signIn(hint: hint)
    }

    func accessToken() async throws -> String {
        guard let current = GIDSignIn.sharedInstance.currentUser else {
            throw GoogleAuthError.notSignedIn
        }
        let refreshed = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<GIDGoogleUser, Error>) in
            current.refreshTokensIfNeeded { user, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let user {
                    continuation.resume(returning: user)
                } else {
                    continuation.resume(throwing: GoogleAuthError.missingToken)
                }
            }
        }
        let token = refreshed.accessToken.tokenString
        guard !token.isEmpty else { throw GoogleAuthError.missingToken }
        apply(user: refreshed)
        return token
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        apply(user: nil)
    }

    func disconnect() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            GIDSignIn.sharedInstance.disconnect { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        apply(user: nil)
    }

    func handle(url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    private func apply(user: GIDGoogleUser?) {
        isSignedIn = user != nil
        email = user?.profile?.email
        userID = user?.userID
    }
}

private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    nonisolated(unsafe) let value: Value

    nonisolated init(_ value: Value) {
        self.value = value
    }
}

private extension UIApplication {
    var topViewController: UIViewController? {
        let scene = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        return root?.topmost
    }
}

private extension UIViewController {
    var topmost: UIViewController {
        if let presentedViewController {
            return presentedViewController.topmost
        }
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.topmost ?? navigation
        }
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topmost ?? tab
        }
        return self
    }
}
