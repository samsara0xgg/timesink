import Foundation
import os

/// Consecutive write failures across the tracker's write paths. Degraded once
/// `threshold` writes in a row failed; the next success clears it.
public final class WriteHealth: Sendable {
    public struct Degraded: Equatable, Sendable {
        public let failure: StorageFailure
        public let lastSuccess: Date?
    }

    private struct State {
        var failures = 0
        var last: StorageFailure = .other
        var lastSuccess: Date?
        var onChange: (@Sendable () -> Void)?
    }

    private let threshold: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(threshold: Int = 2) { self.threshold = threshold }

    /// Called (on whatever thread the write ran) whenever `degraded` changes.
    public func observe(_ onChange: @escaping @Sendable () -> Void) {
        state.withLock { $0.onChange = onChange }
    }

    public var consecutiveFailures: Int { state.withLock { $0.failures } }

    public var degraded: Degraded? { state.withLock { degraded($0) } }

    public func succeeded(at date: Date = Date()) {
        let (changed, notify) = state.withLock { s -> (Bool, (@Sendable () -> Void)?) in
            let before = degraded(s)
            s.failures = 0
            s.lastSuccess = date
            return (before != nil, s.onChange)
        }
        if changed { notify?() }
    }

    public func failed(_ error: Error) {
        let (changed, notify) = state.withLock { s -> (Bool, (@Sendable () -> Void)?) in
            let before = degraded(s)
            s.failures += 1
            s.last = StorageFailure.classify(error)
            return (before != degraded(s), s.onChange)
        }
        if changed { notify?() }
    }

    private func degraded(_ s: State) -> Degraded? {
        s.failures >= threshold ? Degraded(failure: s.last, lastSuccess: s.lastSuccess) : nil
    }
}
