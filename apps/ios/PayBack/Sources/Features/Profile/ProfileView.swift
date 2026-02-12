import SwiftUI
import PhotosUI

struct ProfileView: View {
    @EnvironmentObject var store: AppStore
    @Binding var path: [ProfileRoute]
    var rootResetToken: UUID = UUID()
    @State private var showLogoutConfirmation = false
    @State private var showSettings = false
    @State private var showImportExport = false
    @State private var profileColor: Color = .blue
    
    // Image Upload State
    @State private var photosSelection: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var capturedImage: UIImage?
    @State private var isUploading = false
    @State private var uploadError: String?
    @State private var showUploadError = false
    
    var body: some View {
        NavigationStack(path: $path) {
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
            .id(rootResetToken)
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
        .alert("Upload Failed", isPresented: $showUploadError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(uploadError ?? "An unknown error occurred.")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showImportExport) {
            ImportExportView()
                .environmentObject(store)
        }
        .fullScreenCover(isPresented: $showCamera) {
            ImagePicker(image: $capturedImage, sourceType: .camera)
                .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onChange(of: photosSelection) { _, newItem in
            Task {
                if let newItem, let data = try? await newItem.loadTransferable(type: Data.self) {
                    await uploadImage(data)
                }
            }
        }
        .onChange(of: capturedImage) { _, newImage in
            if let newImage, let data = newImage.jpegData(compressionQuality: 0.8) {
                Task {
                    await uploadImage(data)
                }
            }
        }
        .onChange(of: store.currentUser.profileColorHex) { _, newHex in
            if let newHex, let color = Color(hex: newHex), color != profileColor {
                profileColor = color
            }
        }
    }
    
    // MARK: - Profile Header
    
    private var profileHeader: some View {
        VStack(spacing: 16) {
            // Avatar
            AvatarView(
                name: store.currentUser.name,
                size: 100,
                imageUrl: store.currentUser.profileImageUrl,
                colorHex: store.currentUser.profileColorHex
            )
            .overlay(
                Group {
                    if isUploading {
                        ZStack {
                            Circle().fill(Color.black.opacity(0.4))
                            ProgressView()
                                .tint(.white)
                        }
                    }
                }
            )
            
            // Edit Profile Picture Menu
            Menu {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                
                PhotosPicker(selection: $photosSelection, matching: .images, photoLibrary: .shared()) {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
                
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import from Files", systemImage: "folder")
                }
            } label: {
                 Text("Edit Profile Picture")
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(AppTheme.brand)
            }
            .disabled(isUploading)
            
            // User name
            Text(store.currentUser.name)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .onAppear {
            if let hex = store.currentUser.profileColorHex, let color = Color(hex: hex) {
                profileColor = color
            }
        }
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
    
    // MARK: - Handlers
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Access security scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                uploadError = "Permission denied to access the file."
                showUploadError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let data = try Data(contentsOf: url)
                Task {
                    await uploadImage(data)
                }
            } catch {
                uploadError = "Failed to read file: \(error.localizedDescription)"
                showUploadError = true
            }
        case .failure(let error):
            uploadError = "Import failed: \(error.localizedDescription)"
            showUploadError = true
        }
    }
    
    @MainActor
    private func uploadImage(_ data: Data) async {
        guard !data.isEmpty else { return }
        
        // Basic validation - check max size (e.g. 10MB)
        if data.count > 10 * 1024 * 1024 {
            uploadError = "Image is too large (max 10MB)."
            showUploadError = true
            return
        }
        
        isUploading = true
        
        do {
            try await store.uploadProfileImage(data)
            isUploading = false
            // Reset selections
            photosSelection = nil
            capturedImage = nil
        } catch {
            isUploading = false
            uploadError = "Upload failed: \(error.localizedDescription)"
            showUploadError = true
            // Reset selections
            photosSelection = nil
            capturedImage = nil
        }
    }
    
    // MARK: - Data Management Section
    
    @State private var showClearDataConfirmation = false
    
    private var dataManagementSection: some View {
        VStack(spacing: 16) {
            Text("Data Management")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                // Import/Export button
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
                }
                .buttonStyle(.plain)
                
                Divider()
                    .padding(.horizontal, 8)
                
                // Clear All Data button
                Button(action: {
                    showClearDataConfirmation = true
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(.red.opacity(0.1))
                            )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clear All My Data")
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundStyle(.red)
                            
                            Text("Remove all your expenses, groups & friends")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppTheme.card)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
            )
        }
        .alert("Clear All Data?", isPresented: $showClearDataConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                store.clearAllUserData()
            }
        } message: {
            Text("This will delete all your expenses, remove you from groups, and clear your friends list. Other users in shared groups will keep their data. This cannot be undone.")
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
        Task {
            await store.signOut()
        }
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
