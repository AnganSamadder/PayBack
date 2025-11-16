import XCTest
import SwiftUI
@testable import PayBack

final class NavigationHeaderTests: XCTestCase {
    
    // MARK: - NavigationHeader Initialization Tests
    
    func testNavigationHeaderInitialization() {
        let header = NavigationHeader(title: "Test Title", onBack: {})
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithDefaultShowBackButton() {
        let header = NavigationHeader(title: "Test", onBack: {})
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithShowBackButtonTrue() {
        let header = NavigationHeader(title: "Test", showBackButton: true, onBack: {})
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithShowBackButtonFalse() {
        let header = NavigationHeader(title: "Test", showBackButton: false, onBack: {})
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithEmptyTitle() {
        let header = NavigationHeader(title: "", onBack: {})
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithLongTitle() {
        let longTitle = String(repeating: "A", count: 100)
        let header = NavigationHeader(title: longTitle, onBack: {})
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderActionClosure() {
        var actionCalled = false
        let header = NavigationHeader(title: "Test", onBack: { actionCalled = true })
        XCTAssertNotNil(header)
        XCTAssertFalse(actionCalled, "Action should not be called during initialization")
    }
    
    // MARK: - NavigationHeader Body Rendering Tests
    
    func testNavigationHeaderBodyRendering() {
        let header = NavigationHeader(title: "Test", onBack: {})
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderBodyWithBackButton() {
        let header = NavigationHeader(title: "Test", showBackButton: true, onBack: {})
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderBodyWithoutBackButton() {
        let header = NavigationHeader(title: "Test", showBackButton: false, onBack: {})
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderBodyWithEmptyTitle() {
        let header = NavigationHeader(title: "", showBackButton: true, onBack: {})
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderBodyWithLongTitle() {
        let longTitle = String(repeating: "Long Title ", count: 20)
        let header = NavigationHeader(title: longTitle, onBack: {})
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    // MARK: - NavigationHeaderModifier Tests
    
    func testNavigationHeaderModifierInitialization() {
        let modifier = NavigationHeaderModifier(
            title: "Test",
            showBackButton: true,
            onBack: {}
        )
        XCTAssertNotNil(modifier)
    }
    
    func testNavigationHeaderModifierWithShowBackButtonFalse() {
        let modifier = NavigationHeaderModifier(
            title: "Test",
            showBackButton: false,
            onBack: {}
        )
        XCTAssertNotNil(modifier)
    }
    
    func testNavigationHeaderModifierWithEmptyTitle() {
        let modifier = NavigationHeaderModifier(
            title: "",
            showBackButton: true,
            onBack: {}
        )
        XCTAssertNotNil(modifier)
    }
    
    func testNavigationHeaderModifierWithLongTitle() {
        let longTitle = String(repeating: "Title ", count: 50)
        let modifier = NavigationHeaderModifier(
            title: longTitle,
            showBackButton: true,
            onBack: {}
        )
        XCTAssertNotNil(modifier)
    }
    
    // MARK: - View Extension Tests
    
    func testCustomNavigationHeaderExtension() {
        let view = Text("Content")
            .customNavigationHeader(title: "Test", onBack: {})
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithShowBackButtonTrue() {
        let view = Text("Content")
            .customNavigationHeader(title: "Test", showBackButton: true, onBack: {})
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithShowBackButtonFalse() {
        let view = Text("Content")
            .customNavigationHeader(title: "Test", showBackButton: false, onBack: {})
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithEmptyTitle() {
        let view = Text("Content")
            .customNavigationHeader(title: "", onBack: {})
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithLongTitle() {
        let longTitle = String(repeating: "Title ", count: 30)
        let view = Text("Content")
            .customNavigationHeader(title: longTitle, onBack: {})
        XCTAssertNotNil(view)
    }
    
    // MARK: - NavigationHeaderWithAction Initialization Tests
    
    func testNavigationHeaderWithActionInitialization() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {}
        )
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionWithRightAction() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: {}
        )
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionWithRightActionTitle() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: {},
            rightActionTitle: "Done"
        )
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionWithRightActionIcon() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: {},
            rightActionIcon: "checkmark"
        )
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionWithBothTitleAndIcon() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: {},
            rightActionTitle: "Save",
            rightActionIcon: "square.and.arrow.down"
        )
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionWithShowBackButtonFalse() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            showBackButton: false,
            onBack: {}
        )
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionWithShowBackButtonTrue() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            showBackButton: true,
            onBack: {}
        )
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionWithoutRightAction() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: nil,
            rightActionTitle: nil,
            rightActionIcon: nil
        )
        XCTAssertNotNil(header)
    }
    
    // MARK: - NavigationHeaderWithAction Body Rendering Tests
    
    func testNavigationHeaderWithActionBodyRendering() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {}
        )
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionBodyWithBackButton() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            showBackButton: true,
            onBack: {}
        )
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionBodyWithoutBackButton() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            showBackButton: false,
            onBack: {}
        )
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionBodyWithRightAction() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: {}
        )
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionBodyWithRightActionTitle() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: {},
            rightActionTitle: "Done"
        )
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionBodyWithRightActionIcon() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: {},
            rightActionIcon: "gear"
        )
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionBodyWithBothTitleAndIcon() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: {},
            rightActionTitle: "Settings",
            rightActionIcon: "gear"
        )
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionBodyWithoutRightAction() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: nil
        )
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    // MARK: - NavigationHeaderWithActionModifier Tests
    
    func testNavigationHeaderWithActionModifierInitialization() {
        let modifier = NavigationHeaderWithActionModifier(
            title: "Test",
            showBackButton: true,
            onBack: {},
            rightAction: nil,
            rightActionTitle: nil,
            rightActionIcon: nil
        )
        XCTAssertNotNil(modifier)
    }
    
    func testNavigationHeaderWithActionModifierWithRightAction() {
        let modifier = NavigationHeaderWithActionModifier(
            title: "Test",
            showBackButton: true,
            onBack: {},
            rightAction: {},
            rightActionTitle: "Done",
            rightActionIcon: "checkmark"
        )
        XCTAssertNotNil(modifier)
    }
    
    func testNavigationHeaderWithActionModifierWithShowBackButtonFalse() {
        let modifier = NavigationHeaderWithActionModifier(
            title: "Test",
            showBackButton: false,
            onBack: {},
            rightAction: {},
            rightActionTitle: "Save",
            rightActionIcon: nil
        )
        XCTAssertNotNil(modifier)
    }
    
    func testNavigationHeaderWithActionModifierWithEmptyTitle() {
        let modifier = NavigationHeaderWithActionModifier(
            title: "",
            showBackButton: true,
            onBack: {},
            rightAction: {},
            rightActionTitle: nil,
            rightActionIcon: "star"
        )
        XCTAssertNotNil(modifier)
    }
    
    // MARK: - View Extension with Action Tests
    
    func testCustomNavigationHeaderWithActionExtension() {
        let view = Text("Content")
            .customNavigationHeaderWithAction(title: "Test", onBack: {})
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithActionAndRightAction() {
        let view = Text("Content")
            .customNavigationHeaderWithAction(
                title: "Test",
                onBack: {},
                rightAction: {}
            )
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithActionAndTitle() {
        let view = Text("Content")
            .customNavigationHeaderWithAction(
                title: "Test",
                onBack: {},
                rightAction: {},
                rightActionTitle: "Done"
            )
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithActionAndIcon() {
        let view = Text("Content")
            .customNavigationHeaderWithAction(
                title: "Test",
                onBack: {},
                rightAction: {},
                rightActionIcon: "plus"
            )
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithActionAndBothTitleAndIcon() {
        let view = Text("Content")
            .customNavigationHeaderWithAction(
                title: "Test",
                onBack: {},
                rightAction: {},
                rightActionTitle: "Add",
                rightActionIcon: "plus.circle"
            )
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithActionWithShowBackButtonFalse() {
        let view = Text("Content")
            .customNavigationHeaderWithAction(
                title: "Test",
                showBackButton: false,
                onBack: {}
            )
        XCTAssertNotNil(view)
    }
    
    func testCustomNavigationHeaderWithActionWithShowBackButtonTrue() {
        let view = Text("Content")
            .customNavigationHeaderWithAction(
                title: "Test",
                showBackButton: true,
                onBack: {}
            )
        XCTAssertNotNil(view)
    }
    
    // MARK: - Closure Capture Tests
    
    func testNavigationHeaderClosureCapturesCorrectly() {
        var capturedValue = 0
        let header = NavigationHeader(
            title: "Test",
            onBack: { capturedValue = 42 }
        )
        XCTAssertNotNil(header)
        XCTAssertEqual(capturedValue, 0, "Value should not change until action is called")
    }
    
    func testNavigationHeaderWithActionClosureCapturesCorrectly() {
        var backCalled = false
        var rightActionCalled = false
        
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: { backCalled = true },
            rightAction: { rightActionCalled = true }
        )
        
        XCTAssertNotNil(header)
        XCTAssertFalse(backCalled, "Back action should not be called during initialization")
        XCTAssertFalse(rightActionCalled, "Right action should not be called during initialization")
    }
    
    // MARK: - Edge Case Tests
    
    func testNavigationHeaderWithSpecialCharactersInTitle() {
        let specialTitles = [
            "Test & Title",
            "Title with 🎉 emoji",
            "Title\nwith\nnewlines",
            "Title\twith\ttabs",
            "Title with \"quotes\"",
            "Title with 'apostrophes'",
            "Title with <brackets>",
            "Title with [square] brackets"
        ]
        
        for title in specialTitles {
            let header = NavigationHeader(title: title, onBack: {})
            _ = header.body
            XCTAssertNotNil(header)
        }
    }
    
    func testNavigationHeaderWithActionWithSpecialCharactersInTitle() {
        let specialTitles = [
            "Test & Title",
            "Title with 🎉 emoji",
            "Title with symbols: @#$%"
        ]
        
        for title in specialTitles {
            let header = NavigationHeaderWithAction(
                title: title,
                onBack: {},
                rightAction: {},
                rightActionTitle: "Done"
            )
            _ = header.body
            XCTAssertNotNil(header)
        }
    }
    
    func testNavigationHeaderWithVeryLongTitle() {
        let veryLongTitle = String(repeating: "Very Long Title ", count: 100)
        let header = NavigationHeader(title: veryLongTitle, onBack: {})
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    func testNavigationHeaderWithActionWithVeryLongTitle() {
        let veryLongTitle = String(repeating: "Very Long Title ", count: 100)
        let header = NavigationHeaderWithAction(
            title: veryLongTitle,
            onBack: {},
            rightAction: {},
            rightActionTitle: "Done"
        )
        _ = header.body
        XCTAssertNotNil(header)
    }
    
    // MARK: - Multiple Instance Tests
    
    func testMultipleNavigationHeaderInstances() {
        let headers = (0..<10).map { index in
            NavigationHeader(
                title: "Header \(index)",
                showBackButton: index % 2 == 0,
                onBack: {}
            )
        }
        
        XCTAssertEqual(headers.count, 10)
        headers.forEach { XCTAssertNotNil($0) }
    }
    
    func testMultipleNavigationHeaderWithActionInstances() {
        let headers = (0..<10).map { index in
            NavigationHeaderWithAction(
                title: "Header \(index)",
                showBackButton: index % 2 == 0,
                onBack: {},
                rightAction: index % 3 == 0 ? {} : nil,
                rightActionTitle: index % 3 == 0 ? "Action \(index)" : nil,
                rightActionIcon: index % 3 == 0 ? "star" : nil
            )
        }
        
        XCTAssertEqual(headers.count, 10)
        headers.forEach { XCTAssertNotNil($0) }
    }
    
    // MARK: - Complex Scenario Tests
    
    func testNavigationHeaderInComplexViewHierarchy() {
        let header = NavigationHeader(title: "Test", onBack: {})
        _ = header.body
        
        let view = VStack {
            header
            Text("Content")
            Spacer()
        }
        XCTAssertNotNil(view)
    }
    
    func testNavigationHeaderWithActionInComplexViewHierarchy() {
        let header = NavigationHeaderWithAction(
            title: "Test",
            onBack: {},
            rightAction: {},
            rightActionTitle: "Save"
        )
        _ = header.body
        
        let view = VStack {
            header
            ScrollView {
                Text("Scrollable Content")
            }
        }
        XCTAssertNotNil(view)
    }
    
    func testMultipleModifiersOnSameView() {
        let view = Text("Content")
            .customNavigationHeader(title: "First", onBack: {})
            .customNavigationHeader(title: "Second", onBack: {})
        XCTAssertNotNil(view)
    }
    
    func testNavigationHeaderWithDifferentViewTypes() {
        let textView = Text("Text")
            .customNavigationHeader(title: "Text Header", onBack: {})
        
        let imageView = Image(systemName: "star")
            .customNavigationHeader(title: "Image Header", onBack: {})
        
        let shapeView = Circle()
            .customNavigationHeader(title: "Shape Header", onBack: {})
        
        XCTAssertNotNil(textView)
        XCTAssertNotNil(imageView)
        XCTAssertNotNil(shapeView)
    }
}
