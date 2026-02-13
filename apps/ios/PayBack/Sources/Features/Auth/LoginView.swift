import SwiftUI
import UIKit

struct LoginView: View {
    private enum Field {
        case email
        case password
    }

    @State private var emailInput: String = ""
    @State private var passwordInput: String = ""
    @State private var isPasswordVisible: Bool = false
    @FocusState private var focusedField: Field?

    let isBusy: Bool
    let errorMessage: String?
    let infoMessage: String?
    let showResendConfirmation: Bool
    let onLogin: (String, String) -> Void
    let onForgotPassword: (String) -> Void
    let onPrefillSignup: (String) -> Void
    let onResendConfirmation: () -> Void

    init(
        isBusy: Bool,
        errorMessage: String?,
        infoMessage: String?,
        showResendConfirmation: Bool = false,
        onLogin: @escaping (String, String) -> Void,
        onForgotPassword: @escaping (String) -> Void,
        onPrefillSignup: @escaping (String) -> Void,
        onResendConfirmation: @escaping () -> Void = {}
    ) {
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.infoMessage = infoMessage
        self.showResendConfirmation = showResendConfirmation
        self.onLogin = onLogin
        self.onForgotPassword = onForgotPassword
        self.onPrefillSignup = onPrefillSignup
        self.onResendConfirmation = onResendConfirmation
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .center, spacing: 12) {
                Text("Log In")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 32)

            Spacer()

            VStack(spacing: 20) {
                authTextField(
                    title: "Email",
                    systemImage: "envelope.fill",
                    placeholder: "you@example.com",
                    text: $emailInput,
                    isFocused: focusedField == .email,
                    keyboardType: .emailAddress,
                    textContentType: .username,
                    submitLabel: .next
                ) {
                    focusedField = .password
                }
                .focused($focusedField, equals: .email)

                passwordField

                if let infoMessage, !infoMessage.isEmpty {
                    messageRow(
                        systemName: "checkmark.circle.fill",
                        color: .green,
                        text: infoMessage
                    )
                }

                if let errorMessage, !errorMessage.isEmpty {
                    messageRow(
                        systemName: "exclamationmark.triangle.fill",
                        color: .yellow,
                        text: errorMessage
                    )

                    // Show resend confirmation button when email is unconfirmed
                    if showResendConfirmation {
                        Button(action: onResendConfirmation) {
                            HStack(spacing: 8) {
                                Image(systemName: "envelope.arrow.triangle.branch.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Resend confirmation email")
                                    .font(.system(.callout, design: .rounded, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: [Color.orange.opacity(0.8), Color.yellow.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .orange.opacity(0.3), radius: 6, y: 2)
                        }
                        .disabled(isBusy)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: login) {
                    HStack {
                        if isBusy {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Text("Sign in")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isFormValid ? Color.white : Color.white.opacity(0.3))
                    .foregroundStyle(isFormValid ? AppTheme.brand : .white.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: isFormValid ? .white.opacity(0.3) : .clear, radius: 8, y: 4)
                }
                .disabled(!isFormValid || isBusy)

                Button {
                    onPrefillSignup(emailInput)
                } label: {
                    HStack {
                        Image(systemName: "person.badge.plus.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Create account")
                            .font(.system(.callout, design: .rounded, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.15))
                    .foregroundStyle(.white.opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
                }
                .disabled(isBusy)

                Button {
                    onForgotPassword(emailInput)
                } label: {
                    Text("Forgot password?")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(.white.opacity(canAttemptReset ? 0.85 : 0.4))
                        .padding(.vertical, 8)
                }
                .disabled(!canAttemptReset || isBusy)
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.65))
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .onTapGesture {
            focusedField = nil
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
            }
        }
        .onAppear {
            focusedField = .email
        }
    }

    private var isFormValid: Bool {
        let normalized = EmailValidator.normalized(emailInput)
        return EmailValidator.isValid(normalized) && passwordInput.count >= 6
    }

    private var canAttemptReset: Bool {
        let normalized = EmailValidator.normalized(emailInput)
        return EmailValidator.isValid(normalized)
    }

    private func login() {
        guard isFormValid else { return }
        onLogin(emailInput, passwordInput)
    }

    @ViewBuilder
    private func authTextField(
        title: String,
        systemImage: String,
        placeholder: String,
        text: Binding<String>,
        isFocused: Bool,
        keyboardType: UIKeyboardType,
        textContentType: UITextContentType?,
        submitLabel: SubmitLabel,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(.white.opacity(0.75))
                    .font(.system(size: 18, weight: .semibold))

                TextField(placeholder, text: text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .textContentType(textContentType)
                    .disableAutocorrection(true)
                    .foregroundStyle(.white)
                    .font(.system(.headline, design: .rounded))
                    .submitLabel(submitLabel)
                    .onSubmit(onSubmit)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.white.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(isFocused ? 0.7 : 0.2), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            HStack {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.white.opacity(0.75))
                    .font(.system(size: 18, weight: .semibold))

                Group {
                    if isPasswordVisible {
                        TextField("Your password", text: $passwordInput)
                    } else {
                        SecureField("Your password", text: $passwordInput)
                    }
                }
                .textInputAutocapitalization(.never)
                .textContentType(.password)
                .disableAutocorrection(true)
                .foregroundStyle(.white)
                .font(.system(.headline, design: .rounded))
                .submitLabel(.go)
                .focused($focusedField, equals: .password)
                .onSubmit(login)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPasswordVisible.toggle()
                    }
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.white.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(focusedField == .password ? 0.7 : 0.2), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    private func messageRow(systemName: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .foregroundStyle(color)
            Text(text)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            LoginView(
                isBusy: false,
                errorMessage: nil,
                infoMessage: nil,
                onLogin: { _, _ in },
                onForgotPassword: { _ in },
                onPrefillSignup: { _ in }
            )
            .frame(maxWidth: 520)
        }
    }
}
