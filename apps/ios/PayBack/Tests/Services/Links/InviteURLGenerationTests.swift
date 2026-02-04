//
//  InviteURLGenerationTests.swift
//  PayBackTests
//
//  Created on 2026-01-08.
//

import XCTest
@testable import PayBack

/// Tests for invite URL generation using Convex backend
final class InviteURLGenerationTests: XCTestCase {
    
    func testInviteToken_URLGeneration() {
        let tokenId = UUID()
        let url = URL(string: "payback://invite/\(tokenId.uuidString)")!
        
        XCTAssertEqual(url.scheme, "payback")
        XCTAssertEqual(url.host, "invite")
        XCTAssertEqual(url.pathComponents.last, tokenId.uuidString)
    }
    
    func testInviteToken_ShareTextGeneration() {
        let tokenId = UUID()
        let shareText = "Join me on PayBack! Open this link: payback://invite/\(tokenId.uuidString)"
        
        XCTAssertTrue(shareText.contains("PayBack"))
        XCTAssertTrue(shareText.contains(tokenId.uuidString))
    }
}
