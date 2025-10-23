import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedTab: Int = 0
    @State private var showAddOverlay: Bool = false
    @State private var expandCircle: Bool = false
    @State private var selectedGroupForNewExpense: SpendingGroup?
    @Namespace private var addNS
    @State private var addReveal: Bool = false
    @State private var backgroundSnapshot: UIImage?
    @State private var showPickerUI: Bool = false
    @State private var circleSize: CGFloat = 64
    @State private var showExpandingCircle: Bool = false
    @State private var peopleScope: PeopleScope = .friends
    @State private var activityViewSelectedTab: Int = 0
    @State private var peopleNavigationState: PeopleNavigationState = .home
    @State private var shouldResetActivityNavigation: Bool = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Main content
                TabView(selection: $selectedTab) {
                    PeopleHomeView(scope: $peopleScope, navigationState: $peopleNavigationState)
                        .environmentObject(store)
                        .tag(0)

                    ActivityView(selectedTab: $activityViewSelectedTab, shouldResetNavigation: $shouldResetActivityNavigation)
                        .environmentObject(store)
                        .tag(1)
                }
                
                // Custom tab bar
                CustomTabBar(selectedTab: $selectedTab, peopleScope: $peopleScope, activityViewSelectedTab: $activityViewSelectedTab, peopleNavigationState: $peopleNavigationState, shouldResetActivityNavigation: $shouldResetActivityNavigation)
                    .offset(y: -40) // Compensate for safe area changes
            }

            // Center FAB overlay; expose bounds via preference for precise circle origin
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    AddFAB(action: openAdd, namespace: addNS, isActive: showAddOverlay || selectedGroupForNewExpense != nil)
                        .allowsHitTesting(!(showAddOverlay || selectedGroupForNewExpense != nil))
                        // Anchor preference set inside AddFAB
                    Spacer()
                }
            }
            .padding(.bottom, 40) // Compensate for safe area changes

            // Teal background + picker are attached via overlay on the ZStack below

            // Frozen snapshot of previous content shown behind the add page while it is active
            if selectedGroupForNewExpense != nil, let snapshot = backgroundSnapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .zIndex(1)
            }

            

            // AddExpenseView on top
            if let group = selectedGroupForNewExpense {
                AddExpenseView(group: group, onClose: {
                    withAnimation(AppAnimation.fade) {
                        selectedGroupForNewExpense = nil
                        backgroundSnapshot = nil
                    }
                })
                    .environmentObject(store)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    .zIndex(3)
            }
        }
        .overlayPreferenceValue(FABBoundsKey.self) { anchor in
            GeometryReader { proxy in
                // Resolve FAB center in this proxy's coordinate space
                let center: CGPoint = {
                    if let anchor {
                        let rect: CGRect = proxy[anchor]
                        return CGPoint(x: rect.midX, y: rect.midY)
                    } else {
                        return CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                }()
                ZStack {
                    // Full screen background to fill safe areas - during TargetPicker and transition to AddExpenseView
                    if showAddOverlay && (showPickerUI || selectedGroupForNewExpense != nil) {
                        AppTheme.chooseTargetBackground
                            .ignoresSafeArea()
                            .zIndex(-1)
                    }
                    if showAddOverlay && selectedGroupForNewExpense == nil && showExpandingCircle {
                        // Expanding circle from FAB center - show immediately when overlay appears
                        ZStack {
                            // Outer turquoise circle
                            Circle()
                                .fill(AppTheme.brand)
                                .frame(width: circleSize, height: circleSize)
                                .opacity(showExpandingCircle ? 1 : 0)
                                .animation(.easeOut(duration: 0.2), value: showExpandingCircle)

                            // Inner circle (smaller) - black in dark mode, white in light mode
                            Circle()
                                .fill(AppTheme.expandingCircleInnerColor)
                                .frame(width: circleSize * 0.85, height: circleSize * 0.85)
                                .opacity(showExpandingCircle ? 1 : 0)
                                .animation(.easeOut(duration: 0.3).delay(0.1), value: showExpandingCircle)
                        }
                        .position(x: center.x, y: center.y)
                        .ignoresSafeArea()
                        .onAppear {
                            let diagonal = sqrt(proxy.size.width * proxy.size.width + proxy.size.height * proxy.size.height)
                            let diameter = diagonal * 2.2
                            withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) { circleSize = diameter }
                            
                            // Hide circle after animation completes, with extra time for fade-out
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                showExpandingCircle = false
                            }
                        }
                    }

                    if showAddOverlay && showPickerUI {
                        TargetPicker(
                            onClose: closeAdd,
                            onSelectGroup: { group in
                                // Fast fade transition between TargetPicker and AddExpenseView
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedGroupForNewExpense = group
                                }
                                // Keep background visible during transition, hide after
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        showPickerUI = false
                                    }
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showAddOverlay = false
                                }
                            },
                            onSelectFriend: { friend in
                                let g = store.directGroup(with: friend)
                                // Fast fade transition between TargetPicker and AddExpenseView
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedGroupForNewExpense = g
                                }
                                // Keep background visible during transition, hide after
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        showPickerUI = false
                                    }
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showAddOverlay = false
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    }
                }
            }
        }
        .statusBarHidden(true)
        .ignoresSafeArea(.container, edges: showAddOverlay ? [] : .bottom)
        // keep preference available; circle rendered inside ZStack above
    }

    private func openAdd() {
        backgroundSnapshot = captureWindowSnapshot()
        showPickerUI = false
        circleSize = 64
        showExpandingCircle = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showAddOverlay = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(AppAnimation.fade) { showPickerUI = true }
        }
    }

    private func closeAdd() {
        withAnimation(AppAnimation.quick) {
            showPickerUI = false
            showAddOverlay = false
            showExpandingCircle = false
        }
        circleSize = 64
    }

    private func captureWindowSnapshot() -> UIImage? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

// PreferenceKey to pass the FAB's bounds anchor to the overlay
private struct FABBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private struct AddFAB: View {
    let action: () -> Void
    let namespace: Namespace.ID
    let isActive: Bool
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(AppTheme.brand)
                    .frame(width: 64, height: 64)
                    .shadow(color: AppTheme.brand.opacity(0.35), radius: 8, y: 4)
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AppTheme.plusIconColor)
            }
        }
        .anchorPreference(key: FABBoundsKey.self, value: .bounds) { $0 }
        .opacity(isActive ? 0 : 1)
        .accessibilityLabel("Add")
    }
}

private struct CustomTabBar: View {
    @Binding var selectedTab: Int
    @Binding var peopleScope: PeopleScope
    @Binding var activityViewSelectedTab: Int
    @Binding var peopleNavigationState: PeopleNavigationState
    @Binding var shouldResetActivityNavigation: Bool
    
    var body: some View {
        HStack(spacing: 0) {
            // People tab
            Button(action: {
                selectedTab = 0
                // Reset navigation state to home when switching to People tab
                if peopleNavigationState != .home {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        peopleNavigationState = .home
                    }
                }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.system(size: 24))
                        .foregroundStyle(selectedTab == 0 ? AppTheme.brand : .secondary)
                    Text("People")
                        .font(.caption)
                        .foregroundStyle(selectedTab == 0 ? AppTheme.brand : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { _ in
                if selectedTab == 0 {
                    peopleScope = (peopleScope == .friends ? .groups : .friends)
                }
            })
            .padding(.bottom, 8)
            
            // Activity tab
            Button(action: {
                selectedTab = 1
                // Reset navigation state to home when switching to Activity tab
                if peopleNavigationState != .home {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        peopleNavigationState = .home
                    }
                }
                // Reset Activity navigation when switching to Activity tab
                shouldResetActivityNavigation = true
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24))
                        .foregroundStyle(selectedTab == 1 ? AppTheme.brand : .secondary)
                    Text("Activity")
                        .font(.caption)
                        .foregroundStyle(selectedTab == 1 ? AppTheme.brand : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { _ in
                if selectedTab == 1 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        activityViewSelectedTab = (activityViewSelectedTab == 0 ? 1 : 0)
                    }
                }
            })
            .padding(.bottom, 8)
        }
        .frame(height: 0)
    }
}

private struct TargetPicker: View {
    @EnvironmentObject var store: AppStore
    let onClose: () -> Void
    let onSelectGroup: (SpendingGroup) -> Void
    let onSelectFriend: (GroupMember) -> Void

    var body: some View {
        VStack(spacing: 0) {
                                HStack {
                        Text("Choose target")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AppTheme.chooseTargetTextColor)
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(AppTheme.chooseTargetTextColor)
                                .padding(8)
                                .background(Capsule().fill(AppTheme.chooseTargetTextColor.opacity(0.15)))
                        }
                    }
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Friends section (cards on white background)
                    if !uniqueMembers.isEmpty {
                        SectionHeader(text: "Friends")
                        VStack(spacing: 12) {
                            ForEach(uniqueMembers) { m in
                                Button { onSelectFriend(m) } label: {
                                    HStack(spacing: 12) {
                                        AvatarView(name: m.name)
                                        Text(m.name)
                                            .font(.headline)
                                            .foregroundStyle(AppTheme.brandTextColor)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 14)
                                    .background(AppTheme.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                    }

                    // Groups section (cards on white background)
                    let nonDirectGroups = store.groups.filter { !($0.isDirect ?? false) }
                    if !nonDirectGroups.isEmpty {
                        SectionHeader(text: "Groups")
                        VStack(spacing: 12) {
                            ForEach(nonDirectGroups) { g in
                                Button { onSelectGroup(g) } label: {
                                    HStack(spacing: 12) {
                                        GroupIcon(name: g.name)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(g.name).font(.headline).foregroundStyle(AppTheme.brandTextColor)
                                            Text("\(g.members.count) members").font(.caption).foregroundStyle(AppTheme.brandTextColor.opacity(0.7))
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 14)
                                    .background(AppTheme.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal)
            }
        }
        // .background(Color.orange)
    }

    private var uniqueMembers: [GroupMember] {
        var seen: Set<UUID> = []
        var out: [GroupMember] = []
        
        for g in store.groups {
            for m in g.members where !seen.contains(m.id) {
                // CRITICAL: Never include the current user
                guard !store.isCurrentUser(m) else { continue }
                
                // Extra safety: check ID directly
                guard m.id != store.currentUser.id else { continue }
                
                seen.insert(m.id)
                out.append(m)
            }
        }
        
        return out
    }
}

private struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption)
            .foregroundStyle(AppTheme.chooseTargetTextColor.opacity(0.8))
            .padding(.horizontal, 4)
    }
}


