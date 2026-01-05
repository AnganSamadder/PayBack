import SwiftUI
import UniformTypeIdentifiers

struct ImportExportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    
    // State for export
    @State private var isExporting = false
    @State private var showExportSuccess = false
    @State private var exportSuccessMessage = ""
    @State private var showShareSheet = false
    @State private var exportText = ""
    @State private var showFileSaveDialog = false
    
    // State for import
    @State private var isImporting = false
    @State private var showImportResult = false
    @State private var importResultTitle = ""
    @State private var importResultMessage = ""
    @State private var importResultIsSuccess = false
    @State private var showFilePickerDialog = false
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 32) {
                    // Export Section
                    exportSection
                    
                    // Import Section
                    importSection
                    
                    // Info Section
                    infoSection
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Import & Export")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.brand)
                }
            }
        }
        .alert(importResultTitle, isPresented: $showImportResult) {
            Button("OK") { }
        } message: {
            Text(importResultMessage)
        }
        .alert("Export Complete", isPresented: $showExportSuccess) {
            Button("OK") { }
        } message: {
            Text(exportSuccessMessage)
        }
        .sheet(isPresented: $showShareSheet) {
            ExportShareSheet(text: exportText)
        }
        .fileExporter(
            isPresented: $showFileSaveDialog,
            document: TextFileDocument(text: exportText),
            contentType: .commaSeparatedText,
            defaultFilename: DataExportService.suggestedFilename()
        ) { result in
            switch result {
            case .success(let url):
                exportSuccessMessage = "File saved successfully to \(url.lastPathComponent)"
                showExportSuccess = true
            case .failure(let error):
                exportSuccessMessage = "Failed to save file: \(error.localizedDescription)"
                showExportSuccess = true
            }
        }
        .fileImporter(
            isPresented: $showFilePickerDialog,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }
    
    // MARK: - Export Section
    
    private var exportSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)
                
                Text("Export Data")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                
                Spacer()
            }
            
            Text("Export all your expenses, groups, and friends to backup or transfer to another device.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                // Copy to Clipboard
                ExportButton(
                    icon: "doc.on.clipboard",
                    title: "Copy to Clipboard",
                    subtitle: "Copy export data to paste anywhere"
                ) {
                    exportToClipboard()
                }
                
                // Save as CSV File
                ExportButton(
                    icon: "doc.text",
                    title: "Save as CSV File",
                    subtitle: "Save to your device as a file"
                ) {
                    exportToFile()
                }
                
                // Share via Share Sheet
                ExportButton(
                    icon: "square.and.arrow.up.on.square",
                    title: "More...",
                    subtitle: "Share via AirDrop, Messages, and more"
                ) {
                    exportViaShareSheet()
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(AppTheme.card)
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Import Section
    
    private var importSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)
                
                Text("Import Data")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                
                Spacer()
            }
            
            Text("Import expenses from a PayBack export file. New groups and expenses will be added to your account.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                // Paste from Clipboard
                ImportButton(
                    icon: "doc.on.clipboard",
                    title: "Paste from Clipboard",
                    subtitle: "Import data copied to clipboard"
                ) {
                    importFromClipboard()
                }
                
                // Import from File
                ImportButton(
                    icon: "folder",
                    title: "Import from File",
                    subtitle: "Select a PayBack export file"
                ) {
                    importFromFile()
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(AppTheme.card)
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Info Section
    
    private var infoSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppTheme.brand)
                
                Text("About Export Format")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Spacer()
            }
            
            Text("The export includes all your expense details:\n• Groups and members\n• Expense descriptions, amounts, and dates\n• Who paid and how it was split\n• Settlement status (including partial settlements)\n• Friend information")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.brand.opacity(0.1))
        )
    }
    
    // MARK: - Export Actions
    
    private func generateExportText() -> String {
        let accountEmail = store.session?.account.email ?? ""
        return DataExportService.exportAllData(
            groups: store.groups,
            expenses: store.expenses,
            friends: store.friends,
            currentUser: store.currentUser,
            accountEmail: accountEmail
        )
    }
    
    private func exportToClipboard() {
        isExporting = true
        let text = generateExportText()
        UIPasteboard.general.string = text
        
        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        isExporting = false
        exportSuccessMessage = "Export data copied to clipboard! You can paste it anywhere to save or share."
        showExportSuccess = true
    }
    
    private func exportToFile() {
        exportText = generateExportText()
        showFileSaveDialog = true
    }
    
    private func exportViaShareSheet() {
        exportText = generateExportText()
        showShareSheet = true
    }
    
    // MARK: - Import Actions
    
    private func importFromClipboard() {
        guard let clipboardText = UIPasteboard.general.string else {
            showImportError("Clipboard is empty. Please copy PayBack export data first.")
            return
        }
        
        performImport(from: clipboardText)
    }
    
    private func importFromFile() {
        showFilePickerDialog = true
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                showImportError("No file selected")
                return
            }
            
            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                showImportError("Unable to access the selected file")
                return
            }
            
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                performImport(from: text)
            } catch {
                showImportError("Failed to read file: \(error.localizedDescription)")
            }
            
        case .failure(let error):
            showImportError("Failed to select file: \(error.localizedDescription)")
        }
    }
    
    private func performImport(from text: String) {
        isImporting = true
        
        Task {
            let result = await DataImportService.importData(from: text, into: store)
            
            await MainActor.run {
                isImporting = false
                
                switch result {
                case .success(let summary):
                    if summary.totalItems == 0 {
                        showImportSuccess("Import Complete", "All data was already present in your account. No new items were added.")
                    } else {
                        showImportSuccess("Import Successful!", summary.description)
                    }
                    
                case .incompatibleFormat(let message):
                    showImportError(message)
                    
                case .partialSuccess(let summary, let errors):
                    let errorText = errors.prefix(3).joined(separator: "\n")
                    let moreText = errors.count > 3 ? "\n...and \(errors.count - 3) more issues" : ""
                    showImportSuccess(
                        "Import Completed with Issues",
                        "\(summary.description)\n\nSome items could not be imported:\n\(errorText)\(moreText)"
                    )
                }
            }
        }
    }
    
    private func showImportSuccess(_ title: String, _ message: String) {
        importResultTitle = title
        importResultMessage = message
        importResultIsSuccess = true
        showImportResult = true
        
        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
    
    private func showImportError(_ message: String) {
        importResultTitle = "Import Failed"
        importResultMessage = message
        importResultIsSuccess = false
        showImportResult = true
        
        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }
}

// MARK: - Export Button Component

private struct ExportButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(AppTheme.brand)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppTheme.brand.opacity(0.1))
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppTheme.background)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Import Button Component

private struct ImportButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange.opacity(0.1))
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppTheme.background)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Share Sheet

struct ExportShareSheet: UIViewControllerRepresentable {
    let text: String
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activityItems: [Any] = [text]
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Text File Document for file export

struct TextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    
    var text: String
    
    init(text: String) {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(data: data, encoding: .utf8) ?? ""
        } else {
            text = ""
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    ImportExportView()
        .environmentObject(AppStore())
}
