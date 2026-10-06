import XCTest
import NetworkingCore

extension Task where Failure == any Error {
    /// The task's result, or `nil` when the task has not finished within `timeout`.
    /// Unlike `await task.result`, this returns even if the task never finishes.
    func result(timeout: Duration) async -> Result<Success, any Error>? {
        let once = ResumeOnce<Result<Success, any Error>?>()
        return await withCheckedContinuation { continuation in
            Task<Void, Never> { once.resume(continuation, returning: await self.result) }
            Task<Void, Never> {
                try? await Task<Never, Never>.sleep(for: timeout)
                once.resume(continuation, returning: nil)
            }
        }
    }
}

/// Resumes a continuation from whichever of several racing tasks gets there first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Value, Never>, returning value: Value) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        if first { continuation.resume(returning: value) }
    }
}

/// Asserts that `outcome`, from `Task.result(timeout:)`, is a failure with `APIError.cancelled`.
func XCTAssertCancelled<Success>(_ outcome: Result<Success, any Error>?,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
    switch outcome {
    case .failure(APIError.cancelled)?:
        break
    case nil:
        XCTFail("Expected APIError.cancelled; the task did not finish", file: file, line: line)
    default:
        XCTFail("Expected APIError.cancelled, got \(String(describing: outcome))", file: file, line: line)
    }
}
