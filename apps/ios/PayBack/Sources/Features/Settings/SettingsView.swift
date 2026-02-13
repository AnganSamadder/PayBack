import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var preferNicknames: Bool { store.session?.account.preferNicknames ?? false }
    private var preferWholeNames: Bool { store.session?.account.preferWholeNames ?? false }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Display section
                    displaySection

                    // Account section
                    accountSection

                    // Data section
                    dataSection

                    // About section
                    aboutSection

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.brand)
                }
            }
        }
    }

    // MARK: - Display Section

    private var displaySection: some View {
        VStack(spacing: 16) {
            Text("Display")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                // Prefer Nicknames toggle
                Toggle(isOn: Binding(
                    get: { preferNicknames },
                    set: { store.updateAccountSettings(preferNicknames: $0, preferWholeNames: preferWholeNames) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prefer Nicknames")
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(.primary)

                        Text("Show your custom nicknames instead of real names when available")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: AppTheme.brand))
                .padding(16)

                Divider()
                    .padding(.horizontal, 16)

                // Show Full Names toggle
                Toggle(isOn: Binding(
                    get: { preferWholeNames },
                    set: { store.updateAccountSettings(preferNicknames: preferNicknames, preferWholeNames: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show Full Names")
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(.primary)

                        Text("Display full names (first + last) instead of just first names")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: AppTheme.brand))
                .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppTheme.card)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
            )
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(spacing: 16) {
            Text("Account")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                // Display name row
                SettingsRow(
                    icon: "person.fill",
                    label: "Name",
                    value: store.currentUser.name
                )

                // Email row
                if let account = store.session?.account {
                    SettingsRow(
                        icon: "envelope.fill",
                        label: "Email",
                        value: account.email
                    )
                }

                Divider()
                    .padding(.vertical, 4)

                NavigationLink {
                    DeleteAccountView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(Color.red.opacity(0.1))
                            )

                        Text("Delete Account")
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(.red)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
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
    }

    // MARK: - Data Section

    private var dataSection: some View {
        VStack(spacing: 16) {
            Text("Data Management")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                // Merge Friends
                NavigationLink {
                    MergeFriendsView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AppTheme.brand)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(AppTheme.brand.opacity(0.1))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Merge Friends")
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundStyle(.primary)

                            Text("Combine two unlinked friends into one")
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.friends.filter { !$0.hasLinkedAccount }.count < 2)
                .opacity(store.friends.filter { !$0.hasLinkedAccount }.count < 2 ? 0.6 : 1)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppTheme.card)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
            )
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 16) {
            Text("About")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                // App version
                SettingsRow(
                    icon: "info.circle.fill",
                    label: "Version",
                    value: appVersion
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppTheme.card)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
            )
        }
    }

    // MARK: - Helper Properties

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Settings Row Component

private struct SettingsRow: View {
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
