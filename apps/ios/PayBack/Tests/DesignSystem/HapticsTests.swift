import XCTest
@testable import PayBack

final class HapticsTests: XCTestCase {

    func test_hapticImpact_light_doesNotCrash() {
        // Given/When/Then
        Haptics.impact(.light)
        // No crash is success
    }

    func test_hapticImpact_medium_doesNotCrash() {
        // Given/When/Then
        Haptics.impact(.medium)
        // No crash is success
    }

    func test_hapticImpact_heavy_doesNotCrash() {
        // Given/When/Then
        Haptics.impact(.heavy)
        // No crash is success
    }

    func test_hapticImpact_soft_doesNotCrash() {
        // Given/When/Then
        Haptics.impact(.soft)
        // No crash is success
    }

    func test_hapticImpact_rigid_doesNotCrash() {
        // Given/When/Then
        Haptics.impact(.rigid)
        // No crash is success
    }

    func test_hapticNotification_success_doesNotCrash() {
        // Given/When/Then
        Haptics.notify(.success)
        // No crash is success
    }

    func test_hapticNotification_warning_doesNotCrash() {
        // Given/When/Then
        Haptics.notify(.warning)
        // No crash is success
    }

    func test_hapticNotification_error_doesNotCrash() {
        // Given/When/Then
        Haptics.notify(.error)
        // No crash is success
    }

    func test_hapticSelection_doesNotCrash() {
        // Given/When/Then
        Haptics.selection()
        // No crash is success
    }

    func test_multipleSequentialHaptics_doesNotCrash() {
        // Given/When/Then
        Haptics.impact(.light)
        Haptics.selection()
        Haptics.notify(.success)
        Haptics.impact(.heavy)
        // No crash is success
    }

    func test_rapidHapticCalls_doesNotCrash() {
        // Given/When/Then
        for _ in 1...10 {
            Haptics.impact(.light)
        }
        // No crash is success
    }
}
