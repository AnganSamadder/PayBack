import XCTest
import SwiftUI
import Vision
@testable import PayBack

/// Render real screens with the pre-currency persisted-data shape. Ordinary
/// model fixtures default to USD and cannot reproduce this upgrade regression.
@MainActor
final class LegacyMoneyScreenTests: XCTestCase {
    func testLegacyFriendsAndDashboardKeepCompactBalances() async throws {
        let store = AppStore(
            persistence: MockPersistenceService(), accountService: MockAccountServiceForAppStore(),
            expenseCloudService: MockExpenseCloudServiceForAppStore(), groupCloudService: MockGroupCloudServiceForAppStore(),
            linkRequestService: MockLinkRequestServiceForAppStore(), inviteLinkService: MockInviteLinkServiceForTests(),
            skipClerkInit: true
        )
        let friend = GroupMember(name: "Alex")
        let emptyFriend = GroupMember(name: "Chris")
        let group = SpendingGroup(name: "Weekend Trip", members: [store.currentUser, friend])
        store.groups = [group]
        store.friends = [AccountFriend(memberId: friend.id, name: friend.name, status: "manual"), AccountFriend(memberId: emptyFriend.id, name: emptyFriend.name, status: "manual")]
        store.expenses = (0..<12).map { index in
            Expense(groupId: group.id, description: "Legacy Dinner \(index)", totalAmount: 20,
                    paidByMemberId: store.currentUser.id, involvedMemberIds: [store.currentUser.id, friend.id],
                    splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 10), ExpenseSplit(memberId: friend.id, amount: 10)],
                    currencyCode: nil)
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        previousWindow?.endEditing(true)
        defer { window.isHidden = true; previousWindow?.makeKey() }

        let friends = FriendsTabView(path: .constant([]), selectedRootTab: .constant(0)).environmentObject(store)
        let friendsText = try await render(friends, in: window, name: "Legacy Friends")
        XCTAssertTrue(friendsText.contains("Alex"))
        XCTAssertTrue(friendsText.contains("Chris"), "A second friend should remain visible without scrolling")
        XCTAssertFalse(friendsText.contains("Legacy Dinner"), "Expense descriptions must never fill friend balance labels")
        XCTAssertFalse(friendsText.lowercased().contains("currency unknown"))

        let dashboard = DashboardView(onGroupTap: { _ in }, onFriendTap: { _ in }, onExpenseTap: { _ in }).environmentObject(store)
        let dashboardText = try await render(dashboard, in: window, name: "Legacy Dashboard")
        XCTAssertTrue(dashboardText.contains("TOTAL BALANCE"))
        XCTAssertFalse(dashboardText.lowercased().contains("currency unknown"))
        XCTAssertTrue(dashboardText.contains("You are owed overall"))

        let friendText = try await render(FriendDetailView(friend: friend).environmentObject(store), in: window, name: "Legacy Friend Detail")
        XCTAssertTrue(friendText.contains("You get"))
        _ = try await render(GroupDetailView(group: group, onMemberTap: { _ in }, onExpenseTap: { _ in }).environmentObject(store), in: window, name: "Legacy Group Detail")
        let largeText = try await render(friends.dynamicTypeSize(.accessibility2), in: window, name: "Legacy Friends Large Text")
        XCTAssertFalse(largeText.lowercased().contains("currency unknown"))
        XCTAssertFalse(largeText.contains("Legacy Dinner"))

        let legacyExpenses = store.expenses
        store.expenses = [Expense(groupId: group.id, description: "One cent", totalAmount: 0.01,
                                  paidByMemberId: store.currentUser.id, involvedMemberIds: [store.currentUser.id, friend.id],
                                  splits: [ExpenseSplit(memberId: friend.id, amount: 0.01)], currencyCode: nil)]
        let centText = try await render(FriendDetailView(friend: friend).environmentObject(store), in: window, name: "Legacy One Cent")
        XCTAssertTrue(centText.contains("You get"), "A positive one-cent balance must not say You owe")
        store.expenses.append(Expense(groupId: group.id, description: "Opposite cent", totalAmount: 0.01,
                                      paidByMemberId: friend.id, involvedMemberIds: [store.currentUser.id, friend.id],
                                      splits: [ExpenseSplit(memberId: store.currentUser.id, amount: 0.01)], currencyCode: nil))
        let offsetText = try await render(FriendDetailView(friend: friend).environmentObject(store), in: window, name: "Legacy Offset Balances")
        XCTAssertTrue(offsetText.contains("Balances offset"))
        XCTAssertFalse(offsetText.contains("All Settled"))
        store.expenses = legacyExpenses

        // An opt-in manual review window uses the same in-memory fixture. It is
        // never compiled into the app or connected to a live backend.
        if let seconds = ProcessInfo.processInfo.environment["PAYBACK_SCREEN_REVIEW_SECONDS"].flatMap(Double.init), seconds > 0 {
            _ = try await render(RootView(pendingInviteToken: .constant(nil)).environmentObject(store), in: window, name: "Legacy Full App")
            try await Task.sleep(for: .seconds(min(seconds, 180)))
        }
    }

    private func render<V: View>(_ view: V, in window: UIWindow, name: String) async throws -> String {
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
