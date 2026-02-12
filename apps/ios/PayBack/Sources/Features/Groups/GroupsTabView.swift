import SwiftUI

struct GroupsTabView: View {
    @EnvironmentObject var store: AppStore
    @Binding var path: [GroupsRoute]
    @Binding var selectedRootTab: Int
    var rootResetToken: UUID = UUID()
    @State private var showCreateGroup = false
    
    var body: some View {
        NavigationStack(path: $path) {
            homeContent
            .id(rootResetToken)
            .navigationDestination(for: GroupsRoute.self) { route in
                switch route {
                case .groupDetail(let groupId):
                    if let group = store.navigationGroup(id: groupId) {
                        GroupDetailView(
                            group: group,
                            onMemberTap: { member in
                                path.append(.friendDetail(memberId: member.id))
                            },
                            onExpenseTap: { expense in
                                path.append(.expenseDetail(expenseId: expense.id))
                            }
                        )
                        .environmentObject(store)
                    } else {
                        NavigationRouteUnavailableView(
                            title: "Group Not Available",
                            message: "This group could not be found. It may have been deleted."
                        )
                    }
                case .friendDetail(let memberId):
                    if let friend = store.navigationMember(id: memberId) {
                        FriendDetailView(
                            friend: friend,
                            onExpenseSelected: { expense in
                                path.append(.expenseDetail(expenseId: expense.id))
                            }
                        )
                        .environmentObject(store)
                    } else {
                        NavigationRouteUnavailableView(
                            title: "Friend Not Available",
                            message: "This friend could not be found. They may have been removed."
                        )
                    }
                case .expenseDetail(let expenseId):
                    if let expense = store.navigationExpense(id: expenseId) {
                        ExpenseDetailView(expense: expense)
                            .environmentObject(store)
                    } else {
                        NavigationRouteUnavailableView(
                            title: "Expense Not Available",
                            message: "This expense could not be found. It may have been removed."
                        )
                    }
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar(path.isEmpty ? .hidden : .visible, for: .navigationBar)
        }
    }
    
    @ViewBuilder
    private var homeContent: some View {
        ZStack(alignment: .topLeading) {
            GroupsListView(onGroupSelected: { group in
                path.append(.groupDetail(groupId: group.id))
            })
            .padding(.horizontal)
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                HStack {
                    Text("Groups")
                        .font(.system(size: AppMetrics.headerTitleFontSize, weight: .bold))
                        .foregroundStyle(AppTheme.brand)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            handleDoubleTap()
                        }

                    Spacer()
                    
                    Button(action: {
                        showCreateGroup = true
                    }) {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(AppTheme.plusIconColor)
                            .frame(width: AppMetrics.smallIconButtonSize, height: AppMetrics.smallIconButtonSize)
                            .background(Circle().fill(AppTheme.brand))
                            .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Create Group")
                }
                .padding(.horizontal)
                .padding(.top, AppMetrics.headerTopPadding)
                .padding(.bottom, AppMetrics.headerBottomPadding)
            }
            .background(AppTheme.background)
        }
        .sheet(isPresented: $showCreateGroup) {
            CreateGroupView()
                .environmentObject(store)
        }
    }
    
    private func handleDoubleTap() {
        // Double-tap on Groups title switches to Friends tab
        withAnimation(.easeInOut(duration: 0.3)) {
            selectedRootTab = RootTab.friends.rawValue
        }
    }
}
