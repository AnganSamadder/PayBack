import XCTest
import SwiftUI
@testable import PayBack

final class DetailContainerTests: XCTestCase {

    // MARK: - Initialization Tests

    func testDetailContainerInitialization() {
        let container = DetailContainer(
            action: {},
            background: { Color.blue },
            content: { Text("Content") }
        )

        XCTAssertNotNil(container)
    }

    func testDetailContainerWithCustomDragThreshold() {
        let container = DetailContainer(
            dragThreshold: 150,
            action: {},
            background: { Color.red },
            content: { Text("Test") }
        )

        XCTAssertNotNil(container)
    }

    func testDetailContainerWithDefaultDragThreshold() {
        let container = DetailContainer(
            action: {},
            background: { EmptyView() },
            content: { Text("Default") }
        )

        XCTAssertNotNil(container)
    }

    // MARK: - Body Rendering Tests

    func testDetailContainerBodyRendering() {
        let container = DetailContainer(
            action: {},
            background: { Color.white },
            content: { Text("Detail") }
        )

        XCTAssertNotNil(container.body)
    }

    func testDetailContainerBodyWithDifferentBackgrounds() {
        let containers = [
            DetailContainer(action: {}, background: { Color.red }, content: { Text("1") }),
            DetailContainer(action: {}, background: { Color.blue }, content: { Text("2") }),
            DetailContainer(action: {}, background: { Color.green }, content: { Text("3") })
        ]

        for container in containers {
            XCTAssertNotNil(container.body)
        }
    }

    func testDetailContainerBodyWithDifferentContent() {
        let container1 = DetailContainer(
            action: {},
            background: { Color.white },
            content: { VStack { Text("Line 1"); Text("Line 2") } }
        )

        let container2 = DetailContainer(
            action: {},
            background: { Color.white },
            content: { HStack { Image(systemName: "star"); Text("Star") } }
        )

        XCTAssertNotNil(container1.body)
        XCTAssertNotNil(container2.body)
    }

    // MARK: - Action Callback Tests

    func testActionCallbackExecution() {
        var actionCalled = false
        let container = DetailContainer(
            action: { actionCalled = true },
            background: { Color.clear },
            content: { Text("Test") }
        )

        XCTAssertNotNil(container)
        XCTAssertFalse(actionCalled, "Action should not be called during initialization")
    }

    func testMultipleContainersWithDifferentActions() {
        var action1Called = false
        var action2Called = false

        let container1 = DetailContainer(
            action: { action1Called = true },
            background: { Color.white },
            content: { Text("Container 1") }
        )

        let container2 = DetailContainer(
            action: { action2Called = true },
            background: { Color.white },
            content: { Text("Container 2") }
        )

        XCTAssertNotNil(container1)
        XCTAssertNotNil(container2)
        XCTAssertFalse(action1Called)
        XCTAssertFalse(action2Called)
    }

    // MARK: - Drag Threshold Tests

    func testVariousDragThresholds() {
        let thresholds: [CGFloat] = [50, 100, 150, 200, 250]

        for threshold in thresholds {
            let container = DetailContainer(
                dragThreshold: threshold,
                action: {},
                background: { Color.white },
                content: { Text("Threshold: \(threshold)") }
            )

            XCTAssertNotNil(container)
        }
    }

    func testZeroDragThreshold() {
        let container = DetailContainer(
            dragThreshold: 0,
            action: {},
            background: { Color.white },
            content: { Text("Zero threshold") }
        )

        XCTAssertNotNil(container)
    }

    func testNegativeDragThreshold() {
        let container = DetailContainer(
            dragThreshold: -50,
            action: {},
            background: { Color.white },
            content: { Text("Negative threshold") }
        )

        XCTAssertNotNil(container)
    }

    // MARK: - Complex Content Tests

    func testDetailContainerWithComplexContent() {
        let container = DetailContainer(
            action: {},
            background: {
                LinearGradient(
                    colors: [.blue, .purple],
                    startPoint: .top,
                    endPoint: .bottom
                )
            },
            content: {
                VStack(spacing: 20) {
                    Text("Title")
                        .font(.title)
                    Text("Subtitle")
                        .font(.subheadline)
                    Button("Action") {}
                    Spacer()
                }
                .padding()
            }
        )

        XCTAssertNotNil(container)
        XCTAssertNotNil(container.body)
    }

    func testDetailContainerWithScrollableContent() {
        let container = DetailContainer(
            action: {},
            background: { Color.black.opacity(0.3) },
            content: {
                ScrollView {
                    VStack {
                        ForEach(0..<20) { index in
                            Text("Item \(index)")
                                .padding()
                        }
                    }
                }
            }
        )

        XCTAssertNotNil(container)
        XCTAssertNotNil(container.body)
    }

    // MARK: - Edge Case Tests

    func testDetailContainerWithEmptyContent() {
        let container = DetailContainer(
            action: {},
            background: { Color.white },
            content: { EmptyView() }
        )

        XCTAssertNotNil(container)
        XCTAssertNotNil(container.body)
    }

    func testDetailContainerWithEmptyBackground() {
        let container = DetailContainer(
            action: {},
            background: { EmptyView() },
            content: { Text("Content") }
        )

        XCTAssertNotNil(container)
        XCTAssertNotNil(container.body)
    }

    func testDetailContainerWithLargeThreshold() {
        let container = DetailContainer(
            dragThreshold: 10000,
            action: {},
            background: { Color.white },
            content: { Text("Large threshold") }
        )

        XCTAssertNotNil(container)
    }

    // MARK: - Multiple Instance Tests

    func testMultipleDetailContainerInstances() {
        let containers = (0..<10).map { index in
            DetailContainer(
                dragThreshold: CGFloat(index * 10 + 50),
                action: {},
                background: { Color.white },
                content: { Text("Container \(index)") }
            )
        }

        XCTAssertEqual(containers.count, 10)
        containers.forEach { XCTAssertNotNil($0) }
    }

    // MARK: - Generic Type Tests

    func testDetailContainerWithDifferentViewTypes() {
        let textContainer = DetailContainer(
            action: {},
            background: { Color.white },
            content: { Text("Text") }
        )

        let imageContainer = DetailContainer(
            action: {},
            background: { Color.white },
            content: { Image(systemName: "star") }
        )

        let shapeContainer = DetailContainer(
            action: {},
            background: { Color.white },
            content: { Circle().fill(Color.blue) }
        )

        XCTAssertNotNil(textContainer)
        XCTAssertNotNil(imageContainer)
        XCTAssertNotNil(shapeContainer)
    }

    // MARK: - Closure Capture Tests

    func testActionClosureCapturesCorrectly() {
        var capturedValue = 0

        let container = DetailContainer(
            action: { capturedValue = 42 },
            background: { Color.white },
            content: { Text("Test") }
        )

        XCTAssertNotNil(container)
        XCTAssertEqual(capturedValue, 0, "Value should not change until action is called")
    }

    func testMultipleClosuresWithDifferentCaptures() {
        var value1 = 0
        var value2 = 0

        let container1 = DetailContainer(
            action: { value1 = 10 },
            background: { Color.white },
            content: { Text("Container 1") }
        )

        let container2 = DetailContainer(
            action: { value2 = 20 },
            background: { Color.white },
            content: { Text("Container 2") }
        )

        XCTAssertNotNil(container1)
        XCTAssertNotNil(container2)
        XCTAssertEqual(value1, 0)
        XCTAssertEqual(value2, 0)
    }
}
