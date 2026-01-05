import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var store: AppStore
    @State private var showLogoutConfirmation = false
    @State private var showSettings = false
    @State private var showImportExport = false
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 32) {
                    // Profile header with avatar and user info
                    profileHeader
                    
                    // Account information section
                    accountInfoSection
                    
                    // Data management section
                    dataManagementSection
                    
                    // Logout button
                    logoutButton
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 32)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Profile")
                            .font(.system(size: AppMetrics.headerTitleFontSize, weight: .bold))
                            .foregroundStyle(AppTheme.brand)
                        
                        Spacer()
                        
                        // Settings button
                        Button(action: {
                            showSettings = true
                        }) {
                            Image(systemName: "gearshape.fill")
                                .font(.headline)
                                .foregroundStyle(AppTheme.brand)
                                .frame(width: AppMetrics.smallIconButtonSize, height: AppMetrics.smallIconButtonSize)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                    }
                    .padding(.horizontal)
                    .padding(.top, AppMetrics.headerTopPadding)
                    .padding(.bottom, AppMetrics.headerBottomPadding)
                }
                .background(AppTheme.background)
            }
        }
        .alert("Log Out", isPresented: $showLogoutConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Log Out", role: .destructive) {
                handleLogout()
            }
        } message: {
            Text("Are you sure you want to log out?")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showImportExport) {
            ImportExportView()
                .environmentObject(store)
        }
    }
    
    // MARK: - Profile Header
    
    private var profileHeader: some View {
        VStack(spacing: 16) {
            // Avatar
            AvatarView(name: store.currentUser.name, size: 100)
            
            // User name
            Text(store.currentUser.name)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
    
    // MARK: - Account Info Section
    
    private var accountInfoSection: some View {
        VStack(spacing: 16) {
            Text("Account Information")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                // Display name row
                InfoRow(
                    icon: "person.fill",
                    label: "Name",
                    value: store.currentUser.name
                )
                
                // Email or phone row
                if let account = store.session?.account {
                    InfoRow(
                        icon: "envelope.fill",
                        label: "Email",
                        value: account.email
                    )
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppTheme.card)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
            )
        }
    }
    
    // MARK: - Data Management Section
    
    private var dataManagementSection: some View {
        VStack(spacing: 16) {
            Text("Data Management")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(action: {
                showImportExport = true
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down.square")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.brand)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(AppTheme.brand.opacity(0.1))
                        )
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import & Export Data")
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(.primary)
                        
                        Text("Backup or transfer your expenses")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(AppTheme.card)
                        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                )
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Logout Button
    
    private var logoutButton: some View {
        Button(action: {
            showLogoutConfirmation = true
        }) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 18, weight: .semibold))
                
                Text("Log Out")
                    .font(.system(.body, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.red)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Helper Methods
    
    private func handleLogout() {
        store.signOut()
    }
}

// MARK: - Info Row Component

private struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.brand)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(AppTheme.brand.opacity(0.1))
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                
                Text(value)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(.primary)
            }
            
            Spacer()
        }
    }
}
