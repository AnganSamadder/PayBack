import Foundation

@MainActor
final class AuthCoordinator: ObservableObject {
    enum Route: Equatable {
        case login
        case signup(presetEmail: String)
        case verification(email: String, displayName: String)
        case passwordResetCode(email: String)
        case passwordResetNewPassword(email: String)
        case authenticated(UserSession)
    }

    @Published private(set) var route: Route = .login
    @Published private(set) var isBusy: Bool = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// Email that needs confirmation - when set, shows the "Resend confirmation" option
    @Published var unconfirmedEmail: String?
    @Published var loginEmail: String = ""
    @Published var loginPassword: String = ""
    @Published var signupEmail: String = ""
    @Published var signupFirstName: String = ""
    @Published var signupLastName: String = ""
    @Published var signupPassword: String = ""
    @Published var signupConfirmPassword: String = ""
    @Published var signupVerificationCode: String = ""
    @Published var passwordResetEmail: String = ""
    @Published var passwordResetCode: String = ""
    @Published var passwordResetNewPassword: String = ""
    @Published var passwordResetConfirmPassword: String = ""

    private let accountService: AccountService
    private let emailAuthService: EmailAuthService
    private let store: AppStore

    /// Stores the display name during signup flow for use after verification
    private var pendingDisplayName: String = ""

    init(
        store: AppStore,
        accountService: AccountService = Dependencies.current.accountService,
        emailAuthService: EmailAuthService = Dependencies.current.emailAuthService
    ) {
        self.store = store
        self.accountService = accountService
        self.emailAuthService = emailAuthService
    }

    func start() {
        if case .authenticated = route {
            return
        }
        route = .login
    }

    func signOut() async {
        try? await emailAuthService.signOut()
        route = .login
    }

    func openSignup(with emailInput: String) {
        let normalized = (try? accountService.normalizedEmail(from: emailInput)) ?? emailInput
        loginEmail = normalized
        signupEmail = normalized
        route = .signup(presetEmail: normalized)
    }

    func backToLoginFromSignup() {
        let normalized = (try? accountService.normalizedEmail(from: signupEmail)) ?? signupEmail
        loginEmail = normalized
        route = .login
    }

    func backToSignupFromVerification() {
        route = .signup(presetEmail: signupEmail)
    }

    func backToLoginFromPasswordReset() {
        loginEmail = passwordResetEmail
        route = .login
    }

    func backToPasswordResetCode() {
        route = .passwordResetCode(email: passwordResetEmail)
    }

    func login(emailInput: String, password: String) async {
        loginEmail = emailInput
        loginPassword = password

        await runBusyTask {
            do {
                let account = try await self.store.login(email: emailInput, password: password)
                self.loginPassword = ""
                self.route = .authenticated(UserSession(account: account))
            } catch PayBackError.authEmailNotConfirmed {
                // Special handling: offer to resend confirmation
                let normalizedEmail = (try? self.accountService.normalizedEmail(from: emailInput)) ?? emailInput
                self.unconfirmedEmail = normalizedEmail
                self.errorMessage = "Please verify your email address before signing in."
            } catch {
                self.handle(error: error)
            }
        }
    }

    func signup(emailInput: String, firstName: String, lastName: String?, password: String) async {
        signupEmail = emailInput
        signupFirstName = firstName
        signupLastName = lastName ?? ""
        signupPassword = password

        await runBusyTask {
            do {
                let result = try await self.store.signup(
                    email: emailInput,
                    firstName: firstName,
                    lastName: lastName,
                    password: password
                )

                switch result {
                case .needsVerification(let email):
                    // Store display name for later and show verification screen
                    let firstNameTrimmed = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lastNameTrimmed = lastName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.pendingDisplayName = [firstNameTrimmed, lastNameTrimmed]
                        .compactMap { $0 }
                        .joined(separator: " ")

                    self.signupEmail = email
                    self.signupVerificationCode = ""
                    self.route = .verification(email: email, displayName: self.pendingDisplayName)

                case .complete(_):
                    self.loginEmail = emailInput
                    self.loginPassword = ""
                    self.signupPassword = ""
                    self.signupConfirmPassword = ""
                    // Auto-login logic inside store handles session setup, we just update route
                    // We need to fetch the account to populate UserSession
                    // store.session should be set by store.signup -> performConvexAuthAndSetup
                    if let session = self.store.session {
                        self.route = .authenticated(session)
                    } else {
                        // Fallback lookup if race condition (shouldn't happen with await)
                        let normalized = try self.accountService.normalizedEmail(from: emailInput)
                        if let account = try await self.accountService.lookupAccount(byEmail: normalized) {
                             self.route = .authenticated(UserSession(account: account))
                        }
                    }
                }
            } catch PayBackError.authSessionMissing {
                // Determine if this was due to verification actually being needed but Clerk returning succes initially
                self.infoMessage = "Please check your email to verify your account before signing in."
                self.route = .login
            } catch {
                self.handle(error: error)
            }
        }
    }

    func verifyCode(_ code: String) async {
        signupVerificationCode = code
        await runBusyTask {
            do {
                let account = try await self.store.verifyCode(code, pendingDisplayName: self.pendingDisplayName)
                self.signupVerificationCode = ""
                self.route = .authenticated(UserSession(account: account))
            } catch {
                self.handle(error: error)
            }
        }
    }

    func resendVerificationCode() async {
        guard case .verification(let email, _) = route else { return }

        await runBusyTask {
            do {
                try await self.emailAuthService.resendConfirmationEmail(email: email)
                self.infoMessage = "A new code has been sent to your email."
            } catch {
                self.handle(error: error)
            }
        }
    }

    func sendPasswordReset(emailInput: String) async {
        loginEmail = emailInput

        await runBusyTask {
            do {
                let normalizedEmail = try self.accountService.normalizedEmail(from: emailInput)
                try await self.emailAuthService.sendPasswordReset(email: normalizedEmail)
                self.loginEmail = normalizedEmail
                self.passwordResetEmail = normalizedEmail
                self.passwordResetCode = ""
                self.passwordResetNewPassword = ""
                self.passwordResetConfirmPassword = ""
                self.route = .passwordResetCode(email: normalizedEmail)
            } catch {
                self.handlePasswordReset(error: error, step: .requestCode)
            }
        }
    }

    func verifyPasswordResetCode(_ code: String) async {
        guard case .passwordResetCode = route else { return }
        passwordResetCode = code

        await runBusyTask {
            do {
                try await self.emailAuthService.verifyPasswordResetCode(code: code)
                self.route = .passwordResetNewPassword(email: self.passwordResetEmail)
            } catch {
                self.handlePasswordReset(error: error, step: .verifyCode)
            }
        }
    }

    func resendPasswordResetCode() async {
        guard case .passwordResetCode = route else { return }

        await runBusyTask {
            do {
                try await self.emailAuthService.resendPasswordResetCode()
                self.infoMessage = "A new reset code has been sent."
            } catch {
                self.handlePasswordReset(error: error, step: .requestCode)
            }
        }
    }

    func completePasswordReset(newPassword: String) async {
        guard case .passwordResetNewPassword = route else { return }
        passwordResetNewPassword = newPassword

        await runBusyTask {
            do {
                let result = try await self.emailAuthService.completePasswordReset(
                    newPassword: newPassword
                )
                switch result {
                case .authenticated(let authResult):
                    do {
                        try await self.store.completeAuthenticationAndWait(
                            email: authResult.email,
                            name: authResult.displayName
                        )
                        guard let session = self.store.session else {
                            throw PayBackError.authSessionMissing
                        }
                        self.route = .authenticated(session)
                    } catch {
                        self.routeToLoginAfterAcceptedPassword()
                    }
                case .requiresSignIn:
                    self.routeToLoginAfterAcceptedPassword()
                }
                self.clearPasswordResetSecrets()
            } catch {
                self.handlePasswordReset(error: error, step: .setPassword)
            }
        }
    }

    func resendConfirmationEmail() async {
        guard let email = unconfirmedEmail else { return }

        await runBusyTask {
            do {
                try await self.emailAuthService.resendConfirmationEmail(email: email)
                self.unconfirmedEmail = nil
                self.errorMessage = nil
                self.infoMessage = "Confirmation email sent! Please check your inbox."
            } catch {
                self.handle(error: error)
            }
        }
    }

    private func runBusyTask(_ operation: @escaping () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        infoMessage = nil
        unconfirmedEmail = nil
        await operation()
    }

    private enum PasswordResetStep {
        case requestCode
        case verifyCode
        case setPassword

        var errorMessage: String {
            switch self {
            case .requestCode:
                return "We couldn't start password reset. Please try again."
            case .verifyCode:
                return "We couldn't verify that reset code. Request a new code and try again."
            case .setPassword:
                return "We couldn't update your password. Please try again."
            }
        }
    }

    private func handlePasswordReset(error: Error, step: PasswordResetStep) {
        if error is CancellationError { return }
#if DEBUG
        print("[AuthCoordinator] Password reset failed at \(step): \(type(of: error))")
#endif
        errorMessage = step.errorMessage
    }

    private func routeToLoginAfterAcceptedPassword() {
        loginEmail = passwordResetEmail
        infoMessage = "Your password was updated. Sign in with your new password to continue."
        route = .login
    }

    private func clearPasswordResetSecrets() {
        loginPassword = ""
        passwordResetCode = ""
        passwordResetNewPassword = ""
        passwordResetConfirmPassword = ""
    }

    private func handle(error: Error) {
        if error is CancellationError { return }
        if let paybackError = error as? PayBackError {
#if DEBUG
            print("[AuthCoordinator] PayBackError: \(paybackError)")
#endif
            errorMessage = paybackError.errorDescription
        } else {
#if DEBUG
            print("[AuthCoordinator] Unknown error: \(error.localizedDescription)")
#endif
            errorMessage = error.localizedDescription
        }
    }

    private static func defaultDisplayName(for email: String, suggested: String?) -> String {
        if let suggested, !suggested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return suggested
        }
        let username = email.split(separator: "@").first ?? Substring(email)
        return username
            .split(separator: ".")
            .map { $0.capitalized }
            .joined(separator: " ")
            .capitalized
    }
}
