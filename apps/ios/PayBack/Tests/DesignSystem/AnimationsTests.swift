import XCTest
import SwiftUI
@testable import PayBack

final class AnimationsTests: XCTestCase {
	func testQuickAnimation() {
		let animation = AppAnimation.quick
		XCTAssertNotNil(animation)
	}

	func testSpringyAnimation() {
		let animation = AppAnimation.springy
		XCTAssertNotNil(animation)
	}

	func testFadeAnimation() {
		let animation = AppAnimation.fade
		XCTAssertNotNil(animation)
	}

	func testAnimationsAreDifferent() {
		XCTAssertNotEqual(String(describing: AppAnimation.quick), String(describing: AppAnimation.springy))
		XCTAssertNotEqual(String(describing: AppAnimation.quick), String(describing: AppAnimation.fade))
		XCTAssertNotEqual(String(describing: AppAnimation.springy), String(describing: AppAnimation.fade))
	}
}
