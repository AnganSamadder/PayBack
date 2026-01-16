import SwiftUI

struct AuthFlowView: View {
    @StateObject private var coordinator: AuthCoordinator
    let onAuthenticated: (UserSession) -> Void

    init(
        store: AppStore,
        accountService: AccountService = Dependencies.current.accountService,
        emailAuthService: EmailAuthService = Dependencies.current.emailAuthService,
        onAuthenticated: @escaping (UserSession) -> Void
    ) {
        _coordinator = StateObject(wrappedValue: AuthCoordinator(store: store, accountService: accountService, emailAuthService: emailAuthService))
        self.onAuthenticated = onAuthenticated
    }

    var body: some View {
        ZStack {
            AuthBackground()
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: coordinator.route)
        .onAppear { coordinator.start() }
        .onChange(of: coordinator.route) { oldValue, newValue in
            if case .authenticated(let session) = newValue {
                onAuthenticated(session)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.route {
        case .login:
            LoginView(
                isBusy: coordinator.isBusy,
                errorMessage: coordinator.errorMessage,
                infoMessage: coordinator.infoMessage,
                showResendConfirmation: coordinator.unconfirmedEmail != nil,
                onLogin: { email, password in
                    Task { await coordinator.login(emailInput: email, password: password) }
                },
                onForgotPassword: { email in
                    Task { await coordinator.sendPasswordReset(emailInput: email) }
                },
                onPrefillSignup: { input in
                    coordinator.openSignup(with: input)
                },
                onResendConfirmation: {
                    Task { await coordinator.resendConfirmationEmail() }
                }
            )
            .frame(maxWidth: 520)
        case .signup(let email):
            SignupView(
                email: email,
                isBusy: coordinator.isBusy,
                errorMessage: coordinator.errorMessage,
                onSubmit: { email, firstName, lastName, password in
                    Task { await coordinator.signup(emailInput: email, firstName: firstName, lastName: lastName, password: password) }
                },
                onBack: {
                    withAnimation {
                        coordinator.start()
                    }
                }
            )
            .frame(maxWidth: 520)
        case .verification(let email, _):
            CodeVerificationView(
                email: email,
                isBusy: coordinator.isBusy,
                errorMessage: coordinator.errorMessage,
                onSubmit: { code in
                    Task { await coordinator.verifyCode(code) }
                },
                onBack: {
                    withAnimation {
                        coordinator.start()
                    }
                },
                onResend: {
                    Task { await coordinator.resendVerificationCode() }
                }
            )
            .frame(maxWidth: 520)
        case .authenticated:
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("Signing you in…")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(48)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.7))
            )
        }
    }
}

private struct AuthBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.18, green: 0.22, blue: 0.56),
                Color(red: 0.41, green: 0.13, blue: 0.6),
                Color(red: 0.06, green: 0.55, blue: 0.7)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .blur(radius: 90)
                    .frame(width: 420)
                    .offset(x: -160, y: -220)
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .blur(radius: 80)
                    .frame(width: 380)
                    .offset(x: 180, y: 260)
            }
        )
        .ignoresSafeArea()
    }
}

struct AuthFlowView_Previews: PreviewProvider {
    static var previews: some View {
        AuthFlowView(store: AppStore(), accountService: MockAccountService(), emailAuthService: MockEmailAuthService()) { _ in }
    }
}
