import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    private let oauthService = OAuthService()
    
    @State private var isConnectingGoogle = false
    @State private var isConnectingMicrosoft = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Account")) {
                    if authManager.isGuest {
                        Text("Signed in as Guest")
                            .foregroundColor(.secondary)
                    } else if let id = authManager.userIdentifier {
                        Text("Signed in with Apple")
                            .badge("Connected")
                    }
                    
                    Button("Sign Out", role: .destructive) {
                        authManager.signOut()
                    }
                }
                
                Section(header: Text("Email Sync"), footer: Text("Connect your email to automatically import travel reservations.")) {
                    Button(action: { connectGoogle() }) {
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(.red)
                            Text("Connect Google")
                            Spacer()
                            if isConnectingGoogle {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isConnectingGoogle || isConnectingMicrosoft)
                    
                    Button(action: { connectMicrosoft() }) {
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(.blue)
                            Text("Connect Microsoft")
                            Spacer()
                            if isConnectingMicrosoft {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isConnectingGoogle || isConnectingMicrosoft)
                }
                
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
    
    private func connectGoogle() {
        isConnectingGoogle = true
        errorMessage = nil
        oauthService.authenticate(provider: .google) { result in
            DispatchQueue.main.async {
                self.isConnectingGoogle = false
                switch result {
                case .success(let token):
                    print("Google connected successfully. Token: \(token)")
                    // Save token securely
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func connectMicrosoft() {
        isConnectingMicrosoft = true
        errorMessage = nil
        oauthService.authenticate(provider: .microsoft) { result in
            DispatchQueue.main.async {
                self.isConnectingMicrosoft = false
                switch result {
                case .success(let token):
                    print("Microsoft connected successfully. Token: \(token)")
                    // Save token securely
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
