import XCTest
@testable import PayBack

final class BulkImportDTOTests: XCTestCase {
    
    func testBulkFriendDTO_Encoding() throws {
        let friend = BulkFriendDTO(
            member_id: "member-1",
            name: "John Doe",
            nickname: "Johnny",
            status: "friend",
            profile_image_url: "https://example.com/image.png",
            profile_avatar_color: "#FF5733"
        )
        
        let data = try JSONEncoder().encode(friend)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        
        XCTAssertEqual(json["member_id"] as? String, "member-1")
        XCTAssertEqual(json["name"] as? String, "John Doe")
        XCTAssertEqual(json["nickname"] as? String, "Johnny")
        XCTAssertEqual(json["status"] as? String, "friend")
        XCTAssertEqual(json["profile_image_url"] as? String, "https://example.com/image.png")
        XCTAssertEqual(json["profile_avatar_color"] as? String, "#FF5733")
    }
    
    func testBulkGroupDTO_Encoding() throws {
        let member = BulkGroupMemberDTO(id: "member-1", name: "John", profile_avatar_color: "#FF5733")
        let group = BulkGroupDTO(id: "group-1", name: "Trip", members: [member], is_direct: false)
        
        let data = try JSONEncoder().encode(group)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        
        XCTAssertEqual(json["id"] as? String, "group-1")
        XCTAssertEqual(json["name"] as? String, "Trip")
        XCTAssertEqual(json["is_direct"] as? Bool, false)
        
        let members = try XCTUnwrap(json["members"] as? [[String: Any]])
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0]["id"] as? String, "member-1")
        XCTAssertEqual(members[0]["name"] as? String, "John")
        XCTAssertEqual(members[0]["profile_avatar_color"] as? String, "#FF5733")
    }
    
    func testBulkExpenseDTO_Encoding() throws {
        let split = BulkSplitDTO(id: "split-1", member_id: "member-1", amount: 10.0, is_settled: false)
        let participant = BulkParticipantDTO(member_id: "member-1", name: "John")
        let subexpense = BulkSubexpenseDTO(id: "sub-1", amount: 5.0)
        let expense = BulkExpenseDTO(
            id: "expense-1",
            group_id: "group-1",
            description: "Dinner",
            date: 1625097600000,
            total_amount: 20.0,
            paid_by_member_id: "member-1",
            involved_member_ids: ["member-1"],
            splits: [split],
            is_settled: false,
            participant_member_ids: ["member-1"],
            participants: [participant],
            subexpenses: [subexpense]
        )
        
        let data = try JSONEncoder().encode(expense)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        
        XCTAssertEqual(json["id"] as? String, "expense-1")
        XCTAssertEqual(json["group_id"] as? String, "group-1")
        XCTAssertEqual(json["description"] as? String, "Dinner")
        XCTAssertEqual(json["date"] as? Double, 1625097600000)
        XCTAssertEqual(json["total_amount"] as? Double, 20.0)
        XCTAssertEqual(json["paid_by_member_id"] as? String, "member-1")
        XCTAssertEqual(json["is_settled"] as? Bool, false)
        XCTAssertEqual(json["involved_member_ids"] as? [String], ["member-1"])
        XCTAssertEqual(json["participant_member_ids"] as? [String], ["member-1"])
        
        let splits = try XCTUnwrap(json["splits"] as? [[String: Any]])
        XCTAssertEqual(splits[0]["id"] as? String, "split-1")
        XCTAssertEqual(splits[0]["member_id"] as? String, "member-1")
        XCTAssertEqual(splits[0]["amount"] as? Double, 10.0)
        XCTAssertEqual(splits[0]["is_settled"] as? Bool, false)

        let participants = try XCTUnwrap(json["participants"] as? [[String: Any]])
        XCTAssertEqual(participants[0]["member_id"] as? String, "member-1")
        XCTAssertEqual(participants[0]["name"] as? String, "John")
        
        let subexpenses = try XCTUnwrap(json["subexpenses"] as? [[String: Any]])
        XCTAssertEqual(subexpenses[0]["id"] as? String, "sub-1")
        XCTAssertEqual(subexpenses[0]["amount"] as? Double, 5.0)
    }

    func testBulkImportRequest_Encoding() throws {
        let friend = BulkFriendDTO(member_id: "m1", name: "N1", profile_avatar_color: "c1")
        let group = BulkGroupDTO(id: "g1", name: "G1", members: [], is_direct: true)
        let expense = BulkExpenseDTO(
            id: "e1",
            group_id: "g1",
            description: "D",
            date: 0,
            total_amount: 0,
            paid_by_member_id: "m1",
            involved_member_ids: ["m1"],
            splits: [BulkSplitDTO(id: "s1", member_id: "m1", amount: 0, is_settled: true)],
            is_settled: true,
            participant_member_ids: ["m1"],
            participants: [BulkParticipantDTO(member_id: "m1", name: "N1")],
            subexpenses: nil
        )
        let request = BulkImportRequest(friends: [friend], groups: [group], expenses: [expense])

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["friends"])
        XCTAssertNotNil(json["groups"])
        XCTAssertNotNil(json["expenses"])
    }
}
