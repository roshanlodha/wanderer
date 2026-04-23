import Foundation
import AuthenticationServices
import CryptoKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - ⚠️ Configuration — Fill in your real credentials here

enum OAuthConfig {
    enum Google {
        /// Create at: https://console.cloud.google.com/apis/credentials
        /// Type: iOS app (or "Desktop app" for Mac Catalyst)
        static let clientID = "251569997541-p9broteupleia5q0rjlpp88qu3t53hca.apps.googleusercontent.com"
        
        /// For iOS native apps, Google uses the reversed client ID as the redirect URI scheme.
        /// e.g. "com.googleusercontent.apps.YOUR_CLIENT_ID"
        /// For ASWebAuthenticationSession, we use our custom scheme:
        static let redirectURI = "wanderer://oauth2/google"
        
        static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
        static let tokenEndpoint = "https://oauth2.googleapis.com/token"
        static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    }
    
    enum Microsoft {
        /// Create at: https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps
        /// Type: Mobile and desktop applications
        static let clientID = "YOUR_MICROSOFT_CLIENT_ID"
        
        static let redirectURI = "wanderer://oauth2/microsoft"
        static let authEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        static let tokenEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        static let scope = "Mail.Read offline_access"
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
    
    enum Provider {
        case google
        case microsoft
        
        var callbackScheme: String { "wanderer" }
    }
    
    private var authSession: ASWebAuthenticationSession?
    
    // MARK: - PKCE Helpers
    
    private func generateCodeVerifier() -> String {
        // 32 random bytes → 43-character base64url string
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
    
    func authenticate(provider: Provider) async throws -> OAuthTokenResponse {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        
        let authURL = buildAuthURL(provider: provider, codeChallenge: codeChallenge)
        let authCode = try await startAuthSession(url: authURL, scheme: provider.callbackScheme)
        let tokenResponse = try await exchangeCodeForToken(
            provider: provider,
            code: authCode,
            codeVerifier: codeVerifier
        )
        
        // Persist tokens
        saveTokens(provider: provider, response: tokenResponse)
        
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
            
        case .microsoft:
            var components = URLComponents(string: OAuthConfig.Microsoft.authEndpoint)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: OAuthConfig.Microsoft.clientID),
                URLQueryItem(name: "redirect_uri", value: OAuthConfig.Microsoft.redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: OAuthConfig.Microsoft.scope),
                URLQueryItem(name: "code_challenge", value: codeChallenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "response_mode", value: "query")
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
                    "code": code,
                    "code_verifier": codeVerifier,
                    "grant_type": "authorization_code",
                    "redirect_uri": OAuthConfig.Google.redirectURI
                ])
            case .microsoft:
                return (OAuthConfig.Microsoft.tokenEndpoint, [
                    "client_id": OAuthConfig.Microsoft.clientID,
                    "code": code,
                    "code_verifier": codeVerifier,
                    "grant_type": "authorization_code",
                    "redirect_uri": OAuthConfig.Microsoft.redirectURI
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
            print("Token exchange failed: \(responseBody)")
            throw OAuthError.tokenExchangeFailed
        }
        
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }
    
    // MARK: - Token Persistence
    
    private func saveTokens(provider: Provider, response: OAuthTokenResponse) {
        let keychain = KeychainManager.shared
        
        switch provider {
        case .google:
            keychain.save(response.accessToken, forKey: .googleAccessToken)
            if let refresh = response.refreshToken {
                keychain.save(refresh, forKey: .googleRefreshToken)
            }
        case .microsoft:
            keychain.save(response.accessToken, forKey: .microsoftAccessToken)
            if let refresh = response.refreshToken {
                keychain.save(refresh, forKey: .microsoftRefreshToken)
            }
        }
    }
    
    // MARK: - Disconnect
    
    func disconnect(provider: Provider) {
        let keychain = KeychainManager.shared
        switch provider {
        case .google:
            keychain.delete(forKey: .googleAccessToken)
            keychain.delete(forKey: .googleRefreshToken)
        case .microsoft:
            keychain.delete(forKey: .microsoftAccessToken)
            keychain.delete(forKey: .microsoftRefreshToken)
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
    
    var errorDescription: String? {
        switch self {
        case .missingAuthCode:
            return "Authorization code was not returned by the provider."
        case .sessionStartFailed:
            return "Failed to start the authentication session."
        case .tokenExchangeFailed:
            return "Failed to exchange the authorization code for an access token."
        }
    }
}
