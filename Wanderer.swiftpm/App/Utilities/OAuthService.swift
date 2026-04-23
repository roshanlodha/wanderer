import Foundation
import AuthenticationServices

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

class OAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Provider {
        case google
        case microsoft
        
        var authURL: URL {
            switch self {
            case .google:
                return URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=PLACEHOLDER_GOOGLE_CLIENT_ID&redirect_uri=wanderer://oauth2/google&response_type=token&scope=https://mail.google.com/")!
            case .microsoft:
                return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=PLACEHOLDER_MICROSOFT_CLIENT_ID&redirect_uri=wanderer://oauth2/microsoft&response_type=token&scope=Mail.Read")!
            }
        }
        
        var scheme: String {
            return "wanderer"
        }
    }
    
    private var authSession: ASWebAuthenticationSession?
    
    func authenticate(provider: Provider, completion: @escaping (Result<String, Error>) -> Void) {
        authSession = ASWebAuthenticationSession(url: provider.authURL, callbackURLScheme: provider.scheme) { callbackURL, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let callbackURL = callbackURL,
                  let fragment = callbackURL.fragment else {
                completion(.failure(NSError(domain: "OAuthServiceError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])))
                return
            }
            
            // Extract the access token from the fragment
            let components = fragment.components(separatedBy: "&")
            for component in components {
                let pair = component.components(separatedBy: "=")
                if pair.count == 2, pair[0] == "access_token" {
                    let token = pair[1]
                    completion(.success(token))
                    return
                }
            }
            
            completion(.failure(NSError(domain: "OAuthServiceError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Token not found in callback"])))
        }
        
        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false
        authSession?.start()
    }
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #elseif os(macOS)
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
