import Foundation

@MainActor
final class AuthCoordinator: ObservableObject {
    enum Route: Equatable {
        case login
        case signup(presetEmail: String)
        case authenticated(UserSession)
    }

    @Published private(set) var route: Route = .login
    @Published private(set) var isBusy: Bool = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private let accountService: AccountService
    private let emailAuthService: EmailAuthService

    init(
        accountService: AccountService = AccountServiceProvider.makeAccountService(),
        emailAuthService: EmailAuthService = EmailAuthServiceProvider.makeService()
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
            } catch {
                self.handle(error: error)
            }
        }
    }

    func signup(emailInput: String, displayName: String, password: String) async {
        await runBusyTask {
            do {
                let normalizedEmail = try self.accountService.normalizedEmail(from: emailInput)
                let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await self.emailAuthService.signUp(email: normalizedEmail, password: password, displayName: trimmedName)
                let account = try await self.accountService.createAccount(email: normalizedEmail, displayName: trimmedName)
                self.route = .authenticated(UserSession(account: account))
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

    private func runBusyTask(allowsConcurrent: Bool = false, _ operation: @escaping () async -> Void) async {
        if isBusy && !allowsConcurrent { return }
        if !allowsConcurrent {
            isBusy = true
        }
        errorMessage = nil
        infoMessage = nil
        await operation()
        if !allowsConcurrent {
            isBusy = false
        }
    }

    private func handle(error: Error) {
        if let accountError = error as? AccountServiceError {
#if DEBUG
            print("[AuthCoordinator] AccountServiceError: \(accountError)")
#endif
            errorMessage = accountError.errorDescription
        } else if let emailError = error as? EmailAuthServiceError {
#if DEBUG
            print("[AuthCoordinator] EmailAuthServiceError: \(emailError)")
#endif
            errorMessage = emailError.errorDescription
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
