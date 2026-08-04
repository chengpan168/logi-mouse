import Foundation
import IOKit.hid

enum HIDPPControllerError: LocalizedError, Equatable {
    case noReceiverChannel
    case deviceNotFound
    case featureUnsupported(UInt16)
    case writeFailed(IOReturn)
    case timeout
    case deviceError(UInt8)
    case unexpectedResponse
    case verificationFailed(expected: UInt8, actual: UInt8)

    var errorDescription: String? {
        switch self {
        case .noReceiverChannel:
            "No writable Logitech Receiver HID++ channel is available."
        case .deviceNotFound:
            "No paired HID++ device responded on Receiver slots 1–6."
        case let .featureUnsupported(featureID):
            String(format: "The connected device does not expose HID++ feature 0x%04x.", featureID)
        case let .writeFailed(code):
            String(format: "IOHIDDeviceSetReport failed (IOReturn 0x%08x).", code)
        case .timeout:
            "The HID++ request timed out. The mouse may be asleep or another process owns the Receiver."
        case let .deviceError(code):
            String(format: "The HID++ device returned error 0x%02x.", code)
        case .unexpectedResponse:
            "The HID++ device returned an unexpected response."
        case let .verificationFailed(expected, actual):
            String(format: "Wheel mode verification failed: expected 0x%02x, got 0x%02x.", expected, actual)
        }
    }
}

/// Serializes every mutating HID++ operation performed against the Logitech
/// USB Receiver and owns the safety lifecycle of diverted wheel modes.
///
/// Hardware invariants:
/// - Feature indices are device-specific and must be discovered from Root
///   Feature `0x0000`; captured indices are never trusted for control writes.
/// - Before the first write, the original main-wheel and thumbwheel modes are
///   saved. Disable, failure and process termination restore those values.
/// - Every mode write is followed by a read-back. A successful USB write only
///   proves that the Receiver accepted bytes, not that the mouse applied them.
/// - Requests are serialized because HID++ exposes only a 4-bit software ID
///   for response matching and unsolicited events use the same input channel.
///
/// `operationQueue` performs commands and watchdog work. `stateLock` protects
/// device/lifecycle state shared with IOKit callbacks, while `condition` pairs
/// the synchronous request path with reports delivered by `HIDMonitor`.
final class HIDPPController {
    enum State: Equatable, Sendable, CustomStringConvertible {
        case unavailable
        case receiverReady
        case discovering
        case ready(deviceIndex: UInt8, featureIndex: UInt8, mode: HIDPPProtocol.WheelMode)
        case failed(String)

        var description: String {
            switch self {
            case .unavailable: "unavailable"
            case .receiverReady: "receiver-ready"
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
    var onLog: ((String, String) -> Void)?

    private struct PendingRequest {
        let header: HIDPPProtocol.RequestHeader
        var response: [UInt8]?
    }

    private struct ActiveWheel {
        let deviceIndex: UInt8
        let featureIndex: UInt8
        let restoreMode: HIDPPProtocol.WheelMode
    }

    private struct ActiveThumbwheel {
        let deviceIndex: UInt8
        let featureIndex: UInt8
        let restoreInverted: Bool
    }

    private let operationQueue = DispatchQueue(label: "dev.logi-mouse.hidpp-controller")
    private let condition = NSCondition()
    private let stateLock = NSLock()
    private var receiverDevice: IOHIDDevice?
    private var receiverDeviceKey: UInt?
    private var pendingRequest: PendingRequest?
    private var nextSoftwareID: UInt8 = 0x0a
    private var observedDeviceIndex: UInt8?
    private var featureIndices: [UInt8: UInt8] = [:]
    private var thumbwheelFeatureIndices: [UInt8: UInt8] = [:]
    private var activeWheel: ActiveWheel?
    private var activeThumbwheel: ActiveThumbwheel?
    private var takeoverRequested = false
    private var modeWatchdog: DispatchSourceTimer?
    private var watchdogStableChecks = 0
    private var watchdogInterval: TimeInterval = 1
    private var lastOnDemandVerificationNs: UInt64 = 0
    private var reacquireAttemptScheduled = false
    private var reacquireAttempt = 0
    // MARK: - Receiver lifecycle

    func considerReceiverDevice(
        _ device: IOHIDDevice,
        key: UInt,
        vendorID: Int?,
        productID: Int?,
        primaryUsagePage: Int?,
        primaryUsage: Int?
    ) {
        guard vendorID == 0x046d,
              productID == 0xc52b,
              primaryUsagePage == 0xff00,
              primaryUsage == 1 else {
            return
        }
        stateLock.lock()
        receiverDevice = device
        receiverDeviceKey = key
        let shouldReacquire = takeoverRequested
        stateLock.unlock()
        transition(to: .receiverReady)
        log("hidpp_controller_device", "selected Receiver HID++ channel usage_page=0xff00 usage=1")
        if shouldReacquire {
            scheduleReacquire(after: 0.15)
        }
    }

    func removeDevice(key: UInt) {
        stateLock.lock()
        let removed = receiverDeviceKey == key
        if removed {
            receiverDevice = nil
            receiverDeviceKey = nil
            featureIndices.removeAll()
            thumbwheelFeatureIndices.removeAll()
            activeWheel = nil
            activeThumbwheel = nil
        }
        stateLock.unlock()
        if removed {
            operationQueue.async { [weak self] in
                self?.stopModeWatchdog()
            }
            condition.lock()
            pendingRequest = nil
            condition.broadcast()
            condition.unlock()
            transition(to: .unavailable)
            log("hidpp_controller_device_removed", "Receiver HID++ channel removed")
        }
    }

    func observeReport(_ report: [UInt8]) {
        guard report.count == HIDPPProtocol.longReportLength,
              report.first == HIDPPProtocol.longReportID else { return }

        condition.lock()
        if let pendingRequest,
           HIDPPProtocol.matchesResponse(report, request: pendingRequest.header) {
            self.pendingRequest?.response = report
            condition.broadcast()
        }
        condition.unlock()
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

    func verifyModeSoon() {
        operationQueue.async { [weak self] in
            guard let self, self.isTakeoverRequested, self.hasActiveWheel else { return }
            let now = MonotonicClock.nowNanoseconds()
            guard now >= self.lastOnDemandVerificationNs + 1_000_000_000 else { return }
            self.lastOnDemandVerificationNs = now
            self.verifyActiveMode()
        }
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

    // MARK: - Public takeover lifecycle

    func takeOverReceiverWheel(completion: @escaping (Result<State, Error>) -> Void) {
        setTakeoverRequested(true)
        operationQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ready = try self.performTakeover()
                DispatchQueue.main.async { completion(.success(ready)) }
            } catch {
                self.setTakeoverRequested(false)
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
                self.transition(to: .failed(error.localizedDescription))
                self.log("hidpp_takeover_failed", error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func restoreReceiverWheel(completion: @escaping (Result<State, Error>) -> Void) {
        setTakeoverRequested(false)
        operationQueue.async { [weak self] in
            guard let self else { return }
            do {
                let state = try self.performRestore()
                DispatchQueue.main.async { completion(.success(state)) }
            } catch {
                self.transition(to: .failed(error.localizedDescription))
                self.log("hidpp_restore_failed", error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func restoreSynchronously() {
        setTakeoverRequested(false)
        if !Thread.isMainThread {
            operationQueue.sync {
                do {
                    _ = try performRestore()
                } catch {
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
                self.log("hidpp_restore_failed", error.localizedDescription)
            }
        }
        while group.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    // MARK: - Takeover transaction

    private func performTakeover(knownRouteOnly: Bool = false) throws -> State {
        transition(to: .discovering)
        // Receiver slot numbers and feature indices can change after reconnect.
        // Resolve both axes on every takeover instead of persisting addresses.
        let deviceIndex = try discoverDeviceIndex(knownRouteOnly: knownRouteOnly)
        let feature = try discoverFeature(
            HIDPPProtocol.hiResWheelFeatureID,
            deviceIndex: deviceIndex,
            timeout: 0.7
        )
        stateLock.lock()
        featureIndices[deviceIndex] = feature.index
        stateLock.unlock()

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


        // The thumbwheel is a separate HID++ feature with separate reporting
        // state. It cannot reuse the main wheel's feature index or mode bits.
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

        let ready = State.ready(
            deviceIndex: deviceIndex,
            featureIndex: feature.index,
            mode: readBack
        )
        transition(to: ready)
        startModeWatchdog()
        log(
            "hidpp_takeover_ready",
            "wheel_feature_version=\(feature.version) original={\(originalMode)} applied={\(readBack)} "
                + "thumbwheel_feature_version=\(thumbwheelFeature.version) "
                + "thumbwheel_original={\(originalThumbwheelStatus)} thumbwheel_applied={\(thumbwheelReadBack)}"
        )
        return ready
    }

    private func performRestore() throws -> State {
        stopModeWatchdog()
        stateLock.lock()
        let activeWheel = self.activeWheel
        let activeThumbwheel = self.activeThumbwheel
        stateLock.unlock()
        guard activeWheel != nil || activeThumbwheel != nil else {
            let available = currentReceiverDevice() != nil
            let newState: State = available ? .receiverReady : .unavailable
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
                stateLock.unlock()
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
                stateLock.unlock()
                restoredDescriptions.append("wheel={\(readBack)}")
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        transition(to: .receiverReady)
        log("hidpp_takeover_restored", restoredDescriptions.joined(separator: " "))
        return .receiverReady
    }

    // MARK: - Feature discovery and commands

    private func discoverDeviceIndex(knownRouteOnly: Bool) throws -> UInt8 {
        stateLock.lock()
        let preferred = observedDeviceIndex
        stateLock.unlock()
        // Prefer the last observed slot for fast wake/reconnect recovery. Every
        // sixth reacquire performs a full 1...6 scan so a slot change cannot
        // permanently trap the controller on a stale route.
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

    private func getWheelMode(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        quietly: Bool = false
    ) throws -> HIDPPProtocol.WheelMode {
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
        _ = try call(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 2,
            payload: [status.reportingMode, status.directionInverted ? 1 : 0, 0],
            timeout: 0.7
        )
        log("hidpp_thumbwheel_status_written", status.description)
    }

    private func call(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        payload: [UInt8],
        timeout: TimeInterval,
        quietly: Bool = false
    ) throws -> [UInt8] {
        guard let device = currentReceiverDevice() else {
            throw HIDPPControllerError.noReceiverChannel
        }
        let header = HIDPPProtocol.RequestHeader(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: functionID,
            softwareID: takeSoftwareID()
        )
        let report = HIDPPProtocol.makeLongRequest(header: header, payload: payload)

        // Publish the expected header before sending. A fast Receiver can call
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

    // MARK: - Drift watchdog and reconnect

    private func startModeWatchdog() {
        stopModeWatchdog()
        watchdogStableChecks = 0
        watchdogInterval = 1
        let timer = DispatchSource.makeTimerSource(queue: operationQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.verifyActiveMode()
        }
        modeWatchdog = timer
        timer.resume()
        log("hidpp_mode_watchdog_started", "interval=1.0s adaptive=true")
    }

    private func scheduleReacquire(after delay: TimeInterval) {
        operationQueue.async { [weak self] in
            guard let self, !self.reacquireAttemptScheduled else { return }
            self.reacquireAttemptScheduled = true
            self.operationQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.reacquireAttemptScheduled = false
                guard self.isTakeoverRequested,
                      self.currentReceiverDevice() != nil,
                      !self.hasActiveWheel else {
                    return
                }
                self.reacquireAttempt += 1
                let knownRouteOnly = self.reacquireAttempt % 6 != 0
                do {
                    let ready = try self.performTakeover(knownRouteOnly: knownRouteOnly)
                    self.reacquireAttempt = 0
                    self.log("hidpp_reacquire_ready", ready.description)
                } catch {
                    self.transition(to: .failed(error.localizedDescription))
                    self.log("hidpp_reacquire_failed", error.localizedDescription)
                    if self.isTakeoverRequested, self.currentReceiverDevice() != nil {
                        self.scheduleReacquire(after: 0.35)
                    }
                }
            }
        }
    }

    private func stopModeWatchdog() {
        modeWatchdog?.cancel()
        modeWatchdog = nil
        watchdogStableChecks = 0
        watchdogInterval = 1
    }

    private func setWatchdogInterval(_ interval: TimeInterval) {
        guard watchdogInterval != interval, let modeWatchdog else { return }
        watchdogInterval = interval
        let leeway: DispatchTimeInterval = interval <= 1 ? .milliseconds(100) : .seconds(2)
        modeWatchdog.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        log("hidpp_mode_watchdog_interval", "interval=\(interval)s")
    }

    private func verifyActiveMode() {
        stateLock.lock()
        let activeWheel = self.activeWheel
        let activeThumbwheel = self.activeThumbwheel
        stateLock.unlock()
        guard let activeWheel else {
            stopModeWatchdog()
            return
        }

        let desiredMode = HIDPPProtocol.WheelMode.divertedHighResolution
        do {
            let observed = try getWheelMode(
                deviceIndex: activeWheel.deviceIndex,
                featureIndex: activeWheel.featureIndex,
                quietly: true
            )
            var repairedDrift = false
            if observed != desiredMode {
                repairedDrift = true
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
                    repairedDrift = true
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
            // Check quickly during initial takeover and after repair. Once eight
            // consecutive checks are stable, reduce polling to preserve idle
            // CPU and Receiver battery/radio activity.
            if repairedDrift {
                watchdogStableChecks = 0
                setWatchdogInterval(1)
            } else {
                watchdogStableChecks += 1
                if watchdogStableChecks >= 8 {
                    setWatchdogInterval(15)
                }
            }
        } catch {
            watchdogStableChecks = 0
            setWatchdogInterval(15)
            log("hidpp_mode_watchdog_failed", error.localizedDescription)
        }
    }

    // MARK: - Thread-safe state helpers

    private func clearPendingRequest() {
        condition.lock()
        pendingRequest = nil
        condition.broadcast()
        condition.unlock()
    }

    private func currentReceiverDevice() -> IOHIDDevice? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return receiverDevice
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
