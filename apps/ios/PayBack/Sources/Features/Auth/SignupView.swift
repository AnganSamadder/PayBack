import SwiftUI
import UIKit

struct SignupView: View {
    private enum Field {
        case email
        case firstName
        case lastName
        case password
        case confirm
    }

    @Binding private var emailInput: String
    @Binding private var firstNameInput: String
    @Binding private var lastNameInput: String
    @Binding private var passwordInput: String
    @Binding private var confirmPasswordInput: String
    @State private var isPasswordVisible: Bool = false
    @State private var isConfirmVisible: Bool = false
    @FocusState private var focusedField: Field?

    private var passwordMismatch: Bool {
        !confirmPasswordInput.isEmpty && passwordInput != confirmPasswordInput
    }

    let isBusy: Bool
    let errorMessage: String?
    let onSubmit: (String, String, String?, String) -> Void  // email, firstName, lastName, password
    let onBack: () -> Void

    init(
        email: Binding<String>,
        firstName: Binding<String>,
        lastName: Binding<String>,
        password: Binding<String>,
        confirmPassword: Binding<String>,
        isBusy: Bool,
        errorMessage: String?,
        onSubmit: @escaping (String, String, String?, String) -> Void,
        onBack: @escaping () -> Void
    ) {
        _emailInput = email
        _firstNameInput = firstName
        _lastNameInput = lastName
        _passwordInput = password
        _confirmPasswordInput = confirmPassword
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.onSubmit = onSubmit
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 32) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.12))
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isBusy)

            VStack(alignment: .leading, spacing: 12) {
                Text("Create your account")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("We'll keep your expenses ready to sync as soon as you join.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
                AuthTextField(
                    title: "Email",
                    systemImage: "envelope.fill",
                    placeholder: "you@example.com",
                    text: $emailInput,
                    isFocused: focusedField == .email,
                    keyboardType: .emailAddress,
                    submitLabel: .next,
                    textContentType: .username,
                    autocapitalization: .never
                ) {
                    focusedField = .firstName
                }
                .focused($focusedField, equals: .email)

                AuthTextField(
                    title: "First name",
                    systemImage: "person.fill",
                    placeholder: "Alex",
                    text: $firstNameInput,
                    isFocused: focusedField == .firstName,
                    keyboardType: .default,
                    submitLabel: .next,
                    textContentType: .givenName,
                    autocapitalization: .words
                ) {
                    focusedField = .lastName
                }
                .focused($focusedField, equals: .firstName)

                AuthTextField(
                    title: "Last name",
                    systemImage: "person.fill",
                    placeholder: "Johnson",
                    text: $lastNameInput,
                    isFocused: focusedField == .lastName,
                    keyboardType: .default,
                    submitLabel: .next,
                    textContentType: .familyName,
                    autocapitalization: .words
                ) {
                    focusedField = .password
                }
                .focused($focusedField, equals: .lastName)

                passwordField(
                    title: "Password",
                    text: $passwordInput,
                    isVisible: $isPasswordVisible,
                    placeholder: "At least 8 characters",
                    field: .password,
                    onSubmit: { focusedField = .confirm }
                )

                passwordField(
                    title: "Confirm password",
                    text: $confirmPasswordInput,
                    isVisible: $isConfirmVisible,
                    placeholder: "Re-enter password",
                    field: .confirm,
                    onSubmit: submit
                )

                Text("Use the iPhone suggested strong password for the fastest sign up.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if passwordMismatch {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Passwords do not match")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            if let errorMessage, !errorMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            VStack(spacing: 12) {
                Button(action: submit) {
                    HStack {
                        if isBusy {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Text("Create account")
                                .font(.system(.headline, design: .rounded))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isFormValid ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                }
                .disabled(!isFormValid || isBusy)

                Text("By creating an account you agree to keep expense data accurate for the people you invite.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            Spacer()
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
            focusedField = firstNameInput.isEmpty ? .firstName : .password
        }
    }

    private var isFormValid: Bool {
        let normalizedEmail = EmailValidator.normalized(emailInput)
        let trimmedFirstName = firstNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordMatches = !passwordInput.isEmpty && passwordInput == confirmPasswordInput
        return EmailValidator.isValid(normalizedEmail) && !trimmedFirstName.isEmpty && passwordInput.count >= 8 && passwordMatches
    }

    private func submit() {
        guard isFormValid else { return }
        let trimmedFirstName = firstNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLastName = lastNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastName: String? = trimmedLastName.isEmpty ? nil : trimmedLastName
        onSubmit(emailInput, trimmedFirstName, lastName, passwordInput)
    }

    @ViewBuilder
    private func passwordField(
        title: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        placeholder: String,
        field: Field,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            HStack {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.white.opacity(0.75))
                    .font(.system(size: 18, weight: .semibold))

                Group {
                    if isVisible.wrappedValue {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textContentType(field == .password ? .newPassword : .password)
                .foregroundStyle(.white)
                .font(.system(.headline, design: .rounded))
                .submitLabel(field == .confirm ? .join : .next)
                .privacySensitive()
                .focused($focusedField, equals: field)
                .onSubmit(onSubmit)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isVisible.wrappedValue.toggle()
                    }
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.white.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(self.focusedField == field ? 0.7 : 0.2), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

private struct AuthTextField: View {
    let title: String
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    let isFocused: Bool
    let keyboardType: UIKeyboardType
    let submitLabel: SubmitLabel
    let textContentType: UITextContentType?
    let autocapitalization: TextInputAutocapitalization
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(.white.opacity(0.75))
                    .font(.system(size: 18, weight: .semibold))

                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(autocapitalization)
                    .disableAutocorrection(true)
                    .foregroundStyle(.white)
                    .font(.system(.headline, design: .rounded))
                    .submitLabel(submitLabel)
                    .onSubmit(onSubmit)
                    .applyIf(textContentType != nil) { view in
                        view.textContentType(textContentType!)
                    }
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
}

private extension View {
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct SignupView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            SignupView(
                email: .constant("you@example.com"),
                firstName: .constant(""),
                lastName: .constant(""),
                password: .constant(""),
                confirmPassword: .constant(""),
                isBusy: false,
                errorMessage: "",
                onSubmit: { _, _, _, _ in },
                onBack: {}
            )
            .frame(maxWidth: 520)
        }
    }
}
