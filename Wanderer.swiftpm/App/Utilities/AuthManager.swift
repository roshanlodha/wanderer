import SwiftUI
import Security
import AuthenticationServices

@Observable
class AuthManager {
    var isAuthenticated: Bool = false
    var isGuest: Bool = false
    var userIdentifier: String?
    
    init() {
        checkSavedAuth()
    }
    
    func checkSavedAuth() {
        // For guest bypass
        if UserDefaults.standard.bool(forKey: "isGuestUser") {
            self.isGuest = true
            return
        }
        
        if let storedId = UserDefaults.standard.string(forKey: "appleUserIdentifier") {
            let provider = ASAuthorizationAppleIDProvider()
            provider.getCredentialState(forUserID: storedId) { [weak self] state, error in
                DispatchQueue.main.async {
                    if state == .authorized {
                        self?.isAuthenticated = true
                        self?.userIdentifier = storedId
                    } else {
                        self?.isAuthenticated = false
                        self?.userIdentifier = nil
                        UserDefaults.standard.removeObject(forKey: "appleUserIdentifier")
                    }
                }
            }
        }
    }
    
    func signInAsGuest() {
        isGuest = true
        isAuthenticated = false
        userIdentifier = nil
        UserDefaults.standard.set(true, forKey: "isGuestUser")
        UserDefaults.standard.removeObject(forKey: "appleUserIdentifier")
    }
    
    func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                let userId = appleIDCredential.user
                self.userIdentifier = userId
                self.isAuthenticated = true
                self.isGuest = false
                
                // Save to UserDefaults (For MVP. In production, use Keychain)
                UserDefaults.standard.set(userId, forKey: "appleUserIdentifier")
                UserDefaults.standard.set(false, forKey: "isGuestUser")
            }
        case .failure(let error):
            print("Apple Sign In failed: \(error.localizedDescription)")
        }
    }
    
    func signOut() {
        self.isAuthenticated = false
        self.isGuest = false
        self.userIdentifier = nil
        UserDefaults.standard.removeObject(forKey: "appleUserIdentifier")
        UserDefaults.standard.removeObject(forKey: "isGuestUser")
    }
}
