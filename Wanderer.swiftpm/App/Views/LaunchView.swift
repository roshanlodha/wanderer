import SwiftUI
import AuthenticationServices

struct LaunchView: View {
    @Environment(AuthManager.self) var authManager
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: "globe.americas.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .foregroundColor(.blue)
            
            Text("Wanderer")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Your personal travel companion")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            VStack(spacing: 16) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    authManager.handleAppleSignIn(result: result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .frame(maxWidth: 340)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                
                Button(action: {
                    authManager.signInAsGuest()
                }) {
                    Text("Continue as Guest")
                        .font(.headline)
                        .foregroundColor(.blue)
                }
                .padding(.bottom, 20)
            }
        }
    }
}
