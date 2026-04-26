import SwiftUI
import AuthenticationServices

struct LaunchView: View {
    @Environment(AuthManager.self) var authManager
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.11, green: 0.13, blue: 0.18), Color(red: 0.06, green: 0.08, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 24)

                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 96, weight: .bold))
                    .foregroundStyle(.blue.gradient)

                VStack(spacing: 8) {
                    Text("Wanderer")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Your personal travel companion")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer(minLength: 8)

                VStack(spacing: 16) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        authManager.handleAppleSignIn(result: result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button(action: {
                        authManager.signInAsGuest()
                    }) {
                        Text("Continue as Guest")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(.white.opacity(0.12))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }
}
