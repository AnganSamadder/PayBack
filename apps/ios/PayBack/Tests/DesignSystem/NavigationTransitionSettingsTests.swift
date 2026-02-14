import XCTest
import SwiftUI
@testable import PayBack

final class NavigationTransitionSettingsTests: XCTestCase {

    func testDisabledStyle() {
        let style = NavigationTransitionStyle.disabled

        XCTAssertNil(style.animation)
        XCTAssertFalse(style.allowsInteractiveDismiss)
        XCTAssertEqual(style.backgroundRestingOpacity, 1)
        XCTAssertEqual(style.backgroundActiveOpacity, 1)
    }

    func testInteractiveStyle() {
        let style = NavigationTransitionStyle.interactive

        XCTAssertNotNil(style.animation)
        XCTAssertTrue(style.allowsInteractiveDismiss)
        XCTAssertEqual(style.backgroundRestingOpacity, 0.2)
        XCTAssertEqual(style.backgroundActiveOpacity, 1)
    }

    func testNavigationTransitionSettingsReturnsDisabled() {
        let style = NavigationTransitionSettings.style

        XCTAssertNil(style.animation)
        XCTAssertFalse(style.allowsInteractiveDismiss)
    }

    func testDisabledStyleHasIdentityTransition() {
        let style = NavigationTransitionStyle.disabled

        XCTAssertEqual(style.backgroundRestingOpacity, style.backgroundActiveOpacity)
    }

    func testInteractiveStyleHasDifferentOpacities() {
        let style = NavigationTransitionStyle.interactive

        XCTAssertNotEqual(style.backgroundRestingOpacity, style.backgroundActiveOpacity)
        XCTAssertLessThan(style.backgroundRestingOpacity, style.backgroundActiveOpacity)
    }
}
