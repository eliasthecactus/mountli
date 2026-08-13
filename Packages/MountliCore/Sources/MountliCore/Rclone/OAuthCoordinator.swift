import AuthenticationServices
import Foundation
import RcloneCore

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

public final class OAuthCoordinator: NSObject, MountliOAuthListenerProtocol, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    @MainActor private var session: ASWebAuthenticationSession?
    private let cancellationHandler: @Sendable () -> Void

    public init(cancellationHandler: @escaping @Sendable () -> Void = {}) {
        self.cancellationHandler = cancellationHandler
        super.init()
    }

    public func install() {
        MountliSetOAuthListener(self)
    }

    public func uninstall() {
        MountliSetOAuthListener(nil)
        Task { @MainActor in
            session?.cancel()
            session = nil
        }
    }

    public func cancel() {
        Task { @MainActor in
            session?.cancel()
            session = nil
        }
    }

    public nonisolated func open(_ url: String?) -> Bool {
        guard let url, let authorizationURL = URL(string: url) else { return false }
        Task { @MainActor in
            session?.cancel()
            let browserSession = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: nil
            ) { [weak self] _, error in
                if let authenticationError = error as? ASWebAuthenticationSessionError,
                    authenticationError.code == .canceledLogin
                {
                    self?.cancellationHandler()
                }
                Task { @MainActor in self?.session = nil }
            }
            browserSession.presentationContextProvider = self
            browserSession.prefersEphemeralWebBrowserSession = true
            session = browserSession
            if !browserSession.start() { session = nil }
        }
        return true
    }

    @MainActor
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #endif
    }
}
