import SwiftUI

// Navigation state for Groups tab
enum GroupsNavigationState: Equatable {
    case home
    case groupDetail(SpendingGroup)
    case friendDetail(GroupMember)
    case expenseDetail(SpendingGroup, Expense)
}

struct GroupsTabView: View {
    @EnvironmentObject var store: AppStore
    @Binding var navigationState: GroupsNavigationState
    @Binding var selectedTab: Int
    @State private var showCreateGroup = false
    @State private var lastGroupForFriendDetail: SpendingGroup?
    
    var body: some View {
        NavigationStack {
            ZStack {
                switch navigationState {
                case .home:
                    homeContent
                case .groupDetail(let group):
                    DetailContainer(
                        action: {
                            navigationState = .home
                            lastGroupForFriendDetail = nil
                        },
                        background: {
                            homeContent
                                .opacity(0.2)
                                .scaleEffect(0.95)
                                .offset(y: 50)
                        }
                    ) {
                        GroupDetailView(
                            group: group,
                            onBack: {
                                navigationState = .home
                                lastGroupForFriendDetail = nil
                            },
                            onMemberTap: { member in
                                lastGroupForFriendDetail = group
                                navigationState = .friendDetail(member)
                            },
                            onExpenseTap: { expense in
                                navigationState = .expenseDetail(group, expense)
                            }
                        )
                        .environmentObject(store)
                    }
                case .friendDetail(let friend):
                    DetailContainer(
                        action: {
                            if let group = lastGroupForFriendDetail {
                                navigationState = .groupDetail(group)
                                lastGroupForFriendDetail = nil
                            } else {
                                navigationState = .home
                            }
                        },
                        background: {
                            homeContent
                                .opacity(0.2)
                                .scaleEffect(0.95)
                                .offset(y: 50)
                        }
                    ) {
                        FriendDetailView(friend: friend, onBack: {
                            if let group = lastGroupForFriendDetail {
                                navigationState = .groupDetail(group)
                                lastGroupForFriendDetail = nil
                            } else {
                                navigationState = .home
                            }
                        })
                        .environmentObject(store)
                    }
                case .expenseDetail(let group, let expense):
                    DetailContainer(
                        action: {
                            navigationState = .groupDetail(group)
                        },
                        background: {
                            homeContent
                                .opacity(0.2)
                                .scaleEffect(0.95)
                                .offset(y: 50)
                        }
                    ) {
                        ExpenseDetailView(expense: expense, onBack: {
                            navigationState = .groupDetail(group)
                        })
                        .environmentObject(store)
                    }
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
    
    @ViewBuilder
    private var homeContent: some View {
        ZStack(alignment: .topLeading) {
            GroupsListView(onGroupSelected: { group in
                lastGroupForFriendDetail = nil
                navigationState = .groupDetail(group)
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
            selectedTab = 0
        }
    }
}
