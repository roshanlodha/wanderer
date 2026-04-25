import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var oauthService = OAuthService()
    @State private var isConnectingGoogle = false
    @State private var isConnectingMicrosoft = false
    @State private var errorMessage: String?
    
    // Reactive connected state
    @State private var googleConnected: Bool = false
    @State private var microsoftConnected: Bool = false
    
    // AI Settings
    @AppStorage("extractionEngine") private var extractionEngine: String = "Cloud (OpenAI)"
    @AppStorage("cloudModelSelection") private var cloudModelSelection: String = "Nano"
    @State private var openAIApiKey: String = ""
    
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
                    providerRow(
                        icon: "envelope.fill",
                        color: .red,
                        name: "Google",
                        isConnected: googleConnected,
                        isConnecting: isConnectingGoogle,
                        provider: .google
                    )
                    
                    providerRow(
                        icon: "envelope.fill",
                        color: .blue,
                        name: "Microsoft",
                        isConnected: microsoftConnected,
                        isConnecting: isConnectingMicrosoft,
                        provider: .microsoft
                    )
                } header: {
                    Text("Email Sync")
                } footer: {
                    Text("Connect your email to automatically import travel reservations. Emails are only fetched for trips you create, within the trip's date range.")
                }
                
                // MARK: - AI Settings
                Section {
                    Picker("Extraction Engine", selection: $extractionEngine) {
                        Text("Cloud (OpenAI)").tag("Cloud (OpenAI)")
                        Text("Apple Intelligence").tag("Apple Intelligence")
                        Text("Local (MLX)").tag("Local (MLX)")
                    }
                    .pickerStyle(.segmented)
                    
                    if extractionEngine == "Cloud (OpenAI)" {
                        Picker("Cloud Model", selection: $cloudModelSelection) {
                            Text("Mini").tag("Mini")
                            Text("Nano").tag("Nano")
                            Text("SOTA").tag("SOTA")
                        }
                        
                        SecureField("OpenAI API Key", text: $openAIApiKey)
                            .onChange(of: openAIApiKey) { _, newValue in
                                KeychainManager.shared.save(newValue, forKey: .openAIApiKey)
                            }
                    }
                } header: {
                    Text("Intelligence")
                } footer: {
                    if extractionEngine == "Apple Intelligence" {
                        Text("Warning: Apple Intelligence has a limited context window. Large emails will be truncated and may lead to parsing errors.")
                            .foregroundColor(.orange)
                    } else {
                        Text("Select where your emails are processed to extract itinerary details.")
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "checkmark")
                            .foregroundColor(.blue)
                            .fontWeight(.bold)
                    }
                }
            }
            .onAppear {
                refreshConnectionState()
                if let key = KeychainManager.shared.get(forKey: .openAIApiKey) {
                    openAIApiKey = key
                }
            }
        }
    }
    
    // MARK: - Provider Row
    
    @ViewBuilder
    private func providerRow(icon: String, color: Color, name: String, isConnected: Bool, isConnecting: Bool, provider: OAuthService.Provider) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(name)
            
            Spacer()
            
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else if isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Connected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Button("Disconnect", role: .destructive) {
                    oauthService.disconnect(provider: provider)
                    refreshConnectionState()
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            } else {
                Button("Connect") {
                    connectProvider(provider)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
    
    // MARK: - Actions
    
    private func refreshConnectionState() {
        googleConnected = oauthService.isConnected(provider: .google)
        microsoftConnected = oauthService.isConnected(provider: .microsoft)
        print("[SettingsView] State refreshed — Google: \(googleConnected), Microsoft: \(microsoftConnected)")
    }
    
    private func connectProvider(_ provider: OAuthService.Provider) {
        errorMessage = nil
        
        switch provider {
        case .google: isConnectingGoogle = true
        case .microsoft: isConnectingMicrosoft = true
        }
        
        Task {
            defer {
                Task { @MainActor in
                    switch provider {
                    case .google: isConnectingGoogle = false
                    case .microsoft: isConnectingMicrosoft = false
                    }
                }
            }
            
            do {
                _ = try await oauthService.authenticate(provider: provider)
                await MainActor.run {
                    refreshConnectionState()
                }
            } catch {
                await MainActor.run {
                    let nsError = error as NSError
                    // Suppress user-cancelled errors
                    if nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1 {
                        // User cancelled — no error to show
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}
