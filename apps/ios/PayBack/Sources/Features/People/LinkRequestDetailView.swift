import SwiftUI

struct LinkRequestDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    
    let request: LinkRequest
    
    @State private var expensePreview: ExpensePreview?
    @State private var isLoading = true
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var showReAcceptConfirmation = false
    @State private var successScale: CGFloat = 0.5
    @State private var successOpacity: Double = 0
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header with requester info
                    requesterInfoSection
                    
                    // Name confirmation prompt
                    nameConfirmationSection
                    
                    // Expense preview
                    if isLoading {
                        ProgressView("Loading expense history...")
                            .padding()
                    } else if let preview = expensePreview {
                        expensePreviewSection(preview: preview)
                    }
                    
                    // Error message
                    if let error = errorMessage {
                        errorSection(message: error)
                    }
                    
                    // Success message
                    if showSuccess {
                        successSection
                    }
                    
                    // Action buttons (only show for pending requests)
                    if request.status == .pending && !showSuccess {
                        actionButtons
                    }
                    
                    // Status badge for non-pending requests
                    if request.status != .pending {
                        statusBadge
                    }
                }
                .padding()
            }
            .navigationTitle("Link Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadExpensePreview()
            }
            .alert("Confirm Re-Acceptance", isPresented: $showReAcceptConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Accept Anyway", role: .destructive) {
                    Task {
                        await acceptRequest()
                    }
                }
            } message: {
                Text("Are you sure you want to accept this request you previously rejected?")
            }
        }
    }
    
    // MARK: - Requester Info Section
    
    @ViewBuilder
    private var requesterInfoSection: some View {
        VStack(spacing: 16) {
            // Avatar
            ZStack {
                Circle()
                    .fill(AppTheme.brand.opacity(0.2))
                    .frame(width: 80, height: 80)
                
                Text(request.requesterName.prefix(1).uppercased())
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)
            }
            
            VStack(spacing: 4) {
                Text(request.requesterName)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(request.requesterEmail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
    private var nameConfirmationSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "person.fill.questionmark")
                    .font(.title2)
                    .foregroundStyle(AppTheme.brand)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Are you \(request.targetMemberName)?")
                        .font(.headline)
                    
                    Text("This person has been tracking expenses with someone named \"\(request.targetMemberName)\"")
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
            
            Text("Link Request Accepted!")
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
    
    // MARK: - Status Badge
    
    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.title3)
            Text(statusText)
                .font(.headline)
        }
        .foregroundStyle(statusColor)
        .padding()
        .frame(maxWidth: .infinity)
        .background(statusColor.opacity(0.15))
        .cornerRadius(12)
    }
    
    private var statusIcon: String {
        switch request.status {
        case .accepted:
            return "checkmark.circle.fill"
        case .declined, .rejected:
            return "xmark.circle.fill"
        case .expired:
            return "clock.badge.exclamationmark"
        case .pending:
            return "clock"
        }
    }
    
    private var statusText: String {
        switch request.status {
        case .accepted:
            return "Already Accepted"
        case .declined, .rejected:
            return "Previously Declined"
        case .expired:
            return "Request Expired"
        case .pending:
            return "Pending"
        }
    }
    
    private var statusColor: Color {
        switch request.status {
        case .accepted:
            return .green
        case .declined, .rejected:
            return .red
        case .expired:
            return .orange
        case .pending:
            return .blue
        }
    }
    
    // MARK: - Action Buttons
    
    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                // Trigger selection haptic
                Haptics.selection()
                
                // Check if this was previously rejected
                if store.wasPreviouslyRejected(request) {
                    showReAcceptConfirmation = true
                } else {
                    Task {
                        await acceptRequest()
                    }
                }
            }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Accept")
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
                
                Task {
                    await declineRequest()
                }
            }) {
                HStack {
                    if isProcessing {
                        ProgressView()
                    } else {
                        Image(systemName: "xmark.circle")
                        Text("Decline")
                            .fontWeight(.semibold)
                    }
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
    
    private func loadExpensePreview() async {
        isLoading = true
        errorMessage = nil
        
        // Generate expense preview for the target member
        await MainActor.run {
            expensePreview = store.generateExpensePreview(forMemberId: request.targetMemberId)
            isLoading = false
        }
    }
    
    private func acceptRequest() async {
        isProcessing = true
        errorMessage = nil
        
        do {
            try await store.acceptLinkRequest(request)
            
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
    
    private func declineRequest() async {
        isProcessing = true
        errorMessage = nil
        
        do {
            try await store.declineLinkRequest(request)
            
            await MainActor.run {
                isProcessing = false
                
                // Trigger selection haptic
                Haptics.selection()
                
                dismiss()
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
}
