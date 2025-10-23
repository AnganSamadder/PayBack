import SwiftUI

struct SignupDetailsView: View {
    @State private var nameInput: String = ""
    @FocusState private var isNameFocused: Bool

    let phoneNumber: String
    let isBusy: Bool
    let errorMessage: String?
    let onSubmit: (String) -> Void
    let onBack: () -> Void

    init(
        phoneNumber: String,
        isBusy: Bool,
        errorMessage: String?,
        onSubmit: @escaping (String) -> Void,
        onBack: @escaping () -> Void
    ) {
        self.phoneNumber = phoneNumber
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
                Text("Set up your profile")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("You're verified! Add your name so friends recognise you.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Phone number")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(phoneNumber)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Display name")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))

                    TextField("Alex Johnson", text: $nameInput)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(false)
                        .keyboardType(.default)
                        .foregroundStyle(.white)
                        .font(.system(.headline, design: .rounded))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(.white.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(.white.opacity(isNameFocused ? 0.7 : 0.2), lineWidth: 1.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit(submit)
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
                            Text("Finish")
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

                Text("This name helps people know they’re sharing expenses with the right you.")
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
        .onAppear {
            isNameFocused = true
        }
    }

    private var isFormValid: Bool {
        !nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard isFormValid else { return }
        onSubmit(nameInput)
    }
}

struct SignupDetailsView_Previews: PreviewProvider {
    static var previews: some View {
        SignupDetailsView(
            phoneNumber: "+1 310 555 0148",
            isBusy: false,
            errorMessage: nil,
            onSubmit: { _ in },
            onBack: {}
        )
    }
}
