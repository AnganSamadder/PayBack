import Foundation

@MainActor
final class AuthCoordinator: ObservableObject {
    enum Route: Equatable {
        case login
        case signup(presetEmail: String)
        case verification(email: String, displayName: String)
        case authenticated(UserSession)
    }

    @Published private(set) var route: Route = .login
    @Published private(set) var isBusy: Bool = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// Email that needs confirmation - when set, shows the "Resend confirmation" option
    @Published var unconfirmedEmail: String?

    private let accountService: AccountService
    private let emailAuthService: EmailAuthService
    /// Stores the display name during signup flow for use after verification
    private var pendingDisplayName: String = ""

    init(
        accountService: AccountService = Dependencies.current.accountService,
        emailAuthService: EmailAuthService = Dependencies.current.emailAuthService
    ) {
        self.accountService = accountService
        self.emailAuthService = emailAuthService
    }

    func start() {
        if case .authenticated = route {
            return
        }
        route = .login
    }

    func signOut() {
        try? emailAuthService.signOut()
        route = .login
    }

    func openSignup(with emailInput: String) {
        let normalized = (try? accountService.normalizedEmail(from: emailInput)) ?? emailInput
        route = .signup(presetEmail: normalized)
    }

    func login(emailInput: String, password: String) async {
        await runBusyTask {
            do {
                let normalizedEmail = try self.accountService.normalizedEmail(from: emailInput)
                let result = try await self.emailAuthService.signIn(email: normalizedEmail, password: password)

                if let account = try await self.accountService.lookupAccount(byEmail: normalizedEmail) {
                    self.route = .authenticated(UserSession(account: account))
                } else {
                    let fallbackName = Self.defaultDisplayName(for: normalizedEmail, suggested: result.displayName)
                    let account = try await self.accountService.createAccount(email: normalizedEmail, displayName: fallbackName)
                    self.route = .authenticated(UserSession(account: account))
                }
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
        await runBusyTask {
            do {
                let normalizedEmail = try self.accountService.normalizedEmail(from: emailInput)
                let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedLastName = lastName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = [trimmedFirstName, trimmedLastName].compactMap { $0 }.joined(separator: " ")
                
                let result = try await self.emailAuthService.signUp(email: normalizedEmail, password: password, firstName: trimmedFirstName, lastName: trimmedLastName)
                
                switch result {
                case .needsVerification(let email):
                    // Store display name for later and show verification screen
                    self.pendingDisplayName = displayName
                    self.route = .verification(email: email, displayName: displayName)
                    
                case .complete(_):
                    // No verification needed - create account and complete
                    let account = try await self.accountService.createAccount(email: normalizedEmail, displayName: displayName)
                    self.route = .authenticated(UserSession(account: account))
                }
            } catch {
                self.handle(error: error)
            }
        }
    }
    
    func verifyCode(_ code: String) async {
        await runBusyTask {
            do {
                let authResult = try await self.emailAuthService.verifyCode(code: code)
                
                // Authenticate Convex client with the new Clerk session
                await Dependencies.authenticateConvex()
                
                // Create account in Convex now that we have an authenticated session
                let displayName = self.pendingDisplayName.isEmpty ? authResult.displayName : self.pendingDisplayName
                let account = try await self.accountService.createAccount(email: authResult.email, displayName: displayName)
                
                // Start real-time sync
                Dependencies.syncManager?.startSync()
                
                self.route = .authenticated(UserSession(account: account))
            } catch {
                self.handle(error: error)
            }
        }
    }
    
    func resendVerificationCode() async {
        guard case .verification(let email, _) = route else { return }
        
        await runBusyTask(allowsConcurrent: true) {
            do {
                try await self.emailAuthService.resendConfirmationEmail(email: email)
                self.infoMessage = "A new code has been sent to your email."
            } catch {
                self.handle(error: error)
            }
        }
    }

    func sendPasswordReset(emailInput: String) async {
        await runBusyTask(allowsConcurrent: true) {
            do {
                let normalizedEmail = try self.accountService.normalizedEmail(from: emailInput)
                try await self.emailAuthService.sendPasswordReset(email: normalizedEmail)
                self.infoMessage = "We sent a password reset email to \(normalizedEmail). Check your inbox."
            } catch {
                self.handle(error: error)
            }
        }
    }

    func resendConfirmationEmail() async {
        guard let email = unconfirmedEmail else { return }
        
        await runBusyTask(allowsConcurrent: true) {
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

    private func runBusyTask(allowsConcurrent: Bool = false, _ operation: @escaping () async -> Void) async {
        if isBusy && !allowsConcurrent { return }
        if !allowsConcurrent {
            isBusy = true
        }
        errorMessage = nil
        infoMessage = nil
        unconfirmedEmail = nil
        await operation()
        if !allowsConcurrent {
            isBusy = false
        }
    }

    private func handle(error: Error) {
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
