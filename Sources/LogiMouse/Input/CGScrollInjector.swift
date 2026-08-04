import CoreGraphics
import Foundation

enum CGScrollInjector {
    /// Marks events synthesized by this process so the suppressing event tap
    /// can pass them without creating an injection loop.
    static let eventMarker: Int64 = 0x4d58_5343_524f_4c4c
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func post(pixelDelta: Int) {
        post(verticalPixelDelta: pixelDelta, horizontalPixelDelta: 0)
    }

    static func postHorizontal(pixelDelta: Int) {
        post(verticalPixelDelta: 0, horizontalPixelDelta: pixelDelta)
    }

    /// Creates pixel-based continuous scroll events. Pixel units are essential:
    /// line units would re-enter macOS application-specific acceleration and
    /// destroy the curve fitted from the captured Options+ output.
    private static func post(verticalPixelDelta: Int, horizontalPixelDelta: Int) {
        guard verticalPixelDelta != 0 || horizontalPixelDelta != 0 else { return }
        let vertical = max(Int(Int32.min), min(Int(Int32.max), verticalPixelDelta))
        let horizontal = max(Int(Int32.min), min(Int(Int32.max), horizontalPixelDelta))
        guard let source,
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: horizontal == 0 ? 1 : 2,
                wheel1: Int32(vertical),
                wheel2: Int32(horizontal),
                wheel3: 0
              ) else {
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }
}
