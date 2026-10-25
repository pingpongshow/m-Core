import Foundation

public enum RemoteRequestError: Error, Equatable, Sendable {
    case notConnected
    case unknownNode
    case timedOut
}

/// Pairs requests with the push that answers them, keyed by node prefix or request tag.
@MainActor
final class PushWaiter<Value: Sendable> {
    private struct Waiting {
        let id: UInt64
        let continuation: CheckedContinuation<Value, Error>
    }

    private var waiting: [String: Waiting] = [:]
    private var nextID: UInt64 = 0

    func wait(for key: String, timeout: Duration) async throws -> Value {
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            waiting.removeValue(forKey: key)?.continuation.resume(throwing: RemoteRequestError.timedOut)
            waiting[key] = Waiting(id: id, continuation: continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                // Only this wait's own timeout may end it; an earlier request to the same key must not.
                self?.timeOut(key, id: id)
            }
        }
    }

    func resolve(_ key: String, with result: Result<Value, Error>) {
        waiting.removeValue(forKey: key)?.continuation.resume(with: result)
    }

    private func timeOut(_ key: String, id: UInt64) {
        guard waiting[key]?.id == id else { return }
        resolve(key, with: .failure(RemoteRequestError.timedOut))
    }

    func cancelAll() {
        for entry in waiting.values { entry.continuation.resume(throwing: RemoteRequestError.notConnected) }
        waiting.removeAll()
    }

    var isWaiting: Bool { !waiting.isEmpty }
}

/// Generous timeout for a mesh round trip, from the radio's estimate.
func meshTimeout(estimatedMs: UInt32, minimum: Duration = .seconds(15)) -> Duration {
    max(minimum, .milliseconds(Int(estimatedMs) * 3))
}
