import SwiftUI

struct NavigationRouteUnavailableView: View {
    let title: String
    let message: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentUnavailableView(title, systemImage: "exclamationmark.triangle", description: Text(message))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
    }
}
