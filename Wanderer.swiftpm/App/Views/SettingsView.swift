import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var oauthService = OAuthService()
    @State private var isConnectingGoogle = false
    @State private var errorMessage: String?
    
    // Reactive connected state
    @State private var googleConnected: Bool = false
    
    // AI Settings
    @AppStorage("extractionEngine") private var extractionEngine: String = "Cloud (OpenAI)"
    @AppStorage("extractionCloudModelSelection") private var extractionCloudModelSelection: String = "Nano"
    @AppStorage("classificationMode") private var classificationMode: String = "Smart"
    @AppStorage("classificationEngine") private var classificationEngine: String = "Apple Intelligence"
    @AppStorage("classificationCloudModelSelection") private var classificationCloudModelSelection: String = "Nano"
    @AppStorage("localMLXServerURL") private var localMLXServerURL: String = "http://127.0.0.1:5413"
    @AppStorage("localMLXModel") private var localMLXModel: String = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    @AppStorage("localMLXOnDeviceEnabled") private var localMLXOnDeviceEnabled: Bool = true
    @State private var openAIApiKey: String = ""
    @State private var isDownloadingLocalModel = false
    @State private var localModelDownloadProgress: Double = 0
    @State private var localModelDownloadStatus: String = ""
    @State private var localModelDownloaded = false
    @State private var localModelEstimatedSize: String?
    @State private var showLocalModelDownloadConfirm = false
    @State private var localModelDownloadError: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var isCompactUI: Bool {
        horizontalSizeClass == .compact
    }

    @ViewBuilder
    private var classificationFooter: some View {
        if classificationMode == "Fast" {
            Text("Fast mode skips AI classification and puts all fetched emails into Detected Emails.")
        } else if classificationEngine == "Apple Intelligence" {
            Text("Smart mode uses on-device Apple Intelligence by default for lightweight local classification.")
        } else if classificationEngine == "Local (MLX)" {
            Text("Smart mode supports on-device model downloads and optional SwiftLM server fallback. Recommended: Qwen2.5.")
        } else {
            Text("Smart mode uses AI to split emails into Detected vs Important and filter out non-trip emails.")
        }
    }
    
    @ViewBuilder
    private var extractionFooter: some View {
        if extractionEngine == "Apple Intelligence" {
            Text("Warning: Apple Intelligence has a limited context window. Large emails will be truncated and may lead to parsing errors.")
                .foregroundColor(.orange)
        } else if extractionEngine == "Local (MLX)" {
            Text("Local MLX supports on-device model download with user confirmation. SwiftLM endpoint is optional fallback if you run a local server.")
        } else {
            Text("Select where your emails are processed to extract itinerary details.")
        }
    }
    
    @ViewBuilder
    private var smartClassificationPicker: some View {
        Picker("Classification Engine", selection: $classificationEngine) {
            Text("Apple Intelligence").tag("Apple Intelligence")
            Text("Cloud (OpenAI)").tag("Cloud (OpenAI)")
            Text("Local (MLX)").tag("Local (MLX)")
        }
        .pickerStyle(.segmented)

        if classificationEngine == "Cloud (OpenAI)" {
            Picker("Classification Model", selection: $classificationCloudModelSelection) {
                Text("Mini").tag("Mini")
                Text("Nano").tag("Nano")
                Text("SOTA").tag("SOTA")
            }

            SecureField("OpenAI API Key", text: $openAIApiKey)
                .onChange(of: openAIApiKey) { _, newValue in
                    KeychainManager.shared.save(newValue, forKey: .openAIApiKey)
                }
        } else if classificationEngine == "Local (MLX)" {
            localMLXControls
        }
    }

    @ViewBuilder
    private var extractionPicker: some View {
        Picker("Extraction Engine", selection: $extractionEngine) {
            Text("Cloud (OpenAI)").tag("Cloud (OpenAI)")
            Text("Apple Intelligence").tag("Apple Intelligence")
            Text("Local (MLX)").tag("Local (MLX)")
        }
        .pickerStyle(.segmented)
        
        if extractionEngine == "Cloud (OpenAI)" {
            Picker("Extraction Model", selection: $extractionCloudModelSelection) {
                Text("Mini").tag("Mini")
                Text("Nano").tag("Nano")
                Text("SOTA").tag("SOTA")
            }

            SecureField("OpenAI API Key", text: $openAIApiKey)
                .onChange(of: openAIApiKey) { _, newValue in
                    KeychainManager.shared.save(newValue, forKey: .openAIApiKey)
                }
        } else if extractionEngine == "Local (MLX)" {
            localMLXControls
        }
    }

    @ViewBuilder
    private var localMLXControls: some View {
        HStack {
            TextField("SwiftLM Model", text: $localMLXModel)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            
            Button {
                localMLXModel = LocalMLXModelManager.shared.recommendedModelIDForCurrentDevice()
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.bordered)
            .help("Reset to recommended model for this device")
        }

        Toggle("Prefer On-Device Model", isOn: $localMLXOnDeviceEnabled)

        onDeviceLocalModelControls

        TextField("SwiftLM Server URL (Optional)", text: $localMLXServerURL)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Account
                Section {
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
                } header: {
                    Text("Account")
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
                } header: {
                    Text("Email Sync")
                } footer: {
                    Text("Connect your email to automatically import travel reservations. Emails are filtered using each trip's Ignore Emails Before date.")
                }
                
                Section {
                    Picker("Classification Mode", selection: $classificationMode) {
                        Text("Fast").tag("Fast")
                        Text("Smart").tag("Smart")
                    }
                    .pickerStyle(.segmented)

                    if classificationMode == "Smart" {
                        smartClassificationPicker
                    }
                } header: {
                    Text("Email Classification")
                } footer: {
                    classificationFooter
                }

                // MARK: - AI Settings
                Section {
                    extractionPicker
                } header: {
                    Text("Extraction")
                } footer: {
                    extractionFooter
                }
                
                // MARK: - Error
                if let errorMessage = errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }

                if let localModelDownloadError {
                    Section {
                        Label(localModelDownloadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
            }
            .onAppear {
                refreshConnectionState()
                refreshLocalModelState()
                if UserDefaults.standard.string(forKey: "extractionCloudModelSelection") == nil,
                   let legacy = UserDefaults.standard.string(forKey: "cloudModelSelection") {
                    extractionCloudModelSelection = legacy
                }
                if let key = KeychainManager.shared.get(forKey: .openAIApiKey) {
                    openAIApiKey = key
                }
            }
            .onChange(of: extractionEngine) { _, newValue in
                if newValue == "Local (MLX)" && !localModelDownloaded && !isDownloadingLocalModel {
                    showLocalModelDownloadConfirm = true
                } else if newValue != "Local (MLX)" {
                    LocalMLXModelManager.shared.clearLoadedModel()
                }
            }
            .onChange(of: classificationEngine) { _, newValue in
                if newValue == "Local (MLX)" && !localModelDownloaded && !isDownloadingLocalModel {
                    showLocalModelDownloadConfirm = true
                } else if newValue != "Local (MLX)" {
                    LocalMLXModelManager.shared.clearLoadedModel()
                }
            }
            .onChange(of: localMLXModel) { _, _ in
                LocalMLXModelManager.shared.clearLoadedModel()
                refreshLocalModelState()
            }
            .alert("Download Local Model?", isPresented: $showLocalModelDownloadConfirm) {
                Button("Not Now", role: .cancel) {}
                Button("Download") {
                    startLocalModelDownload()
                }
            } message: {
                let estimate = localModelEstimatedSize ?? "several GB"
                let cap = LocalMLXModelManager.shared.capability(for: localMLXModel)
                
                if !cap.canRun {
                    Text("Warning: \(cap.reason ?? "This model may be too heavy for this device.")\n\nRecommended: \(cap.recommendedModelID)\n\nDownloading anyway will use \(estimate).")
                } else {
                    Text("TripBuddy can download \(localMLXModel) from Hugging Face for on-device MLX parsing. This may use \(estimate) and mobile data.")
                }
            }
        }
    }

    @ViewBuilder
    var onDeviceLocalModelControls: some View {
        if localModelDownloaded {
            Label("On-device model ready", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.subheadline)
        } else {
            Button {
                showLocalModelDownloadConfirm = true
            } label: {
                if isDownloadingLocalModel {
                    HStack(spacing: 8) {
                        ProgressView(value: localModelDownloadProgress, total: 1)
                            .frame(maxWidth: 120)
                        if isCompactUI {
                            Image(systemName: "arrow.down.circle")
                        } else {
                            Text("Downloading")
                                .font(.caption)
                        }
                    }
                } else {
                    if isCompactUI {
                        Label("Download", systemImage: "arrow.down.circle")
                    } else {
                        Label("Download On-Device Model", systemImage: "arrow.down.circle")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDownloadingLocalModel)

            if !localModelDownloadStatus.isEmpty {
                Text(localModelDownloadStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }
    
    // MARK: - Provider Row
    
    @ViewBuilder
    func providerRow(icon: String, color: Color, name: String, isConnected: Bool, isConnecting: Bool, provider: OAuthService.Provider) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(name)
            
            Spacer()
            
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else if isConnected {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Connected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button {
                            oauthService.disconnect(provider: provider)
                            refreshConnectionState()
                            connectProvider(provider)
                        } label: {
                            if isCompactUI {
                                Image(systemName: "arrow.clockwise.circle")
                            } else {
                                Text("Reconnect")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            oauthService.disconnect(provider: provider)
                            refreshConnectionState()
                        } label: {
                            if isCompactUI {
                                Image(systemName: "xmark.circle")
                            } else {
                                Text("Disconnect")
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                    }
                }
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
    
    func refreshConnectionState() {
        googleConnected = oauthService.isConnected(provider: .google)
        print("[SettingsView] State refreshed — Google: \(googleConnected)")
    }

    func refreshLocalModelState() {
        localModelDownloaded = LocalMLXModelManager.shared.isModelDownloaded(modelID: localMLXModel)

        Task {
            let estimate = await LocalMLXModelManager.shared.estimatedSizeString(modelID: localMLXModel)
            await MainActor.run {
                localModelEstimatedSize = estimate
            }
        }
    }

    func startLocalModelDownload() {
        guard !isDownloadingLocalModel else { return }

        isDownloadingLocalModel = true
        localModelDownloadProgress = 0
        localModelDownloadStatus = "Preparing download..."
        localModelDownloadError = nil

        Task {
            do {
                try await LocalMLXModelManager.shared.downloadModel(modelID: localMLXModel) { progress, currentFile in
                    localModelDownloadProgress = progress
                    localModelDownloadStatus = "Downloading \(currentFile)"
                }
                await MainActor.run {
                    isDownloadingLocalModel = false
                    localModelDownloadStatus = "Model download complete"
                    refreshLocalModelState()
                }
            } catch {
                await MainActor.run {
                    isDownloadingLocalModel = false
                    localModelDownloadError = error.localizedDescription
                    localModelDownloadStatus = ""
                }
            }
        }
    }
    
    func connectProvider(_ provider: OAuthService.Provider) {
        errorMessage = nil
        isConnectingGoogle = true
        
        Task {
            defer {
                Task { @MainActor in
                    isConnectingGoogle = false
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
