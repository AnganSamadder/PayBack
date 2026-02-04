
import XCTest
@testable import PayBack

final class LinkedUserTests: XCTestCase {
    
    // mimic the isMe logic we WANT
    func isMe(_ memberId: String, currentUserId: String, linkedMemberId: String?) -> Bool {
        return memberId == currentUserId || memberId == linkedMemberId
    }
    
    func testLinkedUserVisibility() {
        // Setup
        let mainMemberId = "member_main"
        let testUserId = "user_test"
        let testUserLinkedId = mainMemberId // The test user is linked to the main member ID
        
        // Scenario: Friend paid, split is between Friend and Main Member
        // This is how expenses look when created by the main account, but viewed by the linked account
        let splitMemberId = mainMemberId // The split is assigned to the MAIN member ID
        
        // Check "My Split" resolution
        // The current user (Example User) should see this split as THEIRS
        let isMySplit = isMe(splitMemberId, currentUserId: testUserId, linkedMemberId: testUserLinkedId)
        
        XCTAssertTrue(isMySplit, "Linked user should identify the main member's split as their own")
    }
    
    func testDirectExpenseCardLogic_Simulation() {
        // Mimic DirectExpenseCard logic
        let currentUserId = "user_test"
        let linkedMemberId = "member_main"
        
        let expensePaidBy = "member_friend"
        let splits = [
            (memberId: "member_friend", amount: 50),
            (memberId: "member_main", amount: 50)
        ]
        
        // Logic from FriendDetailView (Hypothetical corrected logic)
        // Find "My" split
        let mySplit = splits.first { isMe($0.memberId, currentUserId: currentUserId, linkedMemberId: linkedMemberId) }
        
        XCTAssertNotNil(mySplit, "Should find a split belonging to the linked user")
        XCTAssertEqual(mySplit?.amount, 50)
        
        // Determine Text
        if expensePaidBy != currentUserId && expensePaidBy != linkedMemberId {
            // Friend paid
            if let mySplit = mySplit {
                print("You owe \(mySplit.amount)")
                XCTAssertEqual(mySplit.amount, 50)
            } else {
                XCTFail("Failed to find my split")
            }
        }
    }
}
