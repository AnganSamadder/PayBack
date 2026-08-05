import XCTest
@testable import PayBack

final class CancellableAsyncStreamTests: XCTestCase {
    private actor CancellationProbe {
        private(set) var wasCancelled = false

        func markCancelled() {
            wasCancelled = true
        }
    }

    func testCancellingConsumerCancelsProducerTask() async throws {
        let probe = CancellationProbe()
        let stream: AsyncThrowingStream<Int, Error> = makeCancellableAsyncThrowingStream { continuation in
            do {
                try await Task.sleep(for: .seconds(30))
                continuation.finish()
            } catch is CancellationError {
                await probe.markCancelled()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let consumer = Task {
            for try await _ in stream {}
        }
        await Task.yield()
        consumer.cancel()

        for _ in 0..<100 {
            if await probe.wasCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let wasCancelled = await probe.wasCancelled
        XCTAssertTrue(wasCancelled)
    }
}
