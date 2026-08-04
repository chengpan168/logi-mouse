import AppKit
import Foundation

/// Coordinates capture, device takeover, axis models and CGEvent injection.
///
/// The vertical and horizontal axes use identical model parameters but separate
/// model instances. Sharing activity or fractional remainder would make a fast
/// vertical gesture artificially accelerate the next horizontal gesture.
final class CaptureCoordinator {
    private(set) var isRunning = false
    private(set) var isLiveModelEnabled = false
    private(set) var isReceiverTakeoverEnabled = false
    private(set) var isGlobalOutputEnabled = false
    private(set) var outputURL: URL?

    var onStatusChange: ((String) -> Void)?
    var onStopped: (() -> Void)?

    private var logger: JSONLLogger?
    private var hidMonitor: HIDMonitor?
    private var eventMonitor: CGEventMonitor?
    private var durationTimer: Timer?
    private var frameTimer: Timer?
    private weak var scrollView: NSScrollView?
    private var previousOffset: CGPoint?
    private var dynamicsModel = ScrollDynamicsModel()
    private var horizontalDynamicsModel = ScrollDynamicsModel()
    private var wasLivePointerBypassed = false

    // MARK: - Capture lifecycle

    func start(configuration: Configuration, scrollView: NSScrollView) throws {
        stop()
        let outputURL = configuration.resolvedOutput()
        let logger = try JSONLLogger(
            outputURL: outputURL,
            scenario: configuration.scenario,
            profile: configuration.captureProfile
        )
        logger.write(layer: "capture_start", timestampNs: MonotonicClock.nowNanoseconds()) { _ in }
        let hidMonitor = HIDMonitor(logger: logger)
        let eventMonitor = CGEventMonitor(logger: logger)
        hidMonitor.onWheelEvent = { [weak self] event, timestampNs in
            self?.processLiveWheel(event, timestampNs: timestampNs)
        }
        hidMonitor.onThumbwheelEvent = { [weak self] event, timestampNs in
            self?.processLiveThumbwheel(event, timestampNs: timestampNs)
        }
        hidMonitor.onControllerStateChange = { [weak self] state in
            guard let self, self.isReceiverTakeoverEnabled else { return }
            switch state {
            case .unavailable:
                self.onStatusChange?("Receiver disconnected — waiting to reacquire HID++ wheel")
            case .receiverReady, .discovering:
                self.onStatusChange?("Receiver connected — reacquiring HID++ wheel…")
            case .ready:
                self.onStatusChange?("ACTIVE Receiver takeover — keep pointer inside test area")
            case let .failed(message):
                self.onStatusChange?("Receiver reacquire retrying — \(message)")
            }
        }
        eventMonitor.shouldSuppressExternalScroll = { [weak self] in
            self?.isLiveTargetActive() ?? false
        }
        eventMonitor.shouldSuppressHorizontalScroll = { [weak self] in
            guard let self else { return false }
            return self.isReceiverTakeoverEnabled && self.isLiveTargetActive()
        }
        eventMonitor.onExternalScrollEvent = { [weak self] in
            guard let self, self.isReceiverTakeoverEnabled else { return }
            self.hidMonitor?.verifyReceiverWheelModeSoon()
        }

        do {
            try hidMonitor.start()
            try eventMonitor.start()
        } catch {
            hidMonitor.stop()
            eventMonitor.stop()
            logger.write(layer: "capture_error", timestampNs: MonotonicClock.nowNanoseconds()) { record in
                record.message = error.localizedDescription
            }
            logger.synchronize()
            throw error
        }

        self.logger = logger
        self.hidMonitor = hidMonitor
        self.eventMonitor = eventMonitor
        self.outputURL = outputURL
        self.scrollView = scrollView
        self.isRunning = true
        self.previousOffset = nil
        self.isLiveModelEnabled = false
        self.isReceiverTakeoverEnabled = false
        self.isGlobalOutputEnabled = false
        self.dynamicsModel.reset()
        self.horizontalDynamicsModel.reset()
        if configuration.captureProfile == .diagnostic {
            frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                self?.sampleViewOffset()
            }
        }
        if let duration = configuration.duration {
            durationTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.stop()
                self?.onStopped?()
            }
        }
        onStatusChange?("\(configuration.captureProfile.displayName) → \(outputURL.path)")
    }

    func recordNSEvent(_ event: NSEvent, offset: CGPoint) {
        guard let logger, let scrollView, isRunning else { return }
        logger.write(layer: "ns_event", timestampNs: UInt64(event.timestamp * 1_000_000_000)) { record in
            record.pointDeltaY = event.scrollingDeltaY
            record.pointDeltaX = event.scrollingDeltaX
            record.isContinuous = event.hasPreciseScrollingDeltas
            record.scrollPhase = Int64(event.phase.rawValue)
            record.momentumPhase = Int64(event.momentumPhase.rawValue)
            record.viewOffsetY = offset.y
            record.viewOffsetX = offset.x
            Self.fillViewGeometry(scrollView, into: &record)
        }
    }

    func setLiveModelEnabled(_ enabled: Bool, direction: ScrollDirectionMapping) throws {
        guard isRunning, let eventMonitor else { return }
        if enabled {
            dynamicsModel = ScrollDynamicsModel(directionMapping: direction)
            horizontalDynamicsModel = ScrollDynamicsModel(directionMapping: direction)
            try eventMonitor.setSuppressionEnabled(true)
            isLiveModelEnabled = true
            wasLivePointerBypassed = false
            logger?.write(layer: "live_model_enabled", timestampNs: MonotonicClock.nowNanoseconds()) { record in
                record.message = "direction=\(direction.rawValue)"
            }
            onStatusChange?("LIVE model enabled in test area — \(direction.rawValue) direction")
        } else {
            if isReceiverTakeoverEnabled {
                isReceiverTakeoverEnabled = false
                hidMonitor?.restoreReceiverWheel { [weak self] result in
                    switch result {
                    case .success:
                        self?.logger?.write(
                            layer: "hidpp_takeover_disabled",
                            timestampNs: MonotonicClock.nowNanoseconds()
                        ) { _ in }
                    case let .failure(error):
                        self?.onStatusChange?("WARNING: Receiver wheel restore failed — \(error.localizedDescription)")
                    }
                }
            }
            isGlobalOutputEnabled = false
            isLiveModelEnabled = false
            dynamicsModel.reset()
            horizontalDynamicsModel.reset()
            wasLivePointerBypassed = false
            logger?.write(layer: "live_model_disabled", timestampNs: MonotonicClock.nowNanoseconds()) { _ in }
            try eventMonitor.setSuppressionEnabled(false)
            if let outputURL {
                onStatusChange?("Recording → \(outputURL.path)")
            }
        }
    }

    func setReceiverTakeoverEnabled(
        _ enabled: Bool,
        completion: @escaping (Result<HIDPPController.State, Error>) -> Void
    ) {
        guard isRunning, let hidMonitor else {
            completion(.failure(HIDPPControllerError.noReceiverChannel))
            return
        }
        if enabled {
            guard isLiveModelEnabled else {
                completion(.failure(ReceiverTakeoverRequirementError.liveModelRequired))
                return
            }
            onStatusChange?("Discovering Receiver HID++ features…")
            hidMonitor.takeOverReceiverWheel { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(state):
                    self.isReceiverTakeoverEnabled = true
                    self.logger?.write(
                        layer: "hidpp_takeover_enabled",
                        timestampNs: MonotonicClock.nowNanoseconds()
                    ) { record in
                        record.message = state.description
                    }
                    self.onStatusChange?(
                        self.isGlobalOutputEnabled
                            ? "ACTIVE Receiver takeover — GLOBAL model output"
                            : "ACTIVE Receiver takeover — keep pointer inside test area"
                    )
                case let .failure(error):
                    self.isReceiverTakeoverEnabled = false
                    self.onStatusChange?("Receiver takeover failed — \(error.localizedDescription)")
                }
                completion(result)
            }
        } else {
            onStatusChange?("Restoring Receiver native wheel mode…")
            hidMonitor.restoreReceiverWheel { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.isReceiverTakeoverEnabled = false
                    self.logger?.write(
                        layer: "hidpp_takeover_disabled",
                        timestampNs: MonotonicClock.nowNanoseconds()
                    ) { _ in }
                    self.onStatusChange?("Receiver native wheel mode restored")
                case let .failure(error):
                    self.onStatusChange?("WARNING: Receiver wheel restore failed — \(error.localizedDescription)")
                }
                completion(result)
            }
        }
    }

    func setLiveDirection(_ direction: ScrollDirectionMapping) {
        dynamicsModel.setDirectionMapping(direction)
        horizontalDynamicsModel.setDirectionMapping(direction)
    }

    func setGlobalOutputEnabled(_ enabled: Bool) {
        guard isRunning, isLiveModelEnabled else {
            isGlobalOutputEnabled = false
            return
        }
        isGlobalOutputEnabled = enabled
        dynamicsModel.reset()
        horizontalDynamicsModel.reset()
        logger?.write(
            layer: enabled ? "global_output_enabled" : "global_output_disabled",
            timestampNs: MonotonicClock.nowNanoseconds()
        ) { _ in }
        onStatusChange?(
            enabled
                ? "GLOBAL model output enabled — all applications"
                : "LIVE model limited to test area"
        )
    }

    func stop() {
        guard isRunning || logger != nil else { return }
        durationTimer?.invalidate()
        durationTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        eventMonitor?.stop()
        hidMonitor?.stop()
        logger?.close()
        eventMonitor = nil
        hidMonitor = nil
        logger = nil
        scrollView = nil
        previousOffset = nil
        isRunning = false
        isLiveModelEnabled = false
        isReceiverTakeoverEnabled = false
        isGlobalOutputEnabled = false
        dynamicsModel.reset()
        horizontalDynamicsModel.reset()
        if let outputURL {
            onStatusChange?("Stopped. Saved \(outputURL.path)")
        } else {
            onStatusChange?("Stopped")
        }
    }

    // MARK: - Real-time model pipeline

    private func processLiveWheel(_ event: HIDPPWheelEvent, timestampNs: UInt64) {
        guard isLiveModelEnabled else { return }
        guard isLiveTargetActive() else {
            dynamicsModel.reset()
            if !wasLivePointerBypassed {
                wasLivePointerBypassed = true
                logger?.write(layer: "live_model_bypassed", timestampNs: timestampNs) { record in
                    record.message = "pointer outside test surface"
                }
            }
            return
        }
        wasLivePointerBypassed = false
        let output = dynamicsModel.process(delta: event.delta, flags: event.flags, timestampNs: timestampNs)
        logger?.write(layer: "model_output", timestampNs: timestampNs) { record in
            record.hidppWheelDelta = event.delta
            record.hidppWheelFlags = event.flags
            record.pointDeltaY = Double(output.totalPixels)
            record.message = String(
                format: "gain=%.4f activity_before=%.4f activity_after=%.4f periods=%d",
                output.gain,
                output.activityBeforeInput,
                output.activityAfterInput,
                output.periods
            )
        }
        for pixels in output.pixelDeltas {
            CGScrollInjector.post(pixelDelta: pixels)
        }
    }

    private func processLiveThumbwheel(_ event: HIDPPThumbwheelEvent, timestampNs: UInt64) {
        guard isLiveModelEnabled else { return }
        guard isLiveTargetActive() else {
            horizontalDynamicsModel.reset()
            return
        }
        guard event.rotation != 0 else { return }

        // Recorded 0x2150 rotation has the opposite sign from the horizontal
        // CGEvent point delta produced under macOS natural scrolling. Normalize
        // that hardware convention here, then let ScrollDynamicsModel apply the
        // user-selected natural/traditional mapping exactly as it does for Y.
        let output = horizontalDynamicsModel.process(
            delta: -event.rotation,
            flags: 0x11,
            timestampNs: timestampNs
        )
        logger?.write(layer: "horizontal_model_output", timestampNs: timestampNs) { record in
            record.hidppThumbwheelRotation = event.rotation
            record.hidppThumbwheelStatus = event.rotationStatus
            record.pointDeltaX = Double(output.totalPixels)
            record.message = String(
                format: "gain=%.4f activity_before=%.4f activity_after=%.4f periods=%d",
                output.gain,
                output.activityBeforeInput,
                output.activityAfterInput,
                output.periods
            )
        }
        for pixels in output.pixelDeltas {
            CGScrollInjector.postHorizontal(pixelDelta: pixels)
        }
    }

    private func isPointerInsideTestSurface() -> Bool {
        guard let scrollView, let window = scrollView.window, window.isVisible else { return false }
        let windowRect = scrollView.convert(scrollView.bounds, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        return screenRect.contains(NSEvent.mouseLocation)
    }

    private func isLiveTargetActive() -> Bool {
        isGlobalOutputEnabled || isPointerInsideTestSurface()
    }

    private func sampleViewOffset() {
        guard let scrollView, let logger, isRunning else { return }
        let offset = scrollView.contentView.bounds.origin
        guard offset != previousOffset else { return }
        previousOffset = offset
        logger.write(layer: "view", timestampNs: MonotonicClock.nowNanoseconds()) { record in
            record.viewOffsetY = offset.y
            record.viewOffsetX = offset.x
            Self.fillViewGeometry(scrollView, into: &record)
        }
    }

    private static func fillViewGeometry(_ scrollView: NSScrollView, into record: inout EventRecord) {
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let viewportHeight = scrollView.contentView.bounds.height
        let offsetY = scrollView.contentView.bounds.origin.y
        record.viewDocumentHeight = documentHeight
        record.viewViewportHeight = viewportHeight
        record.viewRemainingY = max(0, documentHeight - viewportHeight - offsetY)
    }
}

enum ReceiverTakeoverRequirementError: LocalizedError {
    case liveModelRequired

    var errorDescription: String? {
        "Enable Live model before taking over the Receiver wheel."
    }
}
