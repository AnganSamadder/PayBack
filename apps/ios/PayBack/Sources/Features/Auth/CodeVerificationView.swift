import SwiftUI

struct CodeVerificationView: View {
    @State private var codeInput: String = ""
    @FocusState private var isInputFocused: Bool

    let phoneNumber: String
    let isBusy: Bool
    let errorMessage: String?
    let onSubmit: (String) -> Void
    let onBack: () -> Void
    let onResend: (() -> Void)?

    private let codeLength: Int = 6

    init(
        phoneNumber: String,
        isBusy: Bool,
        errorMessage: String?,
        onSubmit: @escaping (String) -> Void,
        onBack: @escaping () -> Void,
        onResend: (() -> Void)? = nil
    ) {
        self.phoneNumber = phoneNumber
        self.isBusy = isBusy
        self.errorMessage = errorMessage
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
                Text("Enter the code")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 6) {
                    Text("We texted a 6-digit code to")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(phoneNumber)
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
        CodeVerificationView(
            phoneNumber: "+1 310 555 0148",
            isBusy: false,
            errorMessage: nil,
            onSubmit: { _ in },
            onBack: {},
            onResend: nil
        )
    }
}
