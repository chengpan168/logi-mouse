import Foundation
import IOKit.hid

enum HIDPPControllerError: LocalizedError, Equatable {
    /// No IOHIDDevice control interface is currently published.
    case noHIDPPChannel
    /// A Receiver exists, but none of slots 1...6 answered feature discovery.
    case deviceNotFound
    case featureUnsupported(UInt16)
    case writeFailed(IOReturn)
    case timeout
    case transportChanged
    case deviceError(UInt8)
    case unexpectedResponse
    case verificationFailed(expected: UInt8, actual: UInt8)

    var errorDescription: String? {
        switch self {
        case .noHIDPPChannel:
            "No writable Logitech HID++ channel is available."
        case .deviceNotFound:
            "No HID++ device responded on the active transport."
        case let .featureUnsupported(featureID):
            String(format: "The connected device does not expose HID++ feature 0x%04x.", featureID)
        case let .writeFailed(code):
            String(format: "IOHIDDeviceSetReport failed (IOReturn 0x%08x).", code)
        case .timeout:
            "The HID++ request timed out. The mouse may be asleep or another process owns the device."
        case .transportChanged:
            "The mouse transport changed while a HID++ request was in progress."
        case let .deviceError(code):
            String(format: "The HID++ device returned error 0x%02x.", code)
        case .unexpectedResponse:
            "The HID++ device returned an unexpected response."
        case let .verificationFailed(expected, actual):
            String(format: "Wheel mode verification failed: expected 0x%02x, got 0x%02x.", expected, actual)
        }
    }
}

struct HIDPPTakeoverAxes: Equatable, Sendable {
    /// True only after the corresponding device mode has been written and read
    /// back successfully. Event suppression must never rely on intent alone.
    var vertical = false
    var horizontal = false

    static let none = HIDPPTakeoverAxes()
    var isEmpty: Bool { !vertical && !horizontal }
    var isComplete: Bool { vertical && horizontal }
}

enum HIDPPBatteryState: Equatable, Sendable {
    case unavailable
    case loading
    case available(HIDPPProtocol.BatteryInfo)
}

/// Serializes every mutating HID++ operation performed against a Logitech
/// Receiver or Bluetooth control channel and owns the safety lifecycle of
/// diverted wheel modes.
///
/// Hardware invariants:
/// - Feature indices are device-specific and must be discovered from Root
///   Feature `0x0000`; captured indices are never trusted for control writes.
/// - Before the first write, the original main-wheel and thumbwheel modes are
///   saved. Disable, recoverable failure and process termination restore those
///   values while the channel is writable; physical disconnect invalidates the
///   route and waits for event-driven reacquisition instead of pretending that
///   an offline device was restored.
/// - Every mode write is followed by a read-back. A successful transport write
///   only proves that bytes were accepted, not that the mouse applied them.
/// - Requests are serialized because HID++ exposes only a 4-bit software ID
///   for response matching and unsolicited events use the same input channel.
///
/// `operationQueue` performs commands and event-triggered verification work.
/// `stateLock` protects device/lifecycle state shared with IOKit callbacks,
/// while `condition` pairs the synchronous request path with reports delivered
/// by `HIDMonitor`.
final class HIDPPController {
    /// Observable controller phase. `channelReady` means an interface exists;
    /// it does not prove that a paired Receiver device is awake. Only `ready`
    /// follows successful feature discovery, mode writes and read-back.
    enum State: Equatable, Sendable, CustomStringConvertible {
        case unavailable
        case channelReady(HIDPPTransport)
        /// The actual mouse, rather than merely its Receiver interface, has
        /// published readiness evidence suitable for starting takeover.
        case deviceReady(HIDPPTransport)
        case discovering
        case ready(deviceIndex: UInt8, featureIndex: UInt8, mode: HIDPPProtocol.WheelMode)
        case failed(String)

        var description: String {
            switch self {
            case .unavailable: "unavailable"
            case let .channelReady(transport): "channel-ready: \(transport)"
            case let .deviceReady(transport): "device-ready: \(transport)"
            case .discovering: "discovering"
            case let .ready(deviceIndex, featureIndex, mode):
                String(
                    format: "ready device=%u feature=0x%02x %@",
                    deviceIndex,
                    featureIndex,
                    mode.description
                )
            case let .failed(message): "failed: \(message)"
            }
        }
    }

    var onStateChange: ((State) -> Void)?
    var onTakeoverAxesChange: ((HIDPPTakeoverAxes) -> Void)?
    var onBatteryStateChange: ((HIDPPBatteryState) -> Void)?
    var onLog: ((String, String) -> Void)?

    private struct PendingRequest {
        /// Exact route/function/tag expected in the reply. There can be only one
        /// because HID++ provides a four-bit software ID rather than a full
        /// transaction identifier.
        let header: HIDPPProtocol.RequestHeader
        var response: [UInt8]?
    }

    private struct ActiveWheel {
        /// Addresses used by the current transport only; invalid after switch.
        let deviceIndex: UInt8
        let featureIndex: UInt8
        /// Native-safe mode captured before the first mutating command.
        let restoreMode: HIDPPProtocol.WheelMode
    }

    private struct ActiveThumbwheel {
        let deviceIndex: UInt8
        let featureIndex: UInt8
        /// Feature 0x2150 has a separate inversion bit that must be preserved.
        let restoreInverted: Bool
    }

    private struct Channel {
        /// IOHIDDevice used by IOHIDDeviceSetReport for output commands.
        let device: IOHIDDevice
        /// In-process identity shared with HIDMonitor callback routing.
        let key: UInt
        let transport: HIDPPTransport
    }

    /// Serializes hardware requests, mode transactions and explicit verification.
    private let operationQueue = DispatchQueue(label: "dev.logi-mouse.hidpp-controller")
    /// Pairs the synchronous SetReport request path with asynchronous 0x11 input.
    private let condition = NSCondition()
    /// Protects routing and mode state touched by IOKit and operationQueue.
    private let stateLock = NSLock()
    private var channels: [UInt: Channel] = [:]
    private var selectedChannelKey: UInt?
    private var pendingRequest: PendingRequest?
    /// Rotating non-zero four-bit tag embedded in the low nibble of byte 3.
    private var nextSoftwareID: UInt8 = 0x0a
    /// Receiver slot seen in notifications/events; Bluetooth is always 0xff.
    private var observedDeviceIndex: UInt8?
    /// Per-device runtime addresses returned by Root Feature discovery.
    private var featureIndices: [UInt8: UInt8] = [:]
    private var thumbwheelFeatureIndices: [UInt8: UInt8] = [:]
    private var batteryFeatures: [UInt8: HIDPPProtocol.BatteryFeature] = [:]
    private var activeWheel: ActiveWheel?
    private var activeThumbwheel: ActiveThumbwheel?
    private var verifiedTakeoverAxes = HIDPPTakeoverAxes.none
    private var takeoverRequested = false
    private var reacquireAttemptScheduled = false
    private var batteryRefreshScheduled = false
    private var routeGeneration: UInt64 = 0

    // MARK: - HID++ channel lifecycle

    /// Adds a physical control interface and selects the preferred transport.
    /// Bluetooth wins while present because an inserted Receiver does not prove
    /// its paired mouse is currently using that radio path.
    func considerDevice(
        _ device: IOHIDDevice,
        key: UInt,
        transport: HIDPPTransport
    ) {
        stateLock.lock()
        channels[key] = Channel(device: device, key: key, transport: transport)
        let previousKey = selectedChannelKey
        selectedChannelKey = preferredChannelKeyLocked()
        let selected = selectedChannelLocked()
        let channelChanged = previousKey != selectedChannelKey
        if channelChanged {
            resetRouteStateLocked(for: selected?.transport)
        }
        stateLock.unlock()

        if channelChanged { publishTakeoverAxes(.none) }

        guard channelChanged, let selected else { return }
        cancelPendingRequest()
        transition(to: selected.transport == .bluetooth
            ? .deviceReady(.bluetooth)
            : .channelReady(.usbReceiver))
        log("hidpp_controller_device", "selected \(selected.transport) HID++ channel")
        refreshBattery(after: 0.15)
    }

    /// Removes a physical interface. If Bluetooth disappears while a Receiver
    /// remains inserted, recovery waits for Receiver link/activity evidence
    /// instead of immediately scanning dormant slots in a loop.
    func removeDevice(key: UInt) {
        stateLock.lock()
        let wasSelected = selectedChannelKey == key
        channels.removeValue(forKey: key)
        if wasSelected {
            selectedChannelKey = preferredChannelKeyLocked()
        }
        let replacement = selectedChannelLocked()
        if wasSelected { resetRouteStateLocked(for: replacement?.transport) }
        stateLock.unlock()

        if wasSelected {
            publishTakeoverAxes(.none)
            publishBatteryState(.unavailable)
            cancelPendingRequest()
            if let replacement {
                transition(to: replacement.transport == .bluetooth
                    ? .deviceReady(.bluetooth)
                    : .channelReady(.usbReceiver))
                log("hidpp_controller_device", "fell back to \(replacement.transport) HID++ channel")
                if replacement.transport == .bluetooth {
                    refreshBattery(after: 0.15)
                }
            } else {
                transition(to: .unavailable)
                log("hidpp_controller_device_removed", "active HID++ channel removed")
            }
        }
    }

    /// Accepts every complete HID++ 0x11 input before event decoding. Exact
    /// replies wake `call`; ordinary wheel reports never trigger verification.
    func observeReport(_ report: [UInt8]) {
        guard report.count == HIDPPProtocol.longReportLength,
              report.first == HIDPPProtocol.longReportID else { return }

        var matchedPendingRequest = false
        condition.lock()
        if let pendingRequest,
           HIDPPProtocol.matchesResponse(report, request: pendingRequest.header) {
            self.pendingRequest?.response = report
            matchedPendingRequest = true
            condition.broadcast()
        }
        condition.unlock()

        guard !matchedPendingRequest, report[3] == 0 else { return }
        stateLock.lock()
        let batteryFeature = batteryFeatures[report[1]]
        stateLock.unlock()
        guard batteryFeature?.index == report[2],
              let batteryFeature,
              let battery = HIDPPProtocol.batteryInfo(
                  in: report,
                  feature: batteryFeature
              ) else { return }
        publishBatteryState(.available(battery))
    }

    /// Handles Receiver radio-link changes. The USB dongle's IOHIDInterface
    /// does not disappear when the mouse powers off, so report 0x10/0x41 is the
    /// authoritative online/offline signal for Receiver mode.
    func observeReceiverConnection(
        deviceKey: UInt,
        event: HIDPPProtocol.ReceiverConnectionEvent
    ) {
        stateLock.lock()
        let isSelectedReceiver = selectedChannelKey == deviceKey
            && channels[deviceKey]?.transport == .usbReceiver
        if isSelectedReceiver, event.isConnected {
            observedDeviceIndex = event.deviceIndex
        }
        if isSelectedReceiver, !event.isConnected {
            activeWheel = nil
            activeThumbwheel = nil
            featureIndices.removeAll()
            thumbwheelFeatureIndices.removeAll()
            batteryFeatures.removeAll()
            verifiedTakeoverAxes = .none
            routeGeneration &+= 1
        }
        stateLock.unlock()

        if isSelectedReceiver, !event.isConnected { publishTakeoverAxes(.none) }

        guard isSelectedReceiver else { return }
        if event.isConnected {
            log("hidpp_receiver_connected", "slot=\(event.deviceIndex)")
            transition(to: .deviceReady(.usbReceiver))
            refreshBattery(after: 0.05)
        } else {
            publishBatteryState(.unavailable)
            cancelPendingRequest()
            transition(to: .unavailable)
            log("hidpp_receiver_disconnected", "slot=\(event.deviceIndex)")
        }
    }

    func observeWheelRoute(deviceIndex: UInt8, featureIndex: UInt8) {
        stateLock.lock()
        observedDeviceIndex = deviceIndex
        featureIndices[deviceIndex] = featureIndex
        stateLock.unlock()
    }

    func observeThumbwheelRoute(deviceIndex: UInt8, featureIndex: UInt8) {
        stateLock.lock()
        observedDeviceIndex = deviceIndex
        thumbwheelFeatureIndices[deviceIndex] = featureIndex
        stateLock.unlock()
    }

    /// Performs one read-back requested by a low-frequency lifecycle event,
    /// such as reopening the control window. Scroll traffic never calls this.
    func verifyMode(
        completion: @escaping (Result<HIDPPTakeoverAxes, Error>) -> Void = { _ in }
    ) {
        operationQueue.async { [weak self] in
            guard let self else { return }
            guard self.isTakeoverRequested else {
                DispatchQueue.main.async {
                    completion(.failure(HIDPPControllerError.deviceNotFound))
                }
                return
            }
            guard self.hasActiveWheel else {
                self.scheduleReacquire(after: 0)
                DispatchQueue.main.async {
                    completion(.failure(HIDPPControllerError.deviceNotFound))
                }
                return
            }
            do {
                let axes = try self.verifyActiveMode()
                DispatchQueue.main.async { completion(.success(axes)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Reads battery state after an explicit UI request. Device lifecycle
    /// events call the same path with a short stabilization delay.
    func refreshBattery() {
        refreshBattery(after: 0)
    }

    func featureIndex(for deviceIndex: UInt8) -> UInt8? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return featureIndices[deviceIndex]
    }

    func thumbwheelFeatureIndex(for deviceIndex: UInt8) -> UInt8? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return thumbwheelFeatureIndices[deviceIndex]
    }

    func acceptsDevice(key: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedChannelKey == key
    }

    // MARK: - Public takeover lifecycle

    /// Begins the all-axis hardware transaction on `operationQueue`.
    /// Completion is delivered on the main queue for direct UI consumption.
    func takeOverWheel(
        preserveRequestOnFailure: Bool = false,
        completion: @escaping (Result<State, Error>) -> Void
    ) {
        setTakeoverRequested(true)
        operationQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ready = try self.performTakeover()
                DispatchQueue.main.async { completion(.success(ready)) }
            } catch {
                // A user-initiated enable failure turns intent back off. Runtime
                // recovery is different: its application-level intent survives
                // sleep, so keep the controller armed for a later matching or
                // Receiver link-up event after this bounded attempt fails.
                if !preserveRequestOnFailure {
                    self.setTakeoverRequested(false)
                }
                // A SetMode request may have reached the mouse even when its
                // response or verification read timed out. Restore the saved
                // pre-takeover mode before reporting the failed activation.
                if self.hasActiveWheel {
                    do {
                        _ = try self.performRestore()
                    } catch {
                        self.log("hidpp_restore_after_takeover_failure_failed", error.localizedDescription)
                    }
                }
                self.invalidateVerifiedTakeoverAxes()
                self.transition(to: .failed(error.localizedDescription))
                self.log("hidpp_takeover_failed", error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func restoreWheel(completion: @escaping (Result<State, Error>) -> Void) {
        setTakeoverRequested(false)
        operationQueue.async { [weak self] in
            guard let self else { return }
            do {
                let state = try self.performRestore()
                DispatchQueue.main.async { completion(.success(state)) }
            } catch {
                self.invalidateVerifiedTakeoverAxes()
                self.transition(to: .failed(error.localizedDescription))
                self.log("hidpp_restore_failed", error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Restores hardware before process termination.
    ///
    /// When called from the main thread, the run loop must keep pumping because
    /// IOHIDManager delivers the restore replies there. A plain semaphore wait
    /// would deadlock until timeout and could leave the wheel diverted.
    func restoreSynchronously() {
        setTakeoverRequested(false)
        if !Thread.isMainThread {
            operationQueue.sync {
                do {
                    _ = try performRestore()
                } catch {
                    invalidateVerifiedTakeoverAxes()
                    log("hidpp_restore_failed", error.localizedDescription)
                }
            }
            return
        }

        // IOHIDManager callbacks are delivered on the main run loop. Pump it
        // while the serialized controller queue restores and verifies the
        // mode; blocking the main thread here would otherwise force a timeout.
        let group = DispatchGroup()
        group.enter()
        operationQueue.async { [weak self] in
            defer { group.leave() }
            guard let self else { return }
            do {
                _ = try self.performRestore()
            } catch {
                self.invalidateVerifiedTakeoverAxes()
                self.log("hidpp_restore_failed", error.localizedDescription)
            }
        }
        while group.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// Invalidates the complete physical session without writing to hardware.
    ///
    /// This is used only for system sleep. The application-level coordinator
    /// preserves the user's takeover intent, while this controller deliberately
    /// forgets every IOHIDDevice, route and pending request from the old power
    /// generation. A newly created controller will rediscover them after wake.
    func invalidateForSystemSleep() {
        stateLock.lock()
        takeoverRequested = false
        channels.removeAll()
        selectedChannelKey = nil
        resetRouteStateLocked(for: nil)
        stateLock.unlock()

        cancelPendingRequest()
        publishTakeoverAxes(.none)
        publishBatteryState(.unavailable)
        transition(to: .unavailable)
        log("hidpp_controller_suspended", "invalidated old power generation")
    }

    // MARK: - Takeover transaction

    private func performTakeover(knownRouteOnly: Bool = false) throws -> State {
        transition(to: .discovering)
        // Receiver slot numbers and feature indices can change after reconnect;
        // Bluetooth always routes directly through 0xff. Resolve both feature
        // indices on every takeover instead of persisting addresses.
        let deviceIndex = try discoverDeviceIndex(knownRouteOnly: knownRouteOnly)
        let feature = try discoverFeature(
            HIDPPProtocol.hiResWheelFeatureID,
            deviceIndex: deviceIndex,
            timeout: 0.7
        )
        stateLock.lock()
        featureIndices[deviceIndex] = feature.index
        stateLock.unlock()

        // Transaction order is intentionally read -> save -> write -> read.
        // SetReport success confirms only USB/BLE transport delivery, not that
        // firmware accepted or persisted the requested mode.
        let originalMode = try getWheelMode(deviceIndex: deviceIndex, featureIndex: feature.index)
        let desiredMode = HIDPPProtocol.WheelMode.divertedHighResolution

        // Record pre-takeover state before the first mutating request. The write
        // can reach the mouse even if its response is lost; without this early
        // snapshot an error path could leave the physical wheel diverted and
        // make native scrolling appear broken after logi-mouse exits.
        stateLock.lock()
        if activeWheel == nil {
            activeWheel = ActiveWheel(
                deviceIndex: deviceIndex,
                featureIndex: feature.index,
                restoreMode: originalMode.nativeTarget
            )
        }
        stateLock.unlock()

        if originalMode != desiredMode {
            let written = try setWheelMode(
                desiredMode,
                deviceIndex: deviceIndex,
                featureIndex: feature.index
            )
            guard written == desiredMode else {
                throw HIDPPControllerError.verificationFailed(
                    expected: desiredMode.rawValue,
                    actual: written.rawValue
                )
            }
        }

        let readBack = try getWheelMode(deviceIndex: deviceIndex, featureIndex: feature.index)
        guard readBack == desiredMode else {
            throw HIDPPControllerError.verificationFailed(
                expected: desiredMode.rawValue,
                actual: readBack.rawValue
            )
        }
        setVerifiedTakeoverAxis(.vertical, enabled: true)

        // The thumbwheel is a separate physical sensor and HID++ feature with
        // separate reporting state. It cannot reuse the main wheel's feature
        // index or mode bits.
        let thumbwheelFeature = try discoverFeature(
            HIDPPProtocol.thumbwheelFeatureID,
            deviceIndex: deviceIndex,
            timeout: 0.7
        )
        stateLock.lock()
        thumbwheelFeatureIndices[deviceIndex] = thumbwheelFeature.index
        stateLock.unlock()
        let originalThumbwheelStatus = try getThumbwheelStatus(
            deviceIndex: deviceIndex,
            featureIndex: thumbwheelFeature.index
        )
        stateLock.lock()
        if activeThumbwheel == nil {
            activeThumbwheel = ActiveThumbwheel(
                deviceIndex: deviceIndex,
                featureIndex: thumbwheelFeature.index,
                restoreInverted: originalThumbwheelStatus.directionInverted
            )
        }
        stateLock.unlock()
        if originalThumbwheelStatus != .diverted {
            try setThumbwheelReporting(
                .diverted,
                deviceIndex: deviceIndex,
                featureIndex: thumbwheelFeature.index
            )
        }
        let thumbwheelReadBack = try getThumbwheelStatus(
            deviceIndex: deviceIndex,
            featureIndex: thumbwheelFeature.index
        )
        guard thumbwheelReadBack == .diverted else {
            throw HIDPPControllerError.verificationFailed(
                expected: 1,
                actual: thumbwheelReadBack.reportingMode
            )
        }
        setVerifiedTakeoverAxis(.horizontal, enabled: true)

        let ready = State.ready(
            deviceIndex: deviceIndex,
            featureIndex: feature.index,
            mode: readBack
        )
        transition(to: ready)
        log(
            "hidpp_takeover_ready",
            "wheel_feature_version=\(feature.version) original={\(originalMode)} applied={\(readBack)} "
                + "thumbwheel_feature_version=\(thumbwheelFeature.version) "
                + "thumbwheel_original={\(originalThumbwheelStatus)} thumbwheel_applied={\(thumbwheelReadBack)}"
        )
        return ready
    }

    /// Restores both axes independently and reports the first failure only after
    /// attempting both. Returning after one failed sensor would unnecessarily
    /// strand the other sensor in diverted mode.
    private func performRestore() throws -> State {
        stateLock.lock()
        let activeWheel = self.activeWheel
        let activeThumbwheel = self.activeThumbwheel
        stateLock.unlock()
        guard activeWheel != nil || activeThumbwheel != nil else {
            invalidateVerifiedTakeoverAxes()
            let transport = currentTransport()
            let newState: State = transport.map(State.channelReady) ?? .unavailable
            transition(to: newState)
            return newState
        }

        // Always attempt both restores. If one axis fails, returning early would
        // unnecessarily strand the other axis in diverted mode.
        var firstError: Error?
        var restoredDescriptions: [String] = []
        if let activeThumbwheel {
            do {
                let native = HIDPPProtocol.ThumbwheelStatus(
                    reportingMode: 0,
                    directionInverted: activeThumbwheel.restoreInverted
                )
                try setThumbwheelReporting(
                    native,
                    deviceIndex: activeThumbwheel.deviceIndex,
                    featureIndex: activeThumbwheel.featureIndex
                )
                let readBack = try getThumbwheelStatus(
                    deviceIndex: activeThumbwheel.deviceIndex,
                    featureIndex: activeThumbwheel.featureIndex
                )
                guard readBack == native else {
                    throw HIDPPControllerError.verificationFailed(
                        expected: native.reportingMode,
                        actual: readBack.reportingMode
                    )
                }
                stateLock.lock()
                self.activeThumbwheel = nil
                self.verifiedTakeoverAxes.horizontal = false
                let axes = self.verifiedTakeoverAxes
                stateLock.unlock()
                publishTakeoverAxes(axes)
                restoredDescriptions.append("thumbwheel={\(readBack)}")
            } catch {
                firstError = error
            }
        }
        if let activeWheel {
            do {
                let written = try setWheelMode(
                    activeWheel.restoreMode,
                    deviceIndex: activeWheel.deviceIndex,
                    featureIndex: activeWheel.featureIndex
                )
                guard written == activeWheel.restoreMode else {
                    throw HIDPPControllerError.verificationFailed(
                        expected: activeWheel.restoreMode.rawValue,
                        actual: written.rawValue
                    )
                }
                let readBack = try getWheelMode(
                    deviceIndex: activeWheel.deviceIndex,
                    featureIndex: activeWheel.featureIndex
                )
                guard readBack == activeWheel.restoreMode else {
                    throw HIDPPControllerError.verificationFailed(
                        expected: activeWheel.restoreMode.rawValue,
                        actual: readBack.rawValue
                    )
                }
                stateLock.lock()
                self.activeWheel = nil
                self.verifiedTakeoverAxes.vertical = false
                let axes = self.verifiedTakeoverAxes
                stateLock.unlock()
                publishTakeoverAxes(axes)
                restoredDescriptions.append("wheel={\(readBack)}")
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        guard let transport = currentTransport() else {
            transition(to: .unavailable)
            return .unavailable
        }
        let restoredState = State.channelReady(transport)
        transition(to: restoredState)
        log("hidpp_takeover_restored", restoredDescriptions.joined(separator: " "))
        return restoredState
    }

    // MARK: - Feature discovery and commands

    private func discoverDeviceIndex(knownRouteOnly: Bool) throws -> UInt8 {
        stateLock.lock()
        let preferred = observedDeviceIndex
        let directIndex = selectedChannelLocked()?.transport.directDeviceIndex
        stateLock.unlock()
        if let directIndex {
            return directIndex
        }
        // Prefer a slot learned from Receiver 0x41 or an earlier wheel event.
        // Event-driven reconnect normally has this route and avoids scanning.
        // A user-initiated takeover may still scan 1...6 once when no route is
        // known; failed recovery never schedules another scan by itself.
        var candidates: [UInt8] = []
        if let preferred { candidates.append(preferred) }
        if !knownRouteOnly || preferred == nil {
            candidates.append(contentsOf: (1...6).map(UInt8.init))
        }

        var visited = Set<UInt8>()
        for index in candidates where visited.insert(index).inserted {
            do {
                let feature = try discoverFeature(
                    HIDPPProtocol.hiResWheelFeatureID,
                    deviceIndex: index,
                    timeout: index == preferred
                        ? (knownRouteOnly ? 0.35 : 0.7)
                        : 0.25
                )
                stateLock.lock()
                observedDeviceIndex = index
                featureIndices[index] = feature.index
                stateLock.unlock()
                return index
            } catch HIDPPControllerError.featureUnsupported {
                continue
            } catch HIDPPControllerError.timeout {
                continue
            } catch HIDPPControllerError.deviceError {
                continue
            }
        }
        throw HIDPPControllerError.deviceNotFound
    }

    private func discoverFeature(
        _ featureID: UInt16,
        deviceIndex: UInt8,
        timeout: TimeInterval
    ) throws -> HIDPPProtocol.FeatureInformation {
        // Root function 0 accepts the stable 16-bit feature ID and returns the
        // device-specific 8-bit index used by every subsequent call/event.
        let response = try call(
            deviceIndex: deviceIndex,
            featureIndex: UInt8(HIDPPProtocol.rootFeatureID),
            functionID: 0,
            payload: HIDPPProtocol.rootFeaturePayload(featureID: featureID),
            timeout: timeout
        )
        guard let information = HIDPPProtocol.featureInformation(in: response) else {
            throw HIDPPControllerError.featureUnsupported(featureID)
        }
        log(
            "hidpp_feature_discovered",
            String(
                format: "device=%u feature_id=0x%04x index=0x%02x version=%u",
                deviceIndex,
                featureID,
                information.index,
                information.version
            )
        )
        return information
    }

    // MARK: - Battery

    private func refreshBattery(after delay: TimeInterval) {
        stateLock.lock()
        guard selectedChannelLocked() != nil else {
            stateLock.unlock()
            publishBatteryState(.unavailable)
            return
        }
        guard !batteryRefreshScheduled else {
            stateLock.unlock()
            return
        }
        batteryRefreshScheduled = true
        let generation = routeGeneration
        stateLock.unlock()

        publishBatteryState(.loading)
        operationQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let result: Result<HIDPPProtocol.BatteryInfo, Error>
            do {
                result = .success(try self.readBattery())
            } catch {
                result = .failure(error)
            }

            self.stateLock.lock()
            self.batteryRefreshScheduled = false
            let currentGeneration = self.routeGeneration
            let hasChannel = self.selectedChannelLocked() != nil
            self.stateLock.unlock()

            guard generation == currentGeneration else {
                if hasChannel { self.refreshBattery(after: 0.15) }
                return
            }

            switch result {
            case let .success(battery):
                self.publishBatteryState(.available(battery))
                self.log(
                    "hidpp_battery_read",
                    "level=\(battery.percentage.map(String.init) ?? "approximate") "
                        + "state=\(battery.chargingState)"
                )
            case let .failure(error):
                self.publishBatteryState(.unavailable)
                self.log("hidpp_battery_read_failed", error.localizedDescription)
            }
        }
    }

    private func readBattery() throws -> HIDPPProtocol.BatteryInfo {
        let deviceIndex = try discoverDeviceIndex(knownRouteOnly: false)
        stateLock.lock()
        let cachedFeature = batteryFeatures[deviceIndex]
        stateLock.unlock()

        let feature: HIDPPProtocol.BatteryFeature
        if let cachedFeature {
            feature = cachedFeature
        } else {
            feature = try discoverBatteryFeature(deviceIndex: deviceIndex)
            stateLock.lock()
            batteryFeatures[deviceIndex] = feature
            stateLock.unlock()
        }

        let response = try call(
            deviceIndex: deviceIndex,
            featureIndex: feature.index,
            functionID: feature.statusFunctionID,
            payload: [0, 0, 0],
            timeout: 0.7
        )
        guard let battery = HIDPPProtocol.batteryInfo(
            in: response,
            feature: feature
        ) else {
            throw HIDPPControllerError.unexpectedResponse
        }
        return battery
    }

    private func discoverBatteryFeature(
        deviceIndex: UInt8
    ) throws -> HIDPPProtocol.BatteryFeature {
        do {
            let feature = try discoverFeature(
                HIDPPProtocol.unifiedBatteryFeatureID,
                deviceIndex: deviceIndex,
                timeout: 0.7
            )
            return .unified(index: feature.index)
        } catch HIDPPControllerError.featureUnsupported {
            let feature = try discoverFeature(
                HIDPPProtocol.batteryStatusFeatureID,
                deviceIndex: deviceIndex,
                timeout: 0.7
            )
            return .legacy(index: feature.index)
        }
    }

    private func getWheelMode(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        quietly: Bool = false
    ) throws -> HIDPPProtocol.WheelMode {
        // Feature 0x2121 function 1 reads the current mode bit field.
        let response = try call(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 1,
            payload: [0, 0, 0],
            timeout: 0.7,
            quietly: quietly
        )
        guard let mode = HIDPPProtocol.wheelMode(in: response) else {
            throw HIDPPControllerError.unexpectedResponse
        }
        if !quietly {
            log("hidpp_wheel_mode_read", mode.description)
        }
        return mode
    }

    private func setWheelMode(
        _ mode: HIDPPProtocol.WheelMode,
        deviceIndex: UInt8,
        featureIndex: UInt8
    ) throws -> HIDPPProtocol.WheelMode {
        // Feature 0x2121 function 2 writes the mode. The response is parsed and
        // the caller performs an additional GetMode read-back.
        let response = try call(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 2,
            payload: [mode.rawValue, 0, 0],
            timeout: 0.7
        )
        guard let written = HIDPPProtocol.wheelMode(in: response) else {
            throw HIDPPControllerError.unexpectedResponse
        }
        log("hidpp_wheel_mode_written", written.description)
        return written
    }

    private func getThumbwheelStatus(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        quietly: Bool = false
    ) throws -> HIDPPProtocol.ThumbwheelStatus {
        // Feature 0x2150 function 1 returns reporting mode and inversion.
        let response = try call(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 1,
            payload: [0, 0, 0],
            timeout: 0.7,
            quietly: quietly
        )
        guard let status = HIDPPProtocol.thumbwheelStatus(in: response) else {
            throw HIDPPControllerError.unexpectedResponse
        }
        if !quietly {
            log("hidpp_thumbwheel_status_read", status.description)
        }
        return status
    }

    private func setThumbwheelReporting(
        _ status: HIDPPProtocol.ThumbwheelStatus,
        deviceIndex: UInt8,
        featureIndex: UInt8
    ) throws {
        // Feature 0x2150 function 2 changes reporting mode. Unlike 0x2121 it
        // does not return the same compact mode value, so the transaction is
        // verified by a separate GetStatus in the caller.
        _ = try call(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 2,
            payload: [status.reportingMode, status.directionInverted ? 1 : 0, 0],
            timeout: 0.7
        )
        log("hidpp_thumbwheel_status_written", status.description)
    }

    /// Sends one HID++ long request and synchronously waits for its exact reply.
    /// Must run on `operationQueue`; concurrent requests would overwrite the
    /// single `pendingRequest` slot and make four-bit software tags ambiguous.
    private func call(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        payload: [UInt8],
        timeout: TimeInterval,
        quietly: Bool = false
    ) throws -> [UInt8] {
        guard let channel = currentChannel() else {
            throw HIDPPControllerError.noHIDPPChannel
        }
        // A connection can switch while a takeover transaction is discovering
        // features. Never send a Receiver slot route to a direct Bluetooth
        // channel, or the Bluetooth 0xff route to a Receiver.
        switch channel.transport {
        case .usbReceiver where deviceIndex == 0xff,
             .bluetooth where deviceIndex != 0xff:
            throw HIDPPControllerError.transportChanged
        default:
            break
        }
        let device = channel.device
        let header = HIDPPProtocol.RequestHeader(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: functionID,
            softwareID: takeSoftwareID()
        )
        let report = HIDPPProtocol.makeLongRequest(header: header, payload: payload)

        // Publish the expected header before sending. A fast HID++ channel can call
        // back from IOKit immediately after SetReport; publishing afterward
        // would race and lose a valid response.
        condition.lock()
        pendingRequest = PendingRequest(header: header)
        condition.unlock()

        // IOHIDDeviceSetReport copies the 20-byte output report synchronously;
        // the buffer only needs to remain valid for the duration of this call.
        let result: IOReturn = report.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPPProtocol.longReportID),
                baseAddress,
                report.count
            )
        }
        guard result == kIOReturnSuccess else {
            clearPendingRequest()
            throw HIDPPControllerError.writeFailed(result)
        }
        if !quietly {
            log(
                "hidpp_request",
                String(
                    format: "device=%u feature=0x%02x function=%u swid=%u payload=%@",
                    deviceIndex,
                    featureIndex,
                    functionID,
                    header.softwareID,
                    payload.map { String(format: "%02x", $0) }.joined()
                )
            )
        }

        // `observeReport` signals this condition only for a byte-for-byte header
        // match (or the corresponding HID++ error envelope), so normal wheel
        // notifications cannot accidentally complete a control request.
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        while pendingRequest?.response == nil {
            if !condition.wait(until: deadline) { break }
        }
        let response = pendingRequest?.response
        pendingRequest = nil
        condition.unlock()

        guard let response else { throw HIDPPControllerError.timeout }
        if let error = HIDPPProtocol.errorCode(in: response) {
            throw HIDPPControllerError.deviceError(error)
        }
        if !quietly {
            log(
                "hidpp_response",
                response.map { String(format: "%02x", $0) }.joined()
            )
        }
        return response
    }

    // MARK: - Event-driven verification and reconnect

    /// Schedules at most one recovery for one device lifecycle event. Failure
    /// intentionally does not recurse; the next BLE arrival, Receiver 0x41
    /// notification or explicit window-open verification is required.
    private func scheduleReacquire(after delay: TimeInterval) {
        operationQueue.async { [weak self] in
            guard let self, !self.reacquireAttemptScheduled else { return }
            self.reacquireAttemptScheduled = true
            self.operationQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.reacquireAttemptScheduled = false
                guard self.isTakeoverRequested,
                      self.currentDevice() != nil,
                      !self.hasActiveWheel else {
                    return
                }
                do {
                    let ready = try self.performTakeover(knownRouteOnly: false)
                    self.log("hidpp_reacquire_ready", ready.description)
                } catch {
                    self.transition(to: .failed(error.localizedDescription))
                    self.log("hidpp_reacquire_failed", error.localizedDescription)
                }
            }
        }
    }

    /// Reads both physical sensor modes and repairs drift only after comparing
    /// firmware state. Any missing response invalidates verified suppression
    /// immediately; a later device event or window open may trigger recovery.
    private func verifyActiveMode() throws -> HIDPPTakeoverAxes {
        stateLock.lock()
        let activeWheel = self.activeWheel
        let activeThumbwheel = self.activeThumbwheel
        stateLock.unlock()
        guard let activeWheel else { throw HIDPPControllerError.deviceNotFound }

        let desiredMode = HIDPPProtocol.WheelMode.divertedHighResolution
        do {
            let observed = try getWheelMode(
                deviceIndex: activeWheel.deviceIndex,
                featureIndex: activeWheel.featureIndex,
                quietly: true
            )
            if observed != desiredMode {
                log(
                    "hidpp_mode_drift_detected",
                    "observed={\(observed)} expected={\(desiredMode)}"
                )
                let written = try setWheelMode(
                    desiredMode,
                    deviceIndex: activeWheel.deviceIndex,
                    featureIndex: activeWheel.featureIndex
                )
                guard written == desiredMode else {
                    throw HIDPPControllerError.verificationFailed(
                        expected: desiredMode.rawValue,
                        actual: written.rawValue
                    )
                }
                let readBack = try getWheelMode(
                    deviceIndex: activeWheel.deviceIndex,
                    featureIndex: activeWheel.featureIndex
                )
                guard readBack == desiredMode else {
                    throw HIDPPControllerError.verificationFailed(
                        expected: desiredMode.rawValue,
                        actual: readBack.rawValue
                    )
                }
                log("hidpp_mode_reasserted", readBack.description)
            }
            if let activeThumbwheel {
                let thumbwheelObserved = try getThumbwheelStatus(
                    deviceIndex: activeThumbwheel.deviceIndex,
                    featureIndex: activeThumbwheel.featureIndex,
                    quietly: true
                )
                if thumbwheelObserved != .diverted {
                    log(
                        "hidpp_thumbwheel_mode_drift_detected",
                        "observed={\(thumbwheelObserved)} expected={\(HIDPPProtocol.ThumbwheelStatus.diverted)}"
                    )
                    try setThumbwheelReporting(
                        .diverted,
                        deviceIndex: activeThumbwheel.deviceIndex,
                        featureIndex: activeThumbwheel.featureIndex
                    )
                    let thumbwheelReadBack = try getThumbwheelStatus(
                        deviceIndex: activeThumbwheel.deviceIndex,
                        featureIndex: activeThumbwheel.featureIndex
                    )
                    guard thumbwheelReadBack == .diverted else {
                        throw HIDPPControllerError.verificationFailed(
                            expected: 1,
                            actual: thumbwheelReadBack.reportingMode
                        )
                    }
                    log("hidpp_thumbwheel_mode_reasserted", thumbwheelReadBack.description)
                }
            }
            stateLock.lock()
            verifiedTakeoverAxes.vertical = true
            verifiedTakeoverAxes.horizontal = activeThumbwheel != nil
            let axes = verifiedTakeoverAxes
            stateLock.unlock()
            publishTakeoverAxes(axes)
            transition(to: .ready(
                deviceIndex: activeWheel.deviceIndex,
                featureIndex: activeWheel.featureIndex,
                mode: desiredMode
            ))
            return axes
        } catch {
            // A missing response means the active mouse is gone or asleep.
            // Bluetooth arrival, Receiver 0x41 or reopening the control window
            // will trigger one recovery attempt.
            stateLock.lock()
            self.activeWheel = nil
            self.activeThumbwheel = nil
            self.featureIndices.removeAll()
            self.thumbwheelFeatureIndices.removeAll()
            self.verifiedTakeoverAxes = .none
            stateLock.unlock()
            publishTakeoverAxes(.none)
            transition(to: .unavailable)
            log("hidpp_mode_verification_failed", error.localizedDescription)
            throw error
        }
    }

    // MARK: - Thread-safe state helpers

    private func clearPendingRequest() {
        condition.lock()
        pendingRequest = nil
        condition.broadcast()
        condition.unlock()
    }

    private func currentDevice() -> IOHIDDevice? {
        currentChannel()?.device
    }

    private func currentChannel() -> Channel? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedChannelLocked()
    }

    private func currentTransport() -> HIDPPTransport? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedChannelLocked()?.transport
    }

    private func preferredChannelKeyLocked() -> UInt? {
        channels.values.max { lhs, rhs in
            if lhs.transport.selectionPriority == rhs.transport.selectionPriority {
                return lhs.key < rhs.key
            }
            return lhs.transport.selectionPriority < rhs.transport.selectionPriority
        }?.key
    }

    private func selectedChannelLocked() -> Channel? {
        guard let selectedChannelKey else { return nil }
        return channels[selectedChannelKey]
    }

    /// Route addresses are valid only within one physical transport. Clearing
    /// them on a channel switch prevents a Receiver slot/feature index from
    /// being written to a Bluetooth device (or the reverse). For Bluetooth the
    /// direct route is known up-front, while feature indices remain discoverable.
    private func resetRouteStateLocked(for transport: HIDPPTransport?) {
        observedDeviceIndex = transport?.directDeviceIndex
        featureIndices.removeAll()
        thumbwheelFeatureIndices.removeAll()
        batteryFeatures.removeAll()
        activeWheel = nil
        activeThumbwheel = nil
        verifiedTakeoverAxes = .none
        routeGeneration &+= 1
    }

    private func cancelPendingRequest() {
        condition.lock()
        pendingRequest = nil
        condition.broadcast()
        condition.unlock()
    }

    private var hasActiveWheel: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeWheel != nil
    }

    private var isTakeoverRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return takeoverRequested
    }

    private func setTakeoverRequested(_ requested: Bool) {
        stateLock.lock()
        takeoverRequested = requested
        stateLock.unlock()
    }

    private func setVerifiedTakeoverAxis(_ axis: ScrollAxis, enabled: Bool) {
        stateLock.lock()
        switch axis {
        case .vertical: verifiedTakeoverAxes.vertical = enabled
        case .horizontal: verifiedTakeoverAxes.horizontal = enabled
        }
        let axes = verifiedTakeoverAxes
        stateLock.unlock()
        publishTakeoverAxes(axes)
    }

    private func invalidateVerifiedTakeoverAxes() {
        stateLock.lock()
        let changed = !verifiedTakeoverAxes.isEmpty
        verifiedTakeoverAxes = .none
        stateLock.unlock()
        if changed { publishTakeoverAxes(.none) }
    }

    private func publishTakeoverAxes(_ axes: HIDPPTakeoverAxes) {
        DispatchQueue.main.async { [weak self] in
            self?.onTakeoverAxesChange?(axes)
        }
    }

    private func publishBatteryState(_ state: HIDPPBatteryState) {
        DispatchQueue.main.async { [weak self] in
            self?.onBatteryStateChange?(state)
        }
    }

    private func takeSoftwareID() -> UInt8 {
        defer {
            nextSoftwareID = nextSoftwareID == 0x0f ? 0x01 : nextSoftwareID + 1
        }
        return nextSoftwareID
    }

    private func transition(to state: State) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    private func log(_ layer: String, _ message: String) {
        onLog?(layer, message)
    }
}
