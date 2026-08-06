import SwiftUI
import UIKit

struct CodeVerificationView: View {
    @Binding private var codeInput: String
    @FocusState private var isInputFocused: Bool

    let email: String
    let isBusy: Bool
    let errorMessage: String?
    let infoMessage: String?
    let title: String
    let prompt: String
    let onSubmit: (String) -> Void
    let onBack: () -> Void
    let onResend: (() -> Void)?

    private let codeLength: Int = 6

    init(
        code: Binding<String>,
        email: String,
        isBusy: Bool,
        errorMessage: String?,
        infoMessage: String? = nil,
        title: String = "Verify your email",
        prompt: String = "We sent a 6-digit code to",
        onSubmit: @escaping (String) -> Void,
        onBack: @escaping () -> Void,
        onResend: (() -> Void)? = nil
    ) {
        _codeInput = code
        self.email = email
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.infoMessage = infoMessage
        self.title = title
        self.prompt = prompt
        self.onSubmit = onSubmit
        self.onBack = onBack
        self.onResend = onResend
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
                Text(title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 6) {
                    Text(prompt)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(email)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Verification code")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))

                    TextField("123456", text: $codeInput)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($isInputFocused)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(.white.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(.white.opacity(isInputFocused ? 0.7 : 0.2), lineWidth: 1.5)
                        )
                        .onChange(of: codeInput) { oldValue, newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered.count > codeLength {
                                codeInput = String(filtered.prefix(codeLength))
                            } else if filtered != newValue {
                                codeInput = filtered
                            }
                            // Auto-submit when code is complete
                            if codeInput.count == codeLength {
                                submit()
                            }
                        }
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

                if let infoMessage, !infoMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(infoMessage)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(spacing: 12) {
                Button(action: submit) {
                    HStack {
                        if isBusy {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Text("Verify")
                                .font(.system(.headline, design: .rounded))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isContinueEnabled ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                }
                .disabled(!isContinueEnabled || isBusy)

                if let onResend {
                    Button(action: onResend) {
                        Text("Resend code")
                            .font(.system(.callout, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .underline()
                    }
                    .disabled(isBusy)
                }
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
        .onAppear {
            isInputFocused = true
        }
        .onTapGesture {
            isInputFocused = false
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isInputFocused = false
                }
            }
        }
    }

    private var isContinueEnabled: Bool {
        codeInput.count == codeLength
    }

    private func submit() {
        guard isContinueEnabled else { return }
        onSubmit(codeInput)
    }
}

struct CodeVerificationView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            CodeVerificationView(
                code: .constant(""),
                email: "user@example.com",
                isBusy: false,
                errorMessage: nil,
                onSubmit: { _ in },
                onBack: {},
                onResend: nil
            )
        }
    }
}

struct PasswordResetNewPasswordView: View {
    private enum Field {
        case password
        case confirmation
    }

    @Binding var password: String
    @Binding var confirmation: String
    @State private var showsPassword = false
    @State private var showsConfirmation = false
    @FocusState private var focusedField: Field?

    let email: String
    let isBusy: Bool
    let errorMessage: String?
    let onSubmit: (String) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isBusy)

            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a new password")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Update the password for \(email).")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
                passwordField(
                    title: "New password",
                    text: $password,
                    isVisible: $showsPassword,
                    field: .password,
                    contentType: .newPassword,
                    submitLabel: .next
                ) {
                    focusedField = .confirmation
                }

                passwordField(
                    title: "Confirm password",
                    text: $confirmation,
                    isVisible: $showsConfirmation,
                    field: .confirmation,
                    contentType: .password,
                    submitLabel: .done,
                    onSubmit: submit
                )

                if hasMismatch {
                    messageRow(text: "Passwords do not match")
                }

                if let errorMessage, !errorMessage.isEmpty {
                    messageRow(text: errorMessage)
                }
            }

            Button(action: submit) {
                HStack {
                    if isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Text("Update password")
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

            Spacer()
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.65))
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .onAppear { focusedField = .password }
        .onTapGesture { focusedField = nil }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    private var hasMismatch: Bool {
        !confirmation.isEmpty && password != confirmation
    }

    private var isFormValid: Bool {
        password.count >= 8 && password == confirmation
    }

    private func submit() {
        guard isFormValid else { return }
        onSubmit(password)
    }

    private func messageRow(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func passwordField(
        title: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        field: Field,
        contentType: UITextContentType,
        submitLabel: SubmitLabel,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            HStack {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.white.opacity(0.75))

                Group {
                    if isVisible.wrappedValue {
                        TextField(title, text: text)
                    } else {
                        SecureField(title, text: text)
                    }
                }
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textContentType(contentType)
                .foregroundStyle(.white)
                .submitLabel(submitLabel)
                .focused($focusedField, equals: field)
                .onSubmit(onSubmit)

                Button {
                    isVisible.wrappedValue.toggle()
                    focusedField = field
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.white.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(focusedField == field ? 0.7 : 0.2), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}
