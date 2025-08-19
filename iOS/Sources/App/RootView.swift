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

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                PeopleHomeView()
                    .tabItem { Label("People", systemImage: "person.2") }
                    .tag(0)

                ActivityView()
                    .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .tag(1)
            }
            .tint(AppTheme.brand)
            .accentColor(AppTheme.brand)
            .background(AppTheme.background.ignoresSafeArea())

            // Center FAB overlay; expose bounds via preference for precise circle origin
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    AddFAB(action: openAdd, namespace: addNS, isActive: showAddOverlay || selectedGroupForNewExpense != nil)
                        .padding(.bottom, 10)
                        .allowsHitTesting(!(showAddOverlay || selectedGroupForNewExpense != nil))
                        // Anchor preference set inside AddFAB
                    Spacer()
                }
            }

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
                    .transition(.opacity)
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
                    if showAddOverlay {
                        // Expanding circle from FAB center
                        Circle()
                            .fill(AppTheme.brand)
                            .frame(width: circleSize, height: circleSize)
                            .position(x: center.x, y: center.y)
                            .ignoresSafeArea()
                            .onAppear {
                                let diagonal = sqrt(proxy.size.width * proxy.size.width + proxy.size.height * proxy.size.height)
                                let diameter = diagonal * 2.2
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { circleSize = diameter }
                            }
                    }

                    if showAddOverlay && showPickerUI {
                        TargetPickerTeal(
                            onClose: closeAdd,
                            onSelectGroup: { group in
                                withAnimation(AppAnimation.fade) { selectedGroupForNewExpense = group }
                                withAnimation(AppAnimation.fade) { showAddOverlay = false; showPickerUI = false }
                            },
                            onSelectFriend: { friend in
                                let g = store.directGroup(with: friend)
                                withAnimation(AppAnimation.fade) { selectedGroupForNewExpense = g }
                                withAnimation(AppAnimation.fade) { showAddOverlay = false; showPickerUI = false }
                            }
                        )
                        .transition(.opacity)
                    }
                }
            }
        }
        // keep preference available; circle rendered inside ZStack above
    }

    private func openAdd() {
        backgroundSnapshot = captureWindowSnapshot()
        showPickerUI = false
        circleSize = 64
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showAddOverlay = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(AppAnimation.fade) { showPickerUI = true }
        }
    }

    private func closeAdd() {
        withAnimation(AppAnimation.quick) {
            showPickerUI = false
            showAddOverlay = false
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
                    .foregroundStyle(.white)
            }
        }
        .anchorPreference(key: FABBoundsKey.self, value: .bounds) { $0 }
        .opacity(isActive ? 0 : 1)
        .accessibilityLabel("Add")
    }
}

private struct TargetPickerTeal: View {
    @EnvironmentObject var store: AppStore
    let onClose: () -> Void
    let onSelectGroup: (SpendingGroup) -> Void
    let onSelectFriend: (GroupMember) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose target")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                }
            }
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 8)

            ScrollView {
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
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 14)
                                    .background(Color.white)
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
                                            Text(g.name).font(.headline).foregroundStyle(.primary)
                                            Text("\(g.members.count) members").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 14)
                                    .background(Color.white)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.brand)
    }

    private var uniqueMembers: [GroupMember] {
        var seen: Set<UUID> = []
        var out: [GroupMember] = []
        for g in store.groups {
            for m in g.members where !seen.contains(m.id) {
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
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 4)
    }
}


