import SwiftUI

struct LinkRequestListView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: RequestTab = .pending
    @State private var selectedRequest: LinkRequest?
    @State private var showDetail = false
    
    enum RequestTab: String, CaseIterable {
        case pending = "Pending"
        case previous = "Previous"
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab selector
                Picker("Request Type", selection: $selectedTab) {
                    ForEach(RequestTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                .onChange(of: selectedTab) { _, _ in
                    Haptics.selection()
                }
                
                // Content based on selected tab
                if selectedTab == .pending {
                    pendingRequestsList
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    previousRequestsList
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            .animation(AppAnimation.quick, value: selectedTab)
            .navigationTitle("Link Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showDetail) {
                if let request = selectedRequest {
                    LinkRequestDetailView(request: request)
                        .environmentObject(store)
                }
            }
            .task {
                // Fetch requests when view appears
                try? await store.fetchLinkRequests()
                try? await store.fetchPreviousRequests()
            }
        }
    }
    
    @ViewBuilder
    private var pendingRequestsList: some View {
        let pendingRequests = store.incomingLinkRequests.filter { $0.status == .pending }
        
        if pendingRequests.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "link.circle")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    
                    Text("No Pending Requests")
                        .font(.title3)
                        .fontWeight(.semibold)
                    
                    Text("When someone sends you a link request, it will appear here")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            }
        } else {
            List {
                ForEach(pendingRequests) { request in
                    LinkRequestRow(request: request)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.selection()
                            selectedRequest = request
                            showDetail = true
                        }
                }
            }
            .listStyle(.plain)
        }
    }
    
    @ViewBuilder
    private var previousRequestsList: some View {
        let previousRequests = store.previousLinkRequests
        
        if previousRequests.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    
                    Text("No Previous Requests")
                        .font(.title3)
                        .fontWeight(.semibold)
                    
                    Text("Accepted and declined requests will appear here")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            }
        } else {
            List {
                ForEach(previousRequests) { request in
                    LinkRequestRow(request: request, showStatus: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.selection()
                            selectedRequest = request
                            showDetail = true
                        }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Link Request Row

private struct LinkRequestRow: View {
    let request: LinkRequest
    var showStatus: Bool = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(AppTheme.brand.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                Text(request.requesterName.prefix(1).uppercased())
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(request.requesterName)
                    .font(.headline)
                
                Text(request.requesterEmail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Text("Wants to link with: \(request.targetMemberName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if showStatus {
                    statusBadge
                }
            }
            
            Spacer()
            
            if !showStatus {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .font(.caption2)
            Text(statusText)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.15))
        .cornerRadius(8)
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
            return "Accepted"
        case .declined, .rejected:
            return "Declined"
        case .expired:
            return "Expired"
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
}
