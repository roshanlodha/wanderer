import Foundation
import AuthenticationServices
import CryptoKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Configuration (loaded from Secrets.plist)

enum OAuthConfig {
    
    /// Load secrets from Secrets.plist bundled in the app.
    private static let secrets: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            print("[OAuthConfig] ⚠️ Secrets.plist not found or unreadable. OAuth will not work.")
            return [:]
        }
        return dict
    }()
    
    enum Google {
        static var clientID: String { OAuthConfig.secrets["GoogleClientID"] ?? "" }
        static var clientSecret: String { OAuthConfig.secrets["GoogleClientSecret"] ?? "" }
        
        static var reversedClientID: String {
            // Reversed client ID for redirect: com.googleusercontent.apps.<prefix>
            let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            return "com.googleusercontent.apps.\(prefix)"
        }
        static var redirectURI: String { "\(reversedClientID):/oauthredirect" }
        
        static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
        static let tokenEndpoint = "https://oauth2.googleapis.com/token"
        static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    }
    
}

// MARK: - Token Response

struct OAuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - OAuth Service

class OAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    
    enum Provider: CustomStringConvertible {
        case google
        
        var callbackScheme: String {
            switch self {
            case .google:
                return OAuthConfig.Google.reversedClientID
            }
        }
        
        var description: String {
            switch self {
            case .google: return "Google"
            }
        }
    }
    
    private var authSession: ASWebAuthenticationSession?
    
    // MARK: - PKCE Helpers
    
    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    // MARK: - Public API
    
    /// Returns true if the given provider has a stored access token.
    func isConnected(provider: Provider) -> Bool {
        let keychain = KeychainManager.shared
        switch provider {
        case .google: return keychain.hasToken(forKey: .googleAccessToken)
        }
    }
    
    func authenticate(provider: Provider) async throws -> OAuthTokenResponse {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        
        let authURL = buildAuthURL(provider: provider, codeChallenge: codeChallenge)
        print("[OAuthService] Starting auth session for \(provider)...")
        
        let authCode = try await startAuthSession(url: authURL, scheme: provider.callbackScheme)
        print("[OAuthService] Got auth code, exchanging for token...")
        
        let tokenResponse = try await exchangeCodeForToken(
            provider: provider,
            code: authCode,
            codeVerifier: codeVerifier
        )
        print("[OAuthService] Token exchange successful (access_token length: \(tokenResponse.accessToken.count), refresh_token: \(tokenResponse.refreshToken != nil ? "present" : "nil"))")
        
        // Persist tokens and verify
        let saved = saveTokens(provider: provider, response: tokenResponse)
        if saved {
            print("[OAuthService] ✅ Tokens saved and verified for \(provider).")
        } else {
            print("[OAuthService] ❌ Token save FAILED for \(provider)!")
            throw OAuthError.tokenSaveFailed
        }
        
        return tokenResponse
    }
    
    // MARK: - Build Auth URL
    
    private func buildAuthURL(provider: Provider, codeChallenge: String) -> URL {
        switch provider {
        case .google:
            var components = URLComponents(string: OAuthConfig.Google.authEndpoint)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: OAuthConfig.Google.clientID),
                URLQueryItem(name: "redirect_uri", value: OAuthConfig.Google.redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: OAuthConfig.Google.scope),
                URLQueryItem(name: "code_challenge", value: codeChallenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent")
            ]
            return components.url!
        }
    }
    
    // MARK: - ASWebAuthenticationSession
    
    private func startAuthSession(url: URL, scheme: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: OAuthError.missingAuthCode)
                    return
                }
                
                continuation.resume(returning: code)
            }
            
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            
            self.authSession = session // retain it
            
            if !session.start() {
                continuation.resume(throwing: OAuthError.sessionStartFailed)
            }
        }
    }
    
    // MARK: - Token Exchange
    
    private func exchangeCodeForToken(
        provider: Provider,
        code: String,
        codeVerifier: String
    ) async throws -> OAuthTokenResponse {
        let (tokenEndpoint, params): (String, [String: String]) = {
            switch provider {
            case .google:
                return (OAuthConfig.Google.tokenEndpoint, [
                    "client_id": OAuthConfig.Google.clientID,
                    "client_secret": OAuthConfig.Google.clientSecret,
                    "code": code,
                    "code_verifier": codeVerifier,
                    "grant_type": "authorization_code",
                    "redirect_uri": OAuthConfig.Google.redirectURI
                ])
            }
        }()
        
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "No body"
            print("[OAuthService] Token exchange failed: \(responseBody)")
            throw OAuthError.tokenExchangeFailed
        }
        
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }
    
    // MARK: - Token Persistence
    
    /// Saves tokens and returns true only if the save can be verified by reading back.
    private func saveTokens(provider: Provider, response: OAuthTokenResponse) -> Bool {
        let keychain = KeychainManager.shared
        
        switch provider {
        case .google:
            keychain.save(response.accessToken, forKey: .googleAccessToken)
            if let refresh = response.refreshToken {
                keychain.save(refresh, forKey: .googleRefreshToken)
            }
            // Verify the save actually worked
            let verified = keychain.hasToken(forKey: .googleAccessToken)
            print("[OAuthService] Google token save verified: \(verified)")
            return verified
        }
    }
    
    // MARK: - Disconnect
    
    func disconnect(provider: Provider) {
        let keychain = KeychainManager.shared
        switch provider {
        case .google:
            keychain.delete(forKey: .googleAccessToken)
            keychain.delete(forKey: .googleRefreshToken)
        }
    }
    
    // MARK: - Presentation Anchor
    
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

// MARK: - Errors

enum OAuthError: LocalizedError {
    case missingAuthCode
    case sessionStartFailed
    case tokenExchangeFailed
    case tokenSaveFailed
    
    var errorDescription: String? {
        switch self {
        case .missingAuthCode:
            return "Authorization code was not returned by the provider."
        case .sessionStartFailed:
            return "Failed to start the authentication session."
        case .tokenExchangeFailed:
            return "Failed to exchange the authorization code for an access token."
        case .tokenSaveFailed:
            return "Token was received but could not be saved to local storage."
        }
    }
}
