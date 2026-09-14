import Foundation

/// Owns the high-frequency scroll data path independently of AppKit's main
/// actor. HID callbacks enqueue value types here; the event tap only performs a
/// short, lock-protected suppression query. No pointer event is consumed by
/// this type.
final class ScrollOutputPipeline {
    static let diagnosticSampleLimit = 4

    private struct Configuration: Equatable, Sendable {
        let generation: UInt64
        let direction: ScrollDirectionMapping
        let verticalEnabled: Bool
        let horizontalEnabled: Bool

        static let inactive = Configuration(
            generation: 0,
            direction: .natural,
            verticalEnabled: false,
            horizontalEnabled: false
        )
    }

    private let queue: DispatchQueue
    private let injector: CGScrollInjector
    private let stateLock = NSLock()
    private var configuration = Configuration.inactive
    private let correlation = TargetScrollCorrelation()
    private var verticalModel = ScrollDynamicsModel()
    private var horizontalModel = ScrollDynamicsModel()
    private var verticalDiagnosticSamplesRemaining = 0
    private var horizontalDiagnosticSamplesRemaining = 0

    init(
        queue: DispatchQueue = DispatchQueue(label: "dev.logi-mouse.scroll-output-pipeline", qos: .utility),
        injector: CGScrollInjector = .shared
    ) {
        self.queue = queue
        self.injector = injector
    }

    /// Applies a low-frequency configuration change and resets historical
    /// model state. Resetting also discards pending Quartz output so a mode or
    /// generation transition cannot inject an event after native scrolling has
    /// been restored.
    @MainActor func configure(
        generation: UInt64,
        direction: ScrollDirectionMapping,
        verticalEnabled: Bool,
        horizontalEnabled: Bool,
        armDiagnostics: Bool = false
    ) {
        let next = Configuration(
            generation: generation,
            direction: direction,
            verticalEnabled: verticalEnabled,
            horizontalEnabled: horizontalEnabled
        )

        applyConfiguration(next, armDiagnostics: armDiagnostics)
    }

    @MainActor private func applyConfiguration(
        _ next: Configuration,
        forceReset: Bool = false,
        armDiagnostics: Bool = false
    ) {
        stateLock.lock()
        guard configuration != next || forceReset || armDiagnostics else {
            stateLock.unlock()
            return
        }
        // Enqueueing input holds this same lock, so closing the gate guarantees
        // every accepted old report precedes the queue barrier below.
        configuration = .inactive
        correlation.reset()
        if armDiagnostics {
            verticalDiagnosticSamplesRemaining = Self.diagnosticSampleLimit
            horizontalDiagnosticSamplesRemaining = Self.diagnosticSampleLimit
        }
        stateLock.unlock()

        // Never hold the event-tap lock while waiting for model work or Quartz.
        queue.sync {
            verticalModel = ScrollDynamicsModel(directionMapping: next.direction)
            horizontalModel = ScrollDynamicsModel(directionMapping: next.direction)
        }
        injector.cancelPending()
        stateLock.lock()
        configuration = next
        stateLock.unlock()

        if armDiagnostics {
            RuntimeLog.notice(
                "scroll-model",
                "Diagnostic sampling armed generation=\(next.generation) "
                    + "samples_per_axis=\(Self.diagnosticSampleLimit) "
                    + "enabled={vertical:\(next.verticalEnabled),horizontal:\(next.horizontalEnabled)}"
            )
        }
    }

    /// Clears model history and correlation evidence while preserving the
    /// current gate configuration. Used when output is toggled or a direction
    /// change starts a new physical scroll session.
    @MainActor func reset() {
        stateLock.lock()
        let current = configuration
        stateLock.unlock()
        applyConfiguration(current, forceReset: true)
    }

    func armDiagnostics(reason: String) {
        stateLock.lock()
        verticalDiagnosticSamplesRemaining = Self.diagnosticSampleLimit
        horizontalDiagnosticSamplesRemaining = Self.diagnosticSampleLimit
        let generation = configuration.generation
        stateLock.unlock()
        RuntimeLog.notice(
            "scroll-model",
            "Diagnostic sampling armed reason=\(reason) generation=\(generation) "
                + "samples_per_axis=\(Self.diagnosticSampleLimit)"
        )
    }

    /// Stops the hot path immediately. The queue is drained only for its tiny
    /// value-type reset; no event callback is allowed to call the main actor.
    @MainActor func deactivate(generation: UInt64) {
        configure(
            generation: generation,
            direction: .natural,
            verticalEnabled: false,
            horizontalEnabled: false
        )
    }

    func enqueueWheel(
        _ event: HIDPPWheelEvent,
        timestampNs: UInt64,
        generation: UInt64
    ) {
        // Record correlation at callback time, before model work is queued.
        // macOS may publish the native scroll event immediately after the HID
        // report; delaying this evidence until the utility queue runs would
        // create an avoidable double-scroll/fail-open window.
        guard event.delta != 0 else { return }
        enqueueInput(
            .vertical,
            generation: generation,
            eventCount: max(1, Int(event.flags & 0x0f)),
            timestampNs: timestampNs
        ) { [weak self] in
            self?.processWheel(event, timestampNs: timestampNs, generation: generation)
        }
    }

    func enqueueThumbwheel(
        _ event: HIDPPThumbwheelEvent,
        timestampNs: UInt64,
        generation: UInt64
    ) {
        guard event.rotation != 0 else { return }
        enqueueInput(
            .horizontal,
            generation: generation,
            eventCount: 1,
            timestampNs: timestampNs
        ) { [weak self] in
            self?.processThumbwheel(event, timestampNs: timestampNs, generation: generation)
        }
    }

    /// Called synchronously by the CGEvent tap. It never waits for the model
    /// queue, so a burst of HID reports cannot make pointer events wait behind
    /// model processing or Quartz IPC.
    func shouldSuppress(_ axis: ScrollAxis, timestampNs: UInt64) -> Bool {
        stateLock.lock()
        let enabled: Bool
        switch axis {
        case .vertical: enabled = configuration.verticalEnabled
        case .horizontal: enabled = configuration.horizontalEnabled
        }
        guard enabled else {
            stateLock.unlock()
            return false
        }
        let matched = correlation.consumeMatch(axis, timestampNs: timestampNs)
        stateLock.unlock()
        return matched
    }

    var diagnosticDescription: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return "generation=\(configuration.generation) "
            + "direction=\(configuration.direction.rawValue) "
            + "enabled={vertical:\(configuration.verticalEnabled),horizontal:\(configuration.horizontalEnabled)}"
    }

    private func processWheel(
        _ event: HIDPPWheelEvent,
        timestampNs: UInt64,
        generation: UInt64
    ) {
        guard isEnabled(.vertical, generation: generation) else { return }
        let output = verticalModel.process(
            delta: event.delta,
            flags: event.flags,
            timestampNs: timestampNs
        )
        guard isEnabled(.vertical, generation: generation) else { return }
        if output.totalPixels != 0 {
            injector.post(pixelDelta: output.totalPixels)
        }
        recordVerticalDiagnostic(
            event: event,
            output: output,
            timestampNs: timestampNs,
            generation: generation
        )
    }

    private func processThumbwheel(
        _ event: HIDPPThumbwheelEvent,
        timestampNs: UInt64,
        generation: UInt64
    ) {
        guard isEnabled(.horizontal, generation: generation) else { return }
        let output = horizontalModel.process(
            delta: -event.rotation,
            flags: 0x11,
            timestampNs: timestampNs
        )
        guard isEnabled(.horizontal, generation: generation) else { return }
        if output.totalPixels != 0 {
            injector.postHorizontal(pixelDelta: output.totalPixels)
        }
        recordHorizontalDiagnostic(
            event: event,
            output: output,
            timestampNs: timestampNs,
            generation: generation
        )
    }

    private func isEnabled(_ axis: ScrollAxis, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard configuration.generation == generation else { return false }
        switch axis {
        case .vertical: return configuration.verticalEnabled
        case .horizontal: return configuration.horizontalEnabled
        }
    }

    private func enqueueInput(
        _ axis: ScrollAxis,
        generation: UInt64,
        eventCount: Int,
        timestampNs: UInt64,
        work: @escaping () -> Void
    ) {
        stateLock.lock()
        let enabled: Bool
        switch axis {
        case .vertical: enabled = configuration.verticalEnabled
        case .horizontal: enabled = configuration.horizontalEnabled
        }
        guard enabled, configuration.generation == generation else {
            stateLock.unlock()
            return
        }
        correlation.record(axis, timestampNs: timestampNs, eventCount: eventCount)
        queue.async(execute: work)
        stateLock.unlock()
    }

    private func recordVerticalDiagnostic(
        event: HIDPPWheelEvent,
        output: ScrollDynamicsOutput,
        timestampNs: UInt64,
        generation: UInt64
    ) {
        stateLock.lock()
        guard verticalDiagnosticSamplesRemaining > 0 else {
            stateLock.unlock()
            return
        }
        let sample = Self.diagnosticSampleLimit - verticalDiagnosticSamplesRemaining + 1
        verticalDiagnosticSamplesRemaining -= 1
        stateLock.unlock()
        RuntimeLog.info(
            "scroll-model",
            "sample=\(sample)/\(Self.diagnosticSampleLimit) axis=vertical "
                + "generation=\(generation) device=\(event.deviceIndex) "
                + "feature=\(String(format: "0x%02x", event.featureIndex)) "
                + "timestamp_ns=\(timestampNs) raw_delta=\(event.delta) "
                + "periods=\(output.periods) injected_total=\(output.totalPixels) "
                + "injected_deltas=\(output.pixelDeltas)"
        )
    }

    private func recordHorizontalDiagnostic(
        event: HIDPPThumbwheelEvent,
        output: ScrollDynamicsOutput,
        timestampNs: UInt64,
        generation: UInt64
    ) {
        stateLock.lock()
        guard horizontalDiagnosticSamplesRemaining > 0 else {
            stateLock.unlock()
            return
        }
        let sample = Self.diagnosticSampleLimit - horizontalDiagnosticSamplesRemaining + 1
        horizontalDiagnosticSamplesRemaining -= 1
        stateLock.unlock()
        RuntimeLog.info(
            "scroll-model",
            "sample=\(sample)/\(Self.diagnosticSampleLimit) axis=horizontal "
                + "generation=\(generation) device=\(event.deviceIndex) "
                + "feature=\(String(format: "0x%02x", event.featureIndex)) "
                + "timestamp_ns=\(timestampNs) raw_rotation=\(event.rotation) "
                + "injected_total=\(output.totalPixels) injected_deltas=\(output.pixelDeltas)"
        )
    }
}
