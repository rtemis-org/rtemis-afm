// GenerationGate.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

/// A counting semaphore for Swift concurrency: at most `limit` generations
/// run at once; the rest wait their turn.
///
/// The framework can run concurrent sessions, but one Mac cannot usefully
/// run many at once, and stacking them only makes every reply slower. Excess
/// requests are queued, not refused — the client sees a slower first token,
/// never a `429`.
///
/// For a developer new to Swift: an `actor` is a class whose state can only
/// be touched by one task at a time; the compiler enforces it, so there is
/// no lock to forget. `CheckedContinuation` is how an `async` function
/// suspends until someone else resumes it — here, the waiter parks until a
/// slot frees up. The cancellation handler makes sure a request that goes
/// away while queued (client disconnected) does not hold a place in line.
public actor GenerationGate {
    private let limit: Int
    private var inUse = 0
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    public init(limit: Int) {
        precondition(limit >= 1, "GenerationGate needs at least one slot")
        self.limit = limit
    }

    /// Waits for a slot. Throws `CancellationError` if the task is cancelled
    /// while waiting. Every successful `acquire` must be paired with a
    /// `release`.
    public func acquire() async throws {
        if inUse < limit {
            inUse += 1
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await self.park(id: id)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Suspends the caller until `release` or `cancelWaiter` resumes it.
    private func park(id: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // A cancellation that raced ahead of us is honored right away.
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }
    }

    /// Frees a slot and wakes the longest-waiting request, if any.
    public func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            // The slot passes straight to the waiter; `inUse` stays the same.
            next.continuation.resume()
        } else {
            inUse -= 1
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Slots currently taken (for tests and the verbose log).
    public var active: Int { inUse }

    /// Requests waiting for a slot.
    public var queued: Int { waiters.count }
}
