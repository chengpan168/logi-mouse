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
    case receiverNotificationsNotEnabled(actual: UInt8)

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
        case let .receiverNotificationsNotEnabled(actual):
            String(
                format: "Receiver wireless notifications were not enabled after read-back (receiver flags 0x%02x).",
                actual
            )
        }
    }
}

/// De-duplicates Receiver link notifications by slot and connection edge.
///
/// Receivers may emit multiple 0x41 reports while a mouse remains online (for
/// example when link metadata changes). Treating each report as a fresh device
/// arrival would restart the complete HID++ takeover transaction and compete
/// with the mouse's input reports. The tracker is protected by the controller's
/// `stateLock`; it is kept as a value type so the edge semantics stay directly
/// unit-testable without constructing an IOHIDDevice.
struct ReceiverConnectionEdgeTracker: Sendable {
    private var states: [UInt8: Bool] = [:]

    mutating func accept(deviceIndex: UInt8, connected: Bool) -> Bool {
        if let previous = states[deviceIndex], previous == connected {
            return false
        }
        states[deviceIndex] = connected
        return true
    }

    mutating func reset() {
        states.removeAll(keepingCapacity: false)
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
/// `stateLock` protects device/lifecycle state shared with IOKit callbacks;
/// `HIDPPRequestSession` owns response pairing and request timeouts.
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


    /// Serializes hardware requests, mode transactions and explicit verification.
    private let operationQueue: DispatchQueue
    private let requestSession = HIDPPRequestSession()
    private let deviceServices: HIDPPDeviceServiceCoordinator
    /// Protects routing and mode state touched by IOKit and operationQueue.
    private let stateLock = NSLock()
    private var channels: [UInt: HIDPPCommandChannel] = [:]
    private struct HardwareSession {
        var generation: UInt64 = 0
        var channelKey: UInt?
        var receiverConnectionEdges = ReceiverConnectionEdgeTracker()
        var observedDeviceIndex: UInt8?
        var featureIndices: [UInt8: UInt8] = [:]
        var thumbwheelFeatureIndices: [UInt8: UInt8] = [:]
        var batteryFeatures: [UInt8: HIDPPProtocol.BatteryFeature] = [:]
        // Pending restoration survives verification failure until restore succeeds.
        var activeWheel: ActiveWheel?
        var activeThumbwheel: ActiveThumbwheel?
        var verifiedTakeoverAxes = HIDPPTakeoverAxes.none
    }

    private struct Route {
        let channel: HIDPPCommandChannel
        let generation: UInt64
    }

    private var session = HardwareSession()
    // Confined to operationQueue; every request in a transaction uses this route.
    private var operationRoute: Route?
    private let operationQueueKey = DispatchSpecificKey<Void>()

    init() {
        let queue = DispatchQueue(label: "dev.logi-mouse.hidpp-controller")
        operationQueue = queue
        deviceServices = HIDPPDeviceServiceCoordinator(operationQueue: queue)
        operationQueue.setSpecific(key: operationQueueKey, value: ())
    }

    // MARK: - HID++ channel lifecycle

    /// Adds a physical control interface and selects the preferred transport.
    /// Bluetooth wins while present because an inserted Receiver does not prove
    /// its paired mouse is currently using that radio path.
    func considerDevice(
        _ device: IOHIDDevice,
        key: UInt,
        transport: HIDPPTransport
    ) {
        let requestSession = requestSession
        let log: (String, String) -> Void = { [weak self] layer, message in
            self?.log(layer, message)
        }
        considerChannel(HIDPPCommandChannel(key: key, transport: transport) { request in
            switch request {
            case let .feature(index, feature, function, payload, timeout, quietly):
                return try requestSession.send(
                    device: device, transport: transport, deviceIndex: index,
                    featureIndex: feature, functionID: function, payload: payload,
                    timeout: timeout, quietly: quietly, log: log
                )
            case let .receiverRegister(subID, address, parameters, timeout):
                return try requestSession.sendShortRegister(
                    device: device, subID: subID, address: address,
                    parameters: parameters, timeout: timeout, log: log
                )
            }
        })
    }

    func considerChannel(_ channel: HIDPPCommandChannel) {
        stateLock.lock()
        channels[channel.key] = channel
        let previousKey = session.channelKey
        session.channelKey = preferredChannelKeyLocked()
        let selected = selectedChannelLocked()
        let channelChanged = previousKey != session.channelKey
        if channelChanged {
            resetRouteStateLocked(for: selected?.transport)
        }
        let selectedRouteGeneration = session.generation
        stateLock.unlock()

        if channelChanged { publishTakeoverAxes(.none) }

        guard channelChanged, let selected else { return }
        cancelPendingRequest()
        transition(to: .channelReady(selected.transport))
        log("hidpp_controller_device", "selected \(selected.transport) HID++ channel")
        prepareSelectedChannel(
            selected,
            generation: selectedRouteGeneration
        )
    }

    /// Removes a physical interface. If Bluetooth disappears while a Receiver
    /// remains inserted, recovery waits for Receiver link/activity evidence
    /// instead of immediately scanning dormant slots in a loop.
    func removeDevice(key: UInt) {
        stateLock.lock()
        let wasSelected = session.channelKey == key
        channels.removeValue(forKey: key)
        if wasSelected {
            session.channelKey = preferredChannelKeyLocked()
        }
        let replacement = selectedChannelLocked()
        if wasSelected { resetRouteStateLocked(for: replacement?.transport) }
        let replacementRouteGeneration = session.generation
        stateLock.unlock()

        if wasSelected {
            publishTakeoverAxes(.none)
            publishBatteryState(.unavailable)
            cancelPendingRequest()
            if let replacement {
                transition(to: .channelReady(replacement.transport))
                log("hidpp_controller_device", "fell back to \(replacement.transport) HID++ channel")
                prepareSelectedChannel(
                    replacement,
                    generation: replacementRouteGeneration
                )
            } else {
                transition(to: .unavailable)
                log("hidpp_controller_device_removed", "active HID++ channel removed")
            }
        }
    }

    /// Accepts HID++ 1.0 short and HID++ 2.0 long input before event decoding.
    /// Exact replies wake the shared request session. Unsolicited notifications
    /// never match unless their complete response header belongs to the pending
    /// command, so Receiver lifecycle and wheel events remain asynchronous.
    @discardableResult
    func observeReport(_ report: [UInt8]) -> Bool {
        let matchedPendingRequest = requestSession.observe(report)
        guard !matchedPendingRequest else { return true }
        guard report.count == HIDPPProtocol.longReportLength,
              report.first == HIDPPProtocol.longReportID,
              report[3] == 0 else { return false }
        stateLock.lock()
        let batteryFeature = session.batteryFeatures[report[1]]
        stateLock.unlock()
        guard batteryFeature?.index == report[2],
              let batteryFeature,
              let battery = HIDPPProtocol.batteryInfo(
                  in: report,
                  feature: batteryFeature
              ) else { return false }
        publishBatteryState(.available(battery))
        return false
    }

    /// Handles Receiver radio-link changes. The USB dongle's IOHIDInterface
    /// does not disappear when the mouse powers off, so reports 0x10/0x40 and
    /// 0x10/0x41 are the authoritative offline/online signals. Events from a
    /// keyboard or another unobserved slot must not invalidate the mouse route.
    func observeReceiverConnection(
        deviceKey: UInt,
        event: HIDPPProtocol.ReceiverConnectionEvent
    ) {
        stateLock.lock()
        let isSelectedReceiver = session.channelKey == deviceKey
            && channels[deviceKey]?.transport == .usbReceiver
        guard isSelectedReceiver else {
            stateLock.unlock()
            log(
                "hidpp_receiver_event_ignored",
                String(
                    format: "slot=%u sub_id=0x%02x reason=non-selected-receiver",
                    event.deviceIndex,
                    event.notificationSubID
                )
            )
            return
        }
        if event.isConnected, !event.isPotentialPointingDevice {
            stateLock.unlock()
            log(
                "hidpp_receiver_event_ignored",
                String(
                    format: "slot=%u sub_id=0x%02x device_type=0x%02x reason=non-pointing-device",
                    event.deviceIndex,
                    event.notificationSubID,
                    event.deviceType ?? 0xff
                )
            )
            return
        }
        if !event.isConnected, session.observedDeviceIndex != event.deviceIndex {
            let observed = session.observedDeviceIndex.map(String.init) ?? "none"
            stateLock.unlock()
            log(
                "hidpp_receiver_event_ignored",
                String(
                    format: "slot=%u sub_id=0x%02x reason=not-observed-mouse observed_slot=%@",
                    event.deviceIndex,
                    event.notificationSubID,
                    observed
                )
            )
            return
        }
        guard session.receiverConnectionEdges.accept(
            deviceIndex: event.deviceIndex,
            connected: event.isConnected
        ) else {
            stateLock.unlock()
            log(
                "hidpp_receiver_event_ignored",
                String(
                    format: "slot=%u sub_id=0x%02x connected=%@ reason=duplicate-link-edge",
                    event.deviceIndex,
                    event.notificationSubID,
                    event.isConnected ? "true" : "false"
                )
            )
            return
        }
        var readyGeneration: UInt64?
        if event.isConnected {
            session.observedDeviceIndex = event.deviceIndex
            readyGeneration = session.generation
        }
        if !event.isConnected {
            session.activeWheel = nil
            session.activeThumbwheel = nil
            session.featureIndices.removeAll()
            session.thumbwheelFeatureIndices.removeAll()
            session.batteryFeatures.removeAll()
            session.verifiedTakeoverAxes = .none
            session.generation &+= 1
        }
        let routeGenerationSnapshot = session.generation
        stateLock.unlock()

        if !event.isConnected { publishTakeoverAxes(.none) }

        if event.isConnected {
            if let readyGeneration {
                deviceServices.markDeviceReady(generation: readyGeneration)
            }
            log(
                "hidpp_receiver_connected",
                String(
                    format: "slot=%u sub_id=0x%02x device_type=0x%02x detail=0x%02x route_generation=%llu",
                    event.deviceIndex,
                    event.notificationSubID,
                    event.deviceType ?? 0xff,
                    event.detail,
                    readyGeneration ?? 0
                )
            )
            transition(to: .deviceReady(.usbReceiver))
            refreshBattery(after: 0)
        } else {
            publishBatteryState(.unavailable)
            cancelPendingRequest()
            transition(to: .unavailable)
            log(
                "hidpp_receiver_disconnected",
                String(
                    format: "slot=%u sub_id=0x%02x detail=0x%02x new_route_generation=%llu",
                    event.deviceIndex,
                    event.notificationSubID,
                    event.detail,
                    routeGenerationSnapshot
                )
            )
        }
    }

    func observeWheelRoute(deviceIndex: UInt8, featureIndex: UInt8) {
        stateLock.lock()
        session.observedDeviceIndex = deviceIndex
        session.featureIndices[deviceIndex] = featureIndex
        stateLock.unlock()
    }

    func observeThumbwheelRoute(deviceIndex: UInt8, featureIndex: UInt8) {
        stateLock.lock()
        session.observedDeviceIndex = deviceIndex
        session.thumbwheelFeatureIndices[deviceIndex] = featureIndex
        stateLock.unlock()
    }

    /// Performs one read-back requested by a low-frequency lifecycle event,
    /// such as reopening the control window. Scroll traffic never calls this.
    func verifyMode(
        completion: @escaping (Result<HIDPPTakeoverAxes, Error>) -> Void = { _ in }
    ) {
        runOperation(completion: completion) {
            guard self.hasActiveWheel else { throw HIDPPControllerError.deviceNotFound }
            return try self.verifyActiveMode()
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
        return session.featureIndices[deviceIndex]
    }

    func thumbwheelFeatureIndex(for deviceIndex: UInt8) -> UInt8? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session.thumbwheelFeatureIndices[deviceIndex]
    }

    func acceptsDevice(key: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session.channelKey == key
    }

    // MARK: - Public takeover lifecycle

    /// Begins the all-axis hardware transaction on `operationQueue`.
    /// Completion is delivered on the main queue for direct UI consumption.
    func takeOverWheel(completion: @escaping (Result<State, Error>) -> Void) {
        runOperation(completion: completion) {
            do {
                return try self.performTakeover()
            } catch {
                // Saved modes exist before each write, including a write whose
                // reply was lost. Roll back every modified axis on this route.
                do {
                    _ = try self.performRestore()
                } catch {
                    self.log("hidpp_restore_after_takeover_failure_failed", error.localizedDescription)
                }
                self.invalidateVerifiedTakeoverAxes()
                self.transition(to: .failed(error.localizedDescription))
                throw error
            }
        }
    }

    func restoreWheel(completion: @escaping (Result<State, Error>) -> Void) {
        guard let route = currentRoute() else {
            DispatchQueue.main.async { completion(.success(.unavailable)) }
            return
        }
        runOperation(route: route, completion: completion) {
            do {
                return try self.performRestore()
            } catch {
                self.invalidateVerifiedTakeoverAxes()
                self.transition(to: .failed(error.localizedDescription))
                throw error
            }
        }
    }

    /// Input replies arrive on HIDMonitor's queue while shutdown waits here.
    func restoreSynchronously() {
        guard let route = currentRoute() else { return }
        operationQueue.sync {
            do {
                _ = try withRoute(route) { try performRestore() }
            } catch {
                log("hidpp_restore_failed", error.localizedDescription)
            }
        }
    }

    /// Closes the physical session after restoration or before sleeping. Queued
    /// operations and main-queue publications cannot revive the retired route.
    func invalidateSession() {
        stateLock.lock()
        channels.removeAll()
        session.channelKey = nil
        resetRouteStateLocked(for: nil)
        stateLock.unlock()

        cancelPendingRequest()
        publishTakeoverAxes(.none)
        publishBatteryState(.unavailable)
        transition(to: .unavailable)
        log("hidpp_controller_suspended", "invalidated old power generation")
    }

    // MARK: - Takeover transaction

    private func performTakeover() throws -> State {
        transition(to: .discovering)
        // Receiver slot numbers and feature indices can change after reconnect;
        // Bluetooth always routes directly through 0xff. Resolve both feature
        // indices on every takeover instead of persisting addresses.
        let deviceIndex = try discoverDeviceIndex()
        let feature = try discoverFeature(
            HIDPPProtocol.hiResWheelFeatureID,
            deviceIndex: deviceIndex,
            timeout: 0.7
        )
        try mutateSession { $0.featureIndices[deviceIndex] = feature.index }

        // Transaction order is intentionally read -> save -> write -> read.
        // SetReport success confirms only USB/BLE transport delivery, not that
        // firmware accepted or persisted the requested mode.
        let originalMode = try getWheelMode(deviceIndex: deviceIndex, featureIndex: feature.index)
        let desiredMode = HIDPPProtocol.WheelMode.divertedHighResolution

        // Record pre-takeover state before the first mutating request. The write
        // can reach the mouse even if its response is lost; without this early
        // snapshot an error path could leave the physical wheel diverted and
        // make native scrolling appear broken after logi-mouse exits.
        try mutateSession {
            if $0.activeWheel == nil {
                $0.activeWheel = ActiveWheel(
                    deviceIndex: deviceIndex, featureIndex: feature.index,
                    restoreMode: originalMode.nativeTarget
                )
            }
        }

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
        try setVerifiedTakeoverAxis(.vertical, enabled: true)

        // The thumbwheel is a separate physical sensor and HID++ feature with
        // separate reporting state. It cannot reuse the main wheel's feature
        // index or mode bits.
        let thumbwheelFeature = try discoverFeature(
            HIDPPProtocol.thumbwheelFeatureID,
            deviceIndex: deviceIndex,
            timeout: 0.7
        )
        try mutateSession { $0.thumbwheelFeatureIndices[deviceIndex] = thumbwheelFeature.index }
        let originalThumbwheelStatus = try getThumbwheelStatus(
            deviceIndex: deviceIndex,
            featureIndex: thumbwheelFeature.index
        )
        try mutateSession {
            if $0.activeThumbwheel == nil {
                $0.activeThumbwheel = ActiveThumbwheel(
                    deviceIndex: deviceIndex, featureIndex: thumbwheelFeature.index,
                    restoreInverted: originalThumbwheelStatus.directionInverted
                )
            }
        }
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
        try setVerifiedTakeoverAxis(.horizontal, enabled: true)

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
        let (activeWheel, activeThumbwheel) = try mutateSession { ($0.activeWheel, $0.activeThumbwheel) }
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
                let axes = try mutateSession {
                    $0.activeThumbwheel = nil
                    $0.verifiedTakeoverAxes.horizontal = false
                    return $0.verifiedTakeoverAxes
                }
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
                let axes = try mutateSession {
                    $0.activeWheel = nil
                    $0.verifiedTakeoverAxes.vertical = false
                    return $0.verifiedTakeoverAxes
                }
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

    private func discoverDeviceIndex() throws -> UInt8 {
        let preferred = try mutateSession { $0.observedDeviceIndex }
        let directIndex = operationRoute?.channel.transport.directDeviceIndex
        if let directIndex {
            return directIndex
        }
        // Prefer a slot learned from Receiver 0x41 or an earlier wheel event.
        // Event-driven reconnect normally has this route and avoids scanning.
        // A user-initiated takeover may still scan 1...6 once when no route is
        // known. The controller never loops on its own; the application-level
        // wake policy may explicitly request a bounded sequence of retries.
        var candidates: [UInt8] = []
        if let preferred { candidates.append(preferred) }
        candidates.append(contentsOf: (1...6).map(UInt8.init))

        var visited = Set<UInt8>()
        for index in candidates where visited.insert(index).inserted {
            do {
                let feature = try discoverFeature(
                    HIDPPProtocol.hiResWheelFeatureID,
                    deviceIndex: index,
                    timeout: index == preferred ? 0.7 : 0.25
                )
                try mutateSession {
                    $0.observedDeviceIndex = index
                    $0.featureIndices[index] = feature.index
                }
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

    // MARK: - Receiver notification subscription

    /// Completes transport-specific preparation before readiness probing. The
    /// raw input callback is already installed by HIDMonitor at this point, so
    /// short-register replies and an early 0x40/0x41 notification cannot race
    /// ahead of callback registration.
    private func prepareSelectedChannel(
        _ channel: HIDPPCommandChannel,
        generation: UInt64
    ) {
        guard channel.transport == .usbReceiver else {
            probeDeviceReadiness()
            return
        }

        log(
            "hidpp_receiver_notifications_prepare_scheduled",
            String(
                format: "route_generation=%llu channel_key=0x%llx",
                generation,
                channel.key
            )
        )
        operationQueue.async { [weak self] in
            guard let self else { return }
            guard self.selectedChannelIsCurrent(
                key: channel.key,
                generation: generation
            ) else {
                self.log(
                    "hidpp_receiver_notifications_prepare_discarded",
                    String(
                        format: "route_generation=%llu channel_key=0x%llx reason=stale-route-before-start",
                        generation,
                        channel.key
                    )
                )
                return
            }

            do {
                try self.withRoute(Route(channel: channel, generation: generation)) {
                    try self.enableReceiverWirelessNotifications()
                }
            } catch {
                // Notification subscription improves event-driven recovery but
                // is not a prerequisite for direct probing. Continue so older
                // or unusual Receiver firmware retains the existing behavior.
                self.log(
                    "hidpp_receiver_notifications_enable_failed",
                    "route_generation=\(generation) error=\(error.localizedDescription)"
                )
            }

            guard self.selectedChannelIsCurrent(
                key: channel.key,
                generation: generation
            ) else {
                self.log(
                    "hidpp_receiver_notifications_prepare_discarded",
                    String(
                        format: "route_generation=%llu channel_key=0x%llx reason=stale-route-after-configuration",
                        generation,
                        channel.key
                    )
                )
                return
            }
            self.probeDeviceReadiness()
        }
    }

    /// Enables Receiver register 0x00/r1 bit 0 with read-modify-write semantics.
    /// Other applications may own adjacent notification bits, so their values
    /// are preserved rather than replaced with a hard-coded flag set.
    private func enableReceiverWirelessNotifications() throws {
        let initialResponse = try callReceiverRegister(
            subID: HIDPPProtocol.getShortRegisterSubID,
            address: HIDPPProtocol.receiverNotificationRegister,
            parameters: [0, 0, 0],
            timeout: 0.7
        )
        guard let initial = HIDPPProtocol.receiverNotificationFlags(in: initialResponse) else {
            log(
                "hidpp_receiver_notifications_read_invalid",
                "raw=\(initialResponse.map { String(format: "%02x", $0) }.joined())"
            )
            throw HIDPPControllerError.unexpectedResponse
        }
        log("hidpp_receiver_notifications_read", "before={\(initial)}")

        let desired = initial.enablingWirelessNotifications
        if desired != initial {
            log(
                "hidpp_receiver_notifications_write_requested",
                "before={\(initial)} desired={\(desired)} preserved_other_bits=true"
            )
            _ = try callReceiverRegister(
                subID: HIDPPProtocol.setShortRegisterSubID,
                address: HIDPPProtocol.receiverNotificationRegister,
                parameters: desired.parameters,
                timeout: 0.7
            )
            log("hidpp_receiver_notifications_write_acknowledged", "desired={\(desired)}")
        } else {
            log("hidpp_receiver_notifications_already_enabled", "flags={\(initial)}")
        }

        let verificationResponse = try callReceiverRegister(
            subID: HIDPPProtocol.getShortRegisterSubID,
            address: HIDPPProtocol.receiverNotificationRegister,
            parameters: [0, 0, 0],
            timeout: 0.7
        )
        guard let verified = HIDPPProtocol.receiverNotificationFlags(in: verificationResponse) else {
            log(
                "hidpp_receiver_notifications_verify_invalid",
                "raw=\(verificationResponse.map { String(format: "%02x", $0) }.joined())"
            )
            throw HIDPPControllerError.unexpectedResponse
        }
        guard verified.wirelessNotificationsEnabled else {
            log("hidpp_receiver_notifications_verify_failed", "after={\(verified)}")
            throw HIDPPControllerError.receiverNotificationsNotEnabled(
                actual: verified.receiverFlags
            )
        }
        log(
            "hidpp_receiver_notifications_verified",
            "after={\(verified)} changed=\(initial != verified)"
        )
    }

    // MARK: - Device readiness

    /// Probes only the HID++ root/high-resolution-wheel control path. This is
    /// deliberately separate from battery refresh: readiness drives takeover,
    /// while battery is optional product information.
    private func probeDeviceReadiness() {
        stateLock.lock()
        guard let selectedChannel = selectedChannelLocked() else {
            stateLock.unlock()
            log(
                "hidpp_readiness_probe_skipped",
                "reason=no-selected-channel has_restore_snapshot=\(hasActiveWheel)"
            )
            return
        }
        let generation = session.generation
        let observedDeviceIndexSnapshot = session.observedDeviceIndex
        let hasRestoreSnapshot = session.activeWheel != nil
        stateLock.unlock()
        let observedDeviceDescription = observedDeviceIndexSnapshot.map(String.init) ?? "none"

        log(
            "hidpp_readiness_probe_requested",
            "route_generation=\(generation) transport=\(selectedChannel.transport) "
                + "observed_device=\(observedDeviceDescription) "
                + "has_restore_snapshot=\(hasRestoreSnapshot)"
        )

        deviceServices.probeReadiness(
            generation: generation,
            operation: { [weak self] in
                guard let self else { throw HIDPPControllerError.noHIDPPChannel }
                return try self.withRoute(Route(channel: selectedChannel, generation: generation)) {
                    let deviceIndex = try self.discoverDeviceIndex()
                    return HIDPPReadyDevice(deviceIndex: deviceIndex, transport: selectedChannel.transport)
                }
            },
            isCurrent: { [weak self] generation in
                self?.routeIsCurrent(generation) ?? false
            },
            onReady: { [weak self] device, attempt in
                guard let self else { return }
                self.publish(generation: generation) {
                    $0.onStateChange?(.deviceReady(device.transport))
                }
                self.log(
                    "hidpp_device_ready",
                    "device=\(device.deviceIndex) transport=\(device.transport) attempt=\(attempt)"
                )
                self.refreshBattery(
                    after: 0, deviceIndex: device.deviceIndex, expectedGeneration: generation
                )
            },
            onLog: { [weak self] layer, message in
                guard let self else { return }
                self.stateLock.lock()
                let currentGeneration = self.session.generation
                let transport = self.selectedChannelLocked()?.transport.description ?? "none"
                let observedDevice = self.session.observedDeviceIndex.map(String.init) ?? "none"
                let hasRestoreSnapshot = self.session.activeWheel != nil
                self.stateLock.unlock()
                self.log(
                    layer,
                    "\(message) current_route_generation=\(currentGeneration) "
                        + "selected_transport=\(transport) observed_device=\(observedDevice) "
                        + "has_restore_snapshot=\(hasRestoreSnapshot)"
                )
            }
        )
    }

    // MARK: - Battery

    private func refreshBattery(
        after delay: TimeInterval,
        deviceIndex: UInt8? = nil,
        expectedGeneration: UInt64? = nil
    ) {
        stateLock.lock()
        if let expectedGeneration, session.generation != expectedGeneration {
            stateLock.unlock()
            return
        }
        guard let channel = selectedChannelLocked() else {
            stateLock.unlock()
            publishBatteryState(.unavailable)
            return
        }
        let generation = session.generation
        stateLock.unlock()

        deviceServices.refreshBattery(
            generation: generation,
            delay: delay,
            operation: { [weak self] in
                guard let self else { throw HIDPPControllerError.noHIDPPChannel }
                return try self.withRoute(Route(channel: channel, generation: generation)) {
                    let resolvedDeviceIndex = try deviceIndex
                        ?? self.discoverDeviceIndex()
                    return try self.readBattery(deviceIndex: resolvedDeviceIndex)
                }
            },
            isCurrent: { [weak self] generation in
                self?.routeIsCurrent(generation) ?? false
            },
            onState: { [weak self] state in
                self?.publish(generation: generation) { $0.onBatteryStateChange?(state) }
            },
            onLog: { [weak self] layer, message in self?.log(layer, message) }
        )
    }

    private func readBattery(deviceIndex: UInt8) throws -> HIDPPProtocol.BatteryInfo {
        let cachedFeature = try mutateSession { $0.batteryFeatures[deviceIndex] }

        let feature: HIDPPProtocol.BatteryFeature
        if let cachedFeature {
            feature = cachedFeature
        } else {
            feature = try discoverBatteryFeature(deviceIndex: deviceIndex)
            try mutateSession { $0.batteryFeatures[deviceIndex] = feature }
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

    /// Sends one HID++ long request through the shared serialized session.
    private func call(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        payload: [UInt8],
        timeout: TimeInterval,
        quietly: Bool = false
    ) throws -> [UInt8] {
        try send(.feature(
            deviceIndex: deviceIndex, featureIndex: featureIndex,
            functionID: functionID, payload: payload, timeout: timeout, quietly: quietly
        ))
    }

    private func callReceiverRegister(
        subID: UInt8, address: UInt8, parameters: [UInt8], timeout: TimeInterval
    ) throws -> [UInt8] {
        try send(.receiverRegister(
            subID: subID, address: address, parameters: parameters, timeout: timeout
        ))
    }

    private func send(_ request: HIDPPCommandChannel.Request) throws -> [UInt8] {
        guard let route = operationRoute else { throw HIDPPControllerError.noHIDPPChannel }
        try validate(route)
        let response = try route.channel.send(request)
        try validate(route)
        return response
    }

    /// Reads and repairs both modes on the pinned route. Verification evidence
    /// may be revoked independently from the saved pre-takeover modes.
    private func verifyActiveMode() throws -> HIDPPTakeoverAxes {
        let (activeWheel, activeThumbwheel) = try mutateSession { ($0.activeWheel, $0.activeThumbwheel) }
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
            let axes = try mutateSession {
                $0.verifiedTakeoverAxes = HIDPPTakeoverAxes(
                    vertical: true, horizontal: activeThumbwheel != nil
                )
                return $0.verifiedTakeoverAxes
            }
            publishTakeoverAxes(axes)
            transition(to: .ready(
                deviceIndex: activeWheel.deviceIndex,
                featureIndex: activeWheel.featureIndex,
                mode: desiredMode
            ))
            return axes
        } catch {
            // Timeout alone cannot prove that firmware returned to native mode.
            // Keep restoration snapshots; the coordinator owns recovery policy.
            // A lost reply invalidates evidence, not the obligation to restore.
            invalidateVerifiedTakeoverAxes()
            transition(to: .unavailable)
            log("hidpp_mode_verification_failed", error.localizedDescription)
            throw error
        }
    }

    // MARK: - Thread-safe state helpers

    private func currentTransport() -> HIDPPTransport? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedChannelLocked()?.transport
    }

    private func routeIsCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == session.generation && selectedChannelLocked() != nil
    }

    private func selectedChannelIsCurrent(key: UInt, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == session.generation && session.channelKey == key
    }

    private func preferredChannelKeyLocked() -> UInt? {
        channels.values.max { lhs, rhs in
            if lhs.transport.selectionPriority == rhs.transport.selectionPriority {
                return lhs.key < rhs.key
            }
            return lhs.transport.selectionPriority < rhs.transport.selectionPriority
        }?.key
    }

    private func selectedChannelLocked() -> HIDPPCommandChannel? {
        guard let key = session.channelKey else { return nil }
        return channels[key]
    }

    /// Route addresses are valid only within one physical transport. Clearing
    /// them on a channel switch prevents a Receiver slot/feature index from
    /// being written to a Bluetooth device (or the reverse). For Bluetooth the
    /// direct route is known up-front, while feature indices remain discoverable.
    private func resetRouteStateLocked(for transport: HIDPPTransport?) {
        session.observedDeviceIndex = transport?.directDeviceIndex
        session.receiverConnectionEdges.reset()
        session.featureIndices.removeAll()
        session.thumbwheelFeatureIndices.removeAll()
        session.batteryFeatures.removeAll()
        session.activeWheel = nil
        session.activeThumbwheel = nil
        session.verifiedTakeoverAxes = .none
        session.generation &+= 1
    }

    private func cancelPendingRequest() {
        requestSession.cancel()
    }

    private var hasActiveWheel: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session.activeWheel != nil
    }

    private func setVerifiedTakeoverAxis(_ axis: ScrollAxis, enabled: Bool) throws {
        let axes = try mutateSession {
            switch axis {
            case .vertical: $0.verifiedTakeoverAxes.vertical = enabled
            case .horizontal: $0.verifiedTakeoverAxes.horizontal = enabled
            }
            return $0.verifiedTakeoverAxes
        }
        publishTakeoverAxes(axes)
    }

    private func invalidateVerifiedTakeoverAxes() {
        guard let changed = try? mutateSession({
            let changed = !$0.verifiedTakeoverAxes.isEmpty
            $0.verifiedTakeoverAxes = .none
            return changed
        }) else { return }
        if changed { publishTakeoverAxes(.none) }
    }

    private func publishTakeoverAxes(_ axes: HIDPPTakeoverAxes) {
        publish { $0.onTakeoverAxesChange?(axes) }
    }

    private func publishBatteryState(_ state: HIDPPBatteryState) {
        publish { $0.onBatteryStateChange?(state) }
    }

    private func transition(to state: State) {
        publish { $0.onStateChange?(state) }
    }

    private func publish(
        generation expectedGeneration: UInt64? = nil,
        _ callback: @escaping (HIDPPController) -> Void
    ) {
        let generation: UInt64
        if let expectedGeneration {
            generation = expectedGeneration
        } else if DispatchQueue.getSpecific(key: operationQueueKey) != nil,
           let route = operationRoute {
            generation = route.generation
        } else {
            stateLock.lock()
            generation = session.generation
            stateLock.unlock()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let current = self.session.generation == generation
            self.stateLock.unlock()
            if current { callback(self) }
        }
    }

    private func currentRoute() -> Route? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let channel = selectedChannelLocked() else { return nil }
        return Route(channel: channel, generation: session.generation)
    }

    private func validate(_ route: Route) throws {
        guard selectedChannelIsCurrent(key: route.channel.key, generation: route.generation) else {
            throw HIDPPControllerError.transportChanged
        }
    }

    private func withRoute<T>(_ route: Route, operation: () throws -> T) throws -> T {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        try validate(route)
        operationRoute = route
        defer { operationRoute = nil }
        do {
            let result = try operation()
            try validate(route)
            return result
        } catch {
            try validate(route)
            throw error
        }
    }

    private func mutateSession<T>(_ mutation: (inout HardwareSession) -> T) throws -> T {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let route = operationRoute,
              session.generation == route.generation,
              session.channelKey == route.channel.key else {
            throw HIDPPControllerError.transportChanged
        }
        return mutation(&session)
    }

    private func runOperation<T>(
        route capturedRoute: Route? = nil,
        completion: @escaping (Result<T, Error>) -> Void,
        operation: @escaping () throws -> T
    ) {
        let route = capturedRoute ?? currentRoute()
        operationQueue.async {
            let result = Result {
                guard let route else { throw HIDPPControllerError.noHIDPPChannel }
                return try self.withRoute(route, operation: operation)
            }
            DispatchQueue.main.async {
                // A queued successful completion is stale too if removal happened
                // after the last read-back but before the main queue ran.
                if let route, !self.selectedChannelIsCurrent(
                    key: route.channel.key, generation: route.generation
                ) {
                    completion(.failure(HIDPPControllerError.transportChanged))
                } else {
                    completion(result)
                }
            }
        }
    }

    private func log(_ layer: String, _ message: String) {
        onLog?(layer, message)
    }
}
