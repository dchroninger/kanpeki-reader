import Foundation
import Synchronization

/// Fan-out of values to any number of `AsyncStream` subscribers. Subscription
/// is synchronous, so a value sent right after `stream()` returns is seen.
public final class Broadcaster<T: Sendable>: Sendable {
    private let subs = Mutex<[UUID: AsyncStream<T>.Continuation]>([:])
    public init() {}

    public func stream() -> AsyncStream<T> {
        let (s, c) = AsyncStream<T>.makeStream()
        let id = UUID()
        subs.withLock { $0[id] = c }
        c.onTermination = { _ in self.subs.withLock { $0[id] = nil } }
        return s
    }

    public func send(_ v: T) {
        subs.withLock { for c in $0.values { c.yield(v) } }
    }
}
