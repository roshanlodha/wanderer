import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var oauthService = OAuthService()
    @State private var isConnectingGoogle = false
    @State private var isConnectingMicrosoft = false
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var syncResultCount: Int?
    
    // Reactive connected state
    @State private var googleConnected: Bool = false
    @State private var microsoftConnected: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Account
                Section(header: Text("Account")) {
                    if authManager.isGuest {
                        Label("Signed in as Guest", systemImage: "person.crop.circle.badge.questionmark")
                            .foregroundColor(.secondary)
                    } else if authManager.userIdentifier != nil {
                        Label("Signed in with Apple", systemImage: "apple.logo")
                            .badge("Connected")
                    }
                    
                    Button("Sign Out", role: .destructive) {
                        authManager.signOut()
                        dismiss()
                    }
                }
                
                // MARK: - Email Sync
                Section {
                    // Google row
                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.red)
                        Text("Google")
                        Spacer()
                        
                        if isConnectingGoogle {
                            ProgressView()
                        } else if googleConnected {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Connected")
                                    .foregroundColor(.secondary)
                            }
                            .font(.subheadline)
                            
                            Button("Disconnect", role: .destructive) {
                                oauthService.disconnect(provider: .google)
                                googleConnected = false
                            }
                            .buttonStyle(.borderless)
                            .padding(.leading, 8)
                        } else {
                            Button("Connect") {
                                connectProvider(.google)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    
                    // Microsoft row
                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.blue)
                        Text("Microsoft")
                        Spacer()
                        
                        if isConnectingMicrosoft {
                            ProgressView()
                        } else if microsoftConnected {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Connected")
                                    .foregroundColor(.secondary)
                            }
                            .font(.subheadline)
                            
                            Button("Disconnect", role: .destructive) {
                                oauthService.disconnect(provider: .microsoft)
                                microsoftConnected = false
                            }
                            .buttonStyle(.borderless)
                            .padding(.leading, 8)
                        } else {
                            Button("Connect") {
                                connectProvider(.microsoft)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Email Sync")
                } footer: {
                    Text("Connect your email to automatically import travel reservations like flights, hotels, and tickets.")
                }
                
                // MARK: - Manual Sync
                if googleConnected || microsoftConnected {
                    Section {
                        Button {
                            syncNow()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Sync Now")
                                Spacer()
                                if isSyncing {
                                    ProgressView()
                                }
                                if let count = syncResultCount {
                                    Text("\(count) emails")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .disabled(isSyncing)
                    } header: {
                        Text("Manual Sync")
                    } footer: {
                        Text("Fetch recent travel emails from connected accounts.")
                    }
                }
                
                // MARK: - Error
                if let errorMessage = errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                refreshConnectionState()
            }
        }
    }
    
    // MARK: - Actions
    
    private func refreshConnectionState() {
        let keychain = KeychainManager.shared
        googleConnected = keychain.hasToken(forKey: .googleAccessToken)
        microsoftConnected = keychain.hasToken(forKey: .microsoftAccessToken)
    }
    
    private func connectProvider(_ provider: OAuthService.Provider) {
        errorMessage = nil
        
        switch provider {
        case .google: isConnectingGoogle = true
        case .microsoft: isConnectingMicrosoft = true
        }
        
        Task {
            do {
                print("[SettingsView] Starting authentication for \(provider)...")
                _ = try await oauthService.authenticate(provider: provider)
                print("[SettingsView] Authentication successful, refreshing connection state...")
                await MainActor.run {
                    refreshConnectionState()
                    print("[SettingsView] googleConnected: \(self.googleConnected), microsoftConnected: \(self.microsoftConnected)")
                }
            } catch {
                print("[SettingsView] Authentication failed with error: \(error)")
                await MainActor.run {
                    // Don't show error for user-cancelled sessions (code 1 = canceledLogin)
                    let nsError = error as NSError
                    if nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1 {
                        print("[SettingsView] User cancelled the session.")
                        // User cancelled — no error to show
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
            
            await MainActor.run {
                switch provider {
                case .google: isConnectingGoogle = false
                case .microsoft: isConnectingMicrosoft = false
                }
            }
        }
    }
    
    private func syncNow() {
        isSyncing = true
        syncResultCount = nil
        errorMessage = nil
        
        Task {
            let emails = await EmailFetchService.shared.fetchAllTravelEmails()
            await MainActor.run {
                syncResultCount = emails.count
                isSyncing = false
            }
        }
    }
}
