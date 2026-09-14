import CoreGraphics

/// Keeps synthetic Quartz events from suppressing local hardware input.
///
/// CoreGraphics defaults to a 250 ms local-event suppression interval and a
/// zero filter mask for a newly created source. A scroll injector that posts
/// repeatedly with those defaults can therefore make an unrelated mouse
/// pointer appear to pause. Keep the policy in one place for every injector.
enum CGEventSourceSafety {
    /// Zero disables the post-event suppression window for local hardware.
    static let localEventsSuppressionInterval: CFTimeInterval = 0
    /// Permit local mouse, keyboard and system-defined events (0x1 | 0x2 | 0x4).
    static let localEventsFilterMaskRawValue: UInt32 = 0x07

    static func makeHIDSystemSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return nil
        }
        configure(source)
        return source
    }

    static func configure(_ source: CGEventSource) {
        source.localEventsSuppressionInterval = localEventsSuppressionInterval
        let filter = CGEventFilterMask(rawValue: localEventsFilterMaskRawValue)

        // Use raw values for the enum states because SDK/Swift importer naming
        // changed across Xcode releases; the CoreGraphics ABI values are stable.
        if let suppressionInterval = CGEventSuppressionState(rawValue: 0) {
            source.setLocalEventsFilterDuringSuppressionState(
                filter,
                state: suppressionInterval
            )
        }
        if let remoteMouseDrag = CGEventSuppressionState(rawValue: 1) {
            source.setLocalEventsFilterDuringSuppressionState(
                filter,
                state: remoteMouseDrag
            )
        }
    }
}
