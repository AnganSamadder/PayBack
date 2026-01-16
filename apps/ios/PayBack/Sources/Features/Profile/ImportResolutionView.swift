import SwiftUI

struct ImportResolutionView: View {
    @Environment(\.dismiss) private var dismiss
    
    let conflicts: [ImportConflict]
    let onResolve: ([UUID: ImportResolution]) -> Void
    let onCancel: () -> Void
    
    @State private var resolutions: [UUID: ImportResolution] = [:]
    // Track unique names for "Apply to All" functionality
    @State private var uniqueNames: Set<String> = []
    
    init(conflicts: [ImportConflict], onResolve: @escaping ([UUID: ImportResolution]) -> Void, onCancel: @escaping () -> Void) {
        self.conflicts = conflicts
        self.onResolve = onResolve
        self.onCancel = onCancel
        
        // Initialize with default (Link to Existing)
        var initialResolutions: [UUID: ImportResolution] = [:]
        var names: Set<String> = []
        for conflict in conflicts {
            initialResolutions[conflict.importMemberId] = .linkToExisting(conflict.existingFriend.memberId)
            names.insert(conflict.importName)
        }
        _resolutions = State(initialValue: initialResolutions)
        _uniqueNames = State(initialValue: names)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with explanation
                VStack(spacing: 8) {
                    Text("Duplicate Friends Found")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    
                    Text("We found friends in the import that match your existing contacts. Review and link them to avoid duplicates.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.vertical, 24)
                
                // Conflicts List
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(conflicts, id: \.importMemberId) { conflict in
                            ConflictRow(
                                conflict: conflict,
                                resolution: binding(for: conflict.importMemberId),
                                onApplyToAll: { resolution in
                                    applyToAll(name: conflict.importName, resolution: resolution)
                                }
                            )
                        }
                    }
                    .padding()
                }
                
                // Footer Actions
                VStack(spacing: 16) {
                    Divider()
                    
                    Button(action: {
                        onResolve(resolutions)
                    }) {
                        Text("Confirm Import")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(AppTheme.brand)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
                .background(AppTheme.background)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
        }
    }
    
    private func binding(for id: UUID) -> Binding<ImportResolution> {
        Binding(
            get: { resolutions[id] ?? .createNew },
            set: { resolutions[id] = $0 }
        )
    }
    
    private func applyToAll(name: String, resolution: ImportResolution) {
        for conflict in conflicts where conflict.importName == name {
            // Need to construct the correct resolution for each specific conflict if it's .linkToExisting
            // ensuring we link to THAT conflict's existing friend (though names match, IDs differ)
            switch resolution {
            case .createNew:
                resolutions[conflict.importMemberId] = .createNew
            case .linkToExisting:
                // If applying "Link" to all "Johns", link each import John to its matched local John
                resolutions[conflict.importMemberId] = .linkToExisting(conflict.existingFriend.memberId)
            }
        }
    }
}

struct ConflictRow: View {
    let conflict: ImportConflict
    @Binding var resolution: ImportResolution
    let onApplyToAll: (ImportResolution) -> Void
    
    var isLinked: Bool {
        if case .linkToExisting = resolution { return true }
        return false
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Name and Conflict Info
            HStack {
                Text(conflict.importName)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                
                Spacer()
                
                Menu {
                    Button {
                        onApplyToAll(.linkToExisting(conflict.existingFriend.memberId))
                    } label: {
                        Label("Link All '\(conflict.importName)'", systemImage: "link")
                    }
                    
                    Button {
                        onApplyToAll(.createNew)
                    } label: {
                        Label("Create New for All", systemImage: "plus")
                    }
                } label: {
                    Text("Apply to All")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.brand)
                }
            }
            
            // Comparison Card
            HStack(spacing: 0) {
                // Existing Friend Option
                Button {
                    resolution = .linkToExisting(conflict.existingFriend.memberId)
                } label: {
                    VStack(spacing: 8) {
                        AvatarView(
                            name: conflict.existingFriend.name,
                            size: 40,
                            imageUrl: conflict.existingFriend.profileImageUrl,
                            colorHex: conflict.existingFriend.profileColorHex
                        )
                        .overlay(
                            Circle()
                                .stroke(AppTheme.brand, lineWidth: isLinked ? 3 : 0)
                        )
                        
                        Text("Existing")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        if isLinked {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AppTheme.brand)
                                .font(.caption)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(isLinked ? AppTheme.brand.opacity(0.1) : Color.clear)
                }
                .buttonStyle(.plain)
                
                Divider()
                    .frame(height: 60)
                
                // New Friend Option
                Button {
                    resolution = .createNew
                } label: {
                    VStack(spacing: 8) {
                        AvatarView(
                            name: conflict.importName,
                            size: 40,
                            imageUrl: conflict.importProfileImageUrl,
                            colorHex: conflict.importProfileColorHex
                        )
                        .overlay(
                            Circle()
                                .stroke(AppTheme.brand, lineWidth: !isLinked ? 3 : 0)
                        )
                        
                        Text("New (Import)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        if !isLinked {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AppTheme.brand)
                                .font(.caption)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(!isLinked ? AppTheme.brand.opacity(0.1) : Color.clear)
                }
                .buttonStyle(.plain)
            }
            .background(AppTheme.background)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
            )
        }
        .padding(16)
        .background(AppTheme.card)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

// Support Types moved to DataImportService.swift
