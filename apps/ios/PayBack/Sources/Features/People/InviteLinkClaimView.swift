import SwiftUI

struct InviteLinkClaimView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    
    let tokenId: UUID
    
    @State private var validation: InviteTokenValidation?
    @State private var isLoading = true
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var successScale: CGFloat = 0.5
    @State private var successOpacity: Double = 0
    
    private var needsAuthentication: Bool {
        store.session == nil
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                if needsAuthentication {
                    authenticationRequiredView
                } else if isLoading {
                    loadingView
                } else if let validation = validation {
                    ScrollView {
                        VStack(spacing: 24) {
                            if validation.isValid, let token = validation.token {
                                validTokenView(token: token, preview: validation.expensePreview)
                            } else {
                                errorView(message: validation.errorMessage ?? "Invalid invite link")
                            }
                            
                            // Error message
                            if let error = errorMessage {
                                errorSection(message: error)
                            }
                            
                            // Success message
                            if showSuccess {
                                successSection
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Claim Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                if !needsAuthentication {
                    await validateToken()
                }
            }
        }
    }
    
    // MARK: - Authentication Required View
    
    @ViewBuilder
    private var authenticationRequiredView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundStyle(AppTheme.brand)
            
            Text("Sign In Required")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("You need to sign in to claim this invite link")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: {
                // The user will need to sign in through the main app flow
                dismiss()
            }) {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Go Back to Sign In")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppTheme.brand)
                .foregroundStyle(.white)
                .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    // MARK: - Loading View
    
    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Validating invite link...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    // MARK: - Valid Token View
    
    @ViewBuilder
    private func validTokenView(token: InviteToken, preview: ExpensePreview?) -> some View {
        VStack(spacing: 24) {
            // Sender info section
            senderInfoSection(token: token)
            
            // Name confirmation prompt
            nameConfirmationSection(token: token)
            
            // Expense preview
            if let preview = preview {
                expensePreviewSection(preview: preview)
            }
            
            // Action buttons (only show if not processing or successful)
            if !showSuccess {
                actionButtons
            }
        }
    }
    
    // MARK: - Sender Info Section
    
    @ViewBuilder
    private func senderInfoSection(token: InviteToken) -> some View {
        VStack(spacing: 16) {
            // Avatar
            ZStack {
                Circle()
                    .fill(AppTheme.brand.opacity(0.2))
                    .frame(width: 80, height: 80)
                
                Text(token.creatorEmail.prefix(1).uppercased())
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)
            }
            
            VStack(spacing: 4) {
                Text("Invite from")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Text(token.creatorEmail)
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
    
    // MARK: - Name Confirmation Section
    
    @ViewBuilder
    private func nameConfirmationSection(token: InviteToken) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "person.fill.questionmark")
                    .font(.title2)
                    .foregroundStyle(AppTheme.brand)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Are you \(token.targetMemberName)?")
                        .font(.headline)
                    
                    Text("This person has been tracking expenses with someone named \"\(token.targetMemberName)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            .padding()
            .background(AppTheme.brand.opacity(0.1))
            .cornerRadius(12)
        }
    }
    
    // MARK: - Expense Preview Section
    
    @ViewBuilder
    private func expensePreviewSection(preview: ExpensePreview) -> some View {
        VStack(spacing: 16) {
            // Summary header
            VStack(spacing: 8) {
                Text("Expense History")
                    .font(.headline)
                
                Text("Here's what will be linked to your account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Balance card
            balanceCard(balance: preview.totalBalance)
            
            // Expense counts
            HStack(spacing: 16) {
                expenseCountCard(
                    count: preview.personalExpenses.count,
                    label: "Personal",
                    icon: "person.2"
                )
                
                expenseCountCard(
                    count: preview.groupExpenses.count,
                    label: "Group",
                    icon: "person.3"
                )
            }
            
            // Groups involved
            if !preview.groupNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Groups")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    ForEach(preview.groupNames, id: \.self) { groupName in
                        HStack {
                            Image(systemName: "person.3.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(groupName)
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
    }
    
    @ViewBuilder
    private func balanceCard(balance: Double) -> some View {
        VStack(spacing: 8) {
            Text("Total Balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text(formatBalance(balance))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(balanceColor(balance))
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
    
    @ViewBuilder
    private func expenseCountCard(count: Int, label: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(AppTheme.brand)
            
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    // MARK: - Error View
    
    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            
            Text("Invalid Invite Link")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if let errorSuggestion = getRecoverySuggestion(for: message) {
                Text(errorSuggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
    
    // MARK: - Error Section
    
    @ViewBuilder
    private func errorSection(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - Success Section
    
    @ViewBuilder
    private var successSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
                .scaleEffect(successScale)
                .opacity(successOpacity)
            
            Text("Invite Claimed!")
                .font(.title3)
                .fontWeight(.semibold)
                .opacity(successOpacity)
            
            Text("Your account has been linked successfully")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .opacity(successOpacity)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
        .onAppear {
            withAnimation(AppAnimation.springy) {
                successScale = 1.0
                successOpacity = 1.0
            }
        }
    }
    
    // MARK: - Action Buttons
    
    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                // Trigger selection haptic
                Haptics.selection()
                
                Task {
                    await claimToken()
                }
            }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Accept & Link Account")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppTheme.brand)
                .foregroundStyle(.white)
                .cornerRadius(12)
            }
            .disabled(isProcessing)
            .scaleEffect(isProcessing ? 0.98 : 1.0)
            .animation(AppAnimation.quick, value: isProcessing)
            
            Button(action: {
                // Trigger selection haptic
                Haptics.selection()
                
                dismiss()
            }) {
                HStack {
                    Image(systemName: "xmark.circle")
                    Text("Decline")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray5))
                .foregroundStyle(.primary)
                .cornerRadius(12)
            }
            .disabled(isProcessing)
            .scaleEffect(isProcessing ? 0.98 : 1.0)
            .animation(AppAnimation.quick, value: isProcessing)
        }
    }
    
    // MARK: - Helper Methods
    
    private func validateToken() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let result = try await store.validateInviteToken(tokenId)
            
            await MainActor.run {
                validation = result
                isLoading = false
            }
        } catch {
            await MainActor.run {
                validation = InviteTokenValidation(
                    isValid: false,
                    token: nil,
                    expensePreview: nil,
                    errorMessage: error.localizedDescription
                )
                isLoading = false
            }
        }
    }
    
    private func claimToken() async {
        isProcessing = true
        errorMessage = nil
        
        do {
            try await store.claimInviteToken(tokenId)
            
            await MainActor.run {
                isProcessing = false
                
                // Trigger success haptic
                Haptics.notify(.success)
                
                withAnimation(AppAnimation.springy) {
                    showSuccess = true
                }
                
                // Dismiss after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dismiss()
                }
            }
        } catch {
            await MainActor.run {
                isProcessing = false
                errorMessage = error.localizedDescription
                
                // Trigger error haptic
                Haptics.notify(.error)
            }
        }
    }
    
    private func formatBalance(_ balance: Double) -> String {
        if abs(balance) < 0.01 {
            return "$0.00"
        }
        
        let currencyCode = Locale.current.currency?.identifier ?? "USD"
        let formatted = abs(balance).formatted(.currency(code: currencyCode))
        
        if balance >= 0 {
            return "You're owed \(formatted)"
        } else {
            return "You owe \(formatted)"
        }
    }
    
    private func balanceColor(_ balance: Double) -> Color {
        if balance > 0.01 {
            return .green
        } else if balance < -0.01 {
            return .red
        } else {
            return .secondary
        }
    }
    
    private func getRecoverySuggestion(for errorMessage: String) -> String? {
        if errorMessage.contains("expired") {
            return "Ask the sender to generate a new invite link."
        } else if errorMessage.contains("claimed") {
            return "Contact the person who sent you this link."
        } else if errorMessage.contains("invalid") {
            return "Make sure you're using the complete link."
        }
        return nil
    }
}
