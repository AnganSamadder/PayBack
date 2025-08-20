import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        NavigationStack {
            if store.expenses.isEmpty {
                EmptyStateView("No activity yet", systemImage: "clock.arrow.circlepath", description: "Add an expense to get started")
                    .padding()
            } else {
                List {
                    ForEach(store.expenses.sorted(by: { $0.date > $1.date })) { e in
                        HStack(spacing: 12) {
                            GroupIcon(name: e.description)
                            VStack(alignment: .leading) {
                                Text(e.description).font(.headline)
                                Text(e.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(e.totalAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                        }
                        .padding(.vertical, 6)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppTheme.background)
            }
        }
        .navigationTitle("Activity")
        .background(AppTheme.background.ignoresSafeArea())
    }
}


