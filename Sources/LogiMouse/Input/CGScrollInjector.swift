import CoreGraphics
import Foundation

struct CGScrollOutputBatch: Equatable, Sendable {
    let vertical: Int
    let horizontal: Int

    var isEmpty: Bool {
        vertical == 0 && horizontal == 0
    }
}

/// Bounded accumulator used between HID++ input and Quartz event posting.
/// Keeping this value type separate makes the back-pressure policy explicit and
/// testable without creating a CoreGraphics event source.
struct CGScrollOutputAccumulator: Sendable {
    static let maximumPendingPixels = 8_192

    private(set) var vertical = 0
    private(set) var horizontal = 0

    mutating func append(vertical: Int, horizontal: Int) {
        self.vertical = Self.saturatedAdd(self.vertical, vertical)
        self.horizontal = Self.saturatedAdd(self.horizontal, horizontal)
    }

    mutating func take() -> CGScrollOutputBatch {
        let batch = CGScrollOutputBatch(vertical: vertical, horizontal: horizontal)
        vertical = 0
        horizontal = 0
        return batch
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow {
            return rhs < 0 ? -maximumPendingPixels : maximumPendingPixels
        }
        return max(-maximumPendingPixels, min(maximumPendingPixels, sum))
    }
}

final class CGScrollInjector {
    static let shared = CGScrollInjector()
    /// Marks events synthesized by this process so the suppressing event tap
    /// can pass them without creating an injection loop.
    static let eventMarker: Int64 = 0x4d58_5343_524f_4c4c
    /// `.hidSystemState` posts at the same system layer as physical HID input,
    /// making the result visible to every foreground application. The source
    /// is explicitly configured so posting does not suppress local pointer
    /// events for CoreGraphics' default 250 ms interval.
    private static let source = CGEventSourceSafety.makeHIDSystemSource()
    /// CGEvent creation/posting is an IPC path. Keep it away from AppKit's main
    /// run loop, where the global event tap and pointer/UI work are serviced.
    private let queue: DispatchQueue
    private let send: (CGScrollOutputBatch) -> Void
    private let stateLock = NSLock()
    private var pending = CGScrollOutputAccumulator()
    private var drainScheduled = false
    private let outputInterval: DispatchTimeInterval = .milliseconds(1)

    init(queue: DispatchQueue = DispatchQueue(
        label: "dev.logi-mouse.cg-scroll-output",
        // A bounded, coalescing output queue should never outrank the system's
        // native pointer path. One 1 ms turn still keeps wheel output responsive
        // while giving physical mouse movement scheduling room between posts.
        qos: .utility
    ), send: @escaping (CGScrollOutputBatch) -> Void = CGScrollInjector.postNow) {
        self.queue = queue
        self.send = send
    }

    func post(pixelDelta: Int) {
        post(verticalPixelDelta: pixelDelta, horizontalPixelDelta: 0)
    }

    func postHorizontal(pixelDelta: Int) {
        post(verticalPixelDelta: 0, horizontalPixelDelta: pixelDelta)
    }

    /// Drops output that was queued before a mode/lifecycle transition. A late
    /// synthetic scroll event after native mode has been restored is worse than
    /// losing one pending pixel, because it can move the foreground app after
    /// the user has already disabled smooth scrolling.
    func cancelPending() {
        stateLock.lock()
        pending = CGScrollOutputAccumulator()
        stateLock.unlock()
        // Producers must be stopped first. Finish any batch already taken by
        // the output queue before the caller restores native mode or direction.
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {}
    }

    /// Creates pixel-based continuous scroll events. Pixel units are essential:
    /// line units would re-enter macOS application-specific acceleration and
    /// destroy the curve fitted from the captured Options+ output.
    private func post(verticalPixelDelta: Int, horizontalPixelDelta: Int) {
        guard verticalPixelDelta != 0 || horizontalPixelDelta != 0 else { return }
        let vertical = max(Int(Int32.min), min(Int(Int32.max), verticalPixelDelta))
        let horizontal = max(Int(Int32.min), min(Int(Int32.max), horizontalPixelDelta))
        let shouldSchedule: Bool
        stateLock.lock()
        pending.append(vertical: vertical, horizontal: horizontal)
        shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        stateLock.unlock()

        if shouldSchedule {
            queue.async { self.drainOneBatch() }
        }
    }

    private func drainOneBatch() {
        stateLock.lock()
        let batch = pending.take()
        if batch.isEmpty {
            drainScheduled = false
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        send(batch)

        // Keep one scheduled turn for a continuously active stream. Producers
        // only update the accumulator while this delay is pending, so a slow
        // WindowServer post cannot create an unbounded block backlog.
        queue.asyncAfter(deadline: .now() + outputInterval) {
            self.drainOneBatch()
        }
    }

    private static func postNow(_ batch: CGScrollOutputBatch) {
        guard let source,
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .pixel,
                  wheelCount: batch.horizontal == 0 ? 1 : 2,
                  wheel1: Int32(batch.vertical),
                  wheel2: Int32(batch.horizontal),
                  wheel3: 0
              ) else {
            return
        }
        // The marker is process-defined metadata, not a Logitech field. The
        // event tap checks it before correlation so injected output is never
        // mistaken for native input and suppressed recursively.
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        // Continuous pixel events match trackpad/Options+ semantics.
        // Omitting this flag lets applications interpret values as lines.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }
}
