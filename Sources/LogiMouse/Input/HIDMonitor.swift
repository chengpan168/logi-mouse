import Foundation
import Dispatch
import HIDReportBridge
import IOKit.hid

/// Swift ABI entry point called by the C report filter. Pointer report 0x02 never reaches
/// this function; only HID++ 0x11 traffic and the Receiver's low-frequency short
/// responses and connection notifications cross into Swift. The manager callback
/// supplies the originating IOHIDDevice as `sender`, which is used as the same
/// process-local key stored by `HIDPPController`.
///
/// The raw buffer belongs to IOHIDLib and is valid only for this callback. It
/// is copied before returning; retaining `report` would be a use-after-free.
@_cdecl("LogiMouseReceiveHIDPPReport")
func logiMouseReceiveHIDPPReport(
    _ context: UnsafeMutableRawPointer?,
    _ sender: UnsafeMutableRawPointer?,
    _ reportID: UInt32,
    _ report: UnsafeMutablePointer<UInt8>?,
    _ reportLength: Int,
    _ timestamp: UInt64
) {
    guard let context, let sender, let report, reportLength > 0 else { return }
    let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.receiveFilteredReport(
        deviceKey: UInt(bitPattern: sender),
        reportID: reportID,
        bytes: UnsafePointer(report),
        length: reportLength,
        timestamp: timestamp
    )
}

enum HIDMonitorError: LocalizedError {
    case permissionDenied
    case permissionPending
    case managerOpenFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "输入监控权限已关闭。请在系统设置 → 隐私与安全性 → 输入监控中启用 logi-mouse，然后重新打开应用。"
        case .permissionPending:
            "macOS 已收到输入监控请求。请启用 logi-mouse，然后退出并重新打开应用。"
        case let .managerOpenFailed(code):
            String(format: "无法打开鼠标 HID++ 通道（IOReturn 0x%08x）。", code)
        }
    }
}

/// Runtime-only HID listener.
///
/// It opens only vendor-defined HID++ collections:
/// - USB Receiver: `usagePage 0xff00`, `usage 1`
/// - Bluetooth direct: `usagePage 0xff43`, `usage 0x0202`
///
/// USB and Bluetooth differ below this type:
/// - Receiver PID 0xc52b publishes a dedicated vendor interface, so selecting
///   usage page 0xff00 / usage 1 naturally excludes pointer movement.
/// - Bluetooth publishes one composite device whose usage pairs include the
///   vendor collection 0xff43/0x0202 alongside keyboard and pointer reports.
///   IOHIDManager cannot reliably match only that nested pair, so the complete
///   device is opened and the C bridge rejects report 0x01/0x02 immediately.
///
/// This type owns callback registration and report framing only. It never
/// decides feature indices or mutates wheel modes; HIDPPController owns those
/// hardware transactions and their restoration guarantees.
final class HIDMonitor {
    var onWheelEvent: ((HIDPPWheelEvent, UInt64) -> Void)?
    var onThumbwheelEvent: ((HIDPPThumbwheelEvent, UInt64) -> Void)?
    var onControllerStateChange: ((HIDPPController.State) -> Void)?
    var onTakeoverAxesChange: ((HIDPPTakeoverAxes) -> Void)?
    var onBatteryStateChange: ((HIDPPBatteryState) -> Void)?

    /// USB vendor ID assigned to Logitech.
    private static let logitechVendorID = 0x046d
    /// Product ID of the tested Unifying USB Receiver control interfaces.
    private static let unifyingReceiverProductID = 0xc52b
    /// Logitech vendor usage pair that identifies HID++ inside the BLE descriptor.
    private static let bluetoothUsagePage = 0xff43
    private static let bluetoothUsage = 0x0202
    private struct PendingDevice {
        /// A match can be delivered while manager activation is still in
        /// progress; activation is deferred until `managerIsOpen` so routing
        /// order remains deterministic.
        let device: IOHIDDevice
        let transport: HIDPPTransport
    }

    /// All IOHID callbacks, including the device-wide raw-report callback, are
    /// delivered here. Keeping this queue separate from the AppKit main
    /// RunLoop prevents Bluetooth pointer reports (which the C bridge drops)
    /// from competing with CGEvent processing and UI work.
    private let hidQueue = DispatchQueue(
        label: "dev.logi-mouse.hid-input",
        // HID++ notifications are user-visible, but this queue must not be
        // scheduled ahead of macOS's own pointer event processing. Bluetooth
        // composite devices still wake the callback for report 0x02; the C
        // bridge drops those reports before they reach this queue's Swift
        // work. User-initiated priority keeps wheel latency low without
        // treating the control channel as a display-critical UI task.
        qos: .userInitiated
    )
    private let hidQueueKey = DispatchSpecificKey<Void>()
    private let controller = HIDPPController()
    private var manager: IOHIDManager?
    private var managerIsOpen = false
    private var pendingDevices: [UInt: PendingDevice] = [:]
    private var acceptingReports = false

    init() {
        hidQueue.setSpecific(key: hidQueueKey, value: ())
        controller.onStateChange = { [weak self] state in
            self?.onControllerStateChange?(state)
        }
        controller.onTakeoverAxesChange = { [weak self] axes in
            self?.onTakeoverAxesChange?(axes)
        }
        controller.onBatteryStateChange = { [weak self] state in
            self?.onBatteryStateChange?(state)
        }
        controller.onLog = { layer, message in
            if layer.contains("failed") || layer.contains("exhausted") || layer.contains("timeout") {
                RuntimeLog.warning("hidpp", "layer=\(layer) \(message)")
            } else {
                RuntimeLog.debug("hidpp", "layer=\(layer) \(message)")
            }
        }
    }

    /// Avoids a self-deadlock when a lifecycle operation is called from an
    /// IOHID callback. All mutable manager state is otherwise confined to this
    /// queue.
    private func syncOnHIDQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: hidQueueKey) != nil {
            return work()
        }
        return hidQueue.sync(execute: work)
    }

    func takeOverWheel(
        preserveRequestOnFailure: Bool = false,
        completion: @escaping (Result<HIDPPController.State, Error>) -> Void
    ) {
        controller.takeOverWheel(
            preserveRequestOnFailure: preserveRequestOnFailure,
            completion: completion
        )
    }

    func restoreWheel(completion: @escaping (Result<HIDPPController.State, Error>) -> Void) {
        controller.restoreWheel(completion: completion)
    }

    func verifyWheelMode(
        completion: @escaping (Result<HIDPPTakeoverAxes, Error>) -> Void
    ) {
        controller.verifyMode(completion: completion)
    }

    func refreshBattery() {
        controller.refreshBattery()
    }

    func start() throws {
        RuntimeLog.info("hid-input", "Starting HID monitor")
        // Listening to raw HID input is protected by macOS Input Monitoring.
        // Requesting access is asynchronous: after the user changes the toggle,
        // the process must be restarted before IOHIDManagerOpen can succeed.
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            RuntimeLog.info("hid-input", "Input Monitoring permission granted")
        case kIOHIDAccessTypeDenied:
            RuntimeLog.error("hid-input", "Input Monitoring permission denied")
            throw HIDMonitorError.permissionDenied
        default:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            RuntimeLog.warning("hid-input", "Input Monitoring permission pending; requested access")
            throw HIDMonitorError.permissionPending
        }

        // Configure and activate the manager on its own serial queue. This is
        // deliberately synchronous only during startup, so the caller retains
        // the existing throwing permission/open contract while every later HID
        // callback stays off the AppKit main RunLoop.
        let result = syncOnHIDQueue { () -> IOReturn in
            guard self.manager == nil else { return kIOReturnBusy }
            let manager = IOHIDManagerCreate(
                kCFAllocatorDefault,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )
            self.manager = manager
            self.managerIsOpen = false
            self.acceptingReports = false
            self.pendingDevices.removeAll(keepingCapacity: true)

            // USB can be matched to one dedicated collection. Bluetooth must be
            // matched by VID/PID first and validated against DeviceUsagePairs in
            // `deviceMatched`, because its primary usage is keyboard rather than
            // the nested Logitech vendor collection we need.
            var matching: [[String: Int]] = [[
                kIOHIDVendorIDKey: Self.logitechVendorID,
                kIOHIDProductIDKey: Self.unifyingReceiverProductID,
                kIOHIDPrimaryUsagePageKey: 0xff00,
                kIOHIDPrimaryUsageKey: 1,
            ]]
            for productID in MouseConnectionResolver.supportedBluetoothProductIDs {
                matching.append([
                    kIOHIDVendorIDKey: Self.logitechVendorID,
                    kIOHIDProductIDKey: productID,
                    // Do not add a usage constraint here. The Bluetooth mouse
                    // is a single composite IOHIDDevice whose primary usage is
                    // keyboard; FF43/0202 appears only in DeviceUsagePairs and
                    // is not reliably honored by IOHIDManager's matching.
                ])
            }
            IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
            RuntimeLog.info(
                "hid-input",
                "Configured HID matching dictionaries count=\(matching.count)"
            )

            // A dispatch queue and a RunLoop are mutually exclusive for one
            // manager. Register every callback before activation, as required by
            // IOHIDLib's dispatch-queue contract.
            IOHIDManagerSetDispatchQueue(manager, self.hidQueue)
            IOHIDManagerRegisterDeviceMatchingCallback(
                manager,
                { context, result, _, device in
                    guard let context else { return }
                    guard result == kIOReturnSuccess else {
                        RuntimeLog.error(
                            "hid-input",
                            String(
                                format: "HID device matching callback failed result=0x%08x",
                                result
                            )
                        )
                        return
                    }
                    Unmanaged<HIDMonitor>.fromOpaque(context)
                        .takeUnretainedValue()
                        .deviceMatched(device)
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            IOHIDManagerRegisterDeviceRemovalCallback(
                manager,
                { context, result, _, device in
                    guard let context else { return }
                    guard result == kIOReturnSuccess else {
                        RuntimeLog.error(
                            "hid-input",
                            String(
                                format: "HID device removal callback failed result=0x%08x",
                                result
                            )
                        )
                        return
                    }
                    Unmanaged<HIDMonitor>.fromOpaque(context)
                        .takeUnretainedValue()
                        .deviceRemoved(device)
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            IOHIDManagerRegisterInputReportWithTimeStampCallback(
                manager,
                LMHIDPPFilteredReportCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            // Retain the callback context until IOKit has finished cancelling.
            // Clearing manager here breaks the temporary ownership cycle.
            IOHIDManagerSetCancelHandler(manager) { [self] in
                if let manager = self.manager {
                    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                }
                self.manager = nil
                RuntimeLog.debug("hid-input", "IOHIDManager cancellation handler completed")
            }

            // Keep the existing explicit open so permission/transport failures
            // remain observable. Activation is still required after assigning a
            // dispatch queue; it is idempotent if this OS opens the manager as a
            // side effect of IOHIDManagerOpen.
            let result = IOHIDManagerOpen(
                manager,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )
            guard result == kIOReturnSuccess else {
                self.pendingDevices.removeAll(keepingCapacity: true)
                // Dispatch resources still need activation/cancellation when
                // opening fails. Input stays gated until the handler releases us.
                IOHIDManagerActivate(manager)
                IOHIDManagerCancel(manager)
                return result
            }
            self.managerIsOpen = true
            self.acceptingReports = true
            IOHIDManagerActivate(manager)
            self.activatePendingDevices()
            RuntimeLog.info(
                "hid-input",
                "IOHIDManager opened and activated on dedicated HID dispatch queue"
            )
            return result
        }

        guard result == kIOReturnSuccess else {
            RuntimeLog.error(
                "hid-input",
                String(format: "IOHIDManagerOpen failed result=0x%08x", result)
            )
            throw HIDMonitorError.managerOpenFailed(result)
        }
    }

    func stop() {
        teardown(restoringHardware: true)
    }

    /// Releases the current HID generation without issuing hardware commands.
    ///
    /// A system-sleep notification can arrive after the mouse radio or USB stack
    /// has already stopped answering. Calling `restoreSynchronously()` there
    /// would delay sleep until request timeout. User intent is retained by the
    /// runtime coordinator and a fresh controller reapplies it after wake.
    func suspend() {
        teardown(restoringHardware: false)
    }

    private func teardown(restoringHardware: Bool) {
        guard let manager = syncOnHIDQueue({ self.managerIsOpen ? self.manager : nil }) else {
            RuntimeLog.debug("hid-input", "HID monitor teardown skipped because manager is not active")
            return
        }
        RuntimeLog.notice(
            "hid-input",
            "Tearing down HID monitor restoringHardware=\(restoringHardware) pendingDevices=\(syncOnHIDQueue { pendingDevices.count })"
        )
        if restoringHardware {
            // Restore hardware before cancelling the report callback: restore
            // requests need their 0x11 replies to wake HIDPPController.call().
            controller.restoreSynchronously()
        } else {
            // Reject late reports before cancelling the manager. The old
            // controller generation must never recover independently.
            controller.invalidateForSystemSleep()
        }

        // Cancellation is asynchronous. The cancel handler owns final release;
        // a queue barrier alone cannot wait for IOKit's internal sources.
        syncOnHIDQueue {
            acceptingReports = false
            managerIsOpen = false
            pendingDevices.removeAll(keepingCapacity: true)
            IOHIDManagerCancel(manager)
        }
        RuntimeLog.info("hid-input", "HID monitor cancellation requested restoringHardware=\(restoringHardware)")
    }

    fileprivate func receiveFilteredReport(
        deviceKey: UInt,
        reportID: UInt32,
        bytes: UnsafePointer<UInt8>,
        length: Int,
        timestamp: UInt64
    ) {
        // This method is called by the manager callback on `hidQueue`. Reject
        // reports queued during cancellation before touching controller state.
        guard acceptingReports, controller.acceptsDevice(key: deviceKey) else { return }
        let reportBytes = Array(UnsafeBufferPointer(start: bytes, count: length))
        // Both HID++ generations share one interrupt pipe. Resolve an exact
        // short/long command response before decoding unsolicited events.
        if controller.observeReport(reportBytes) { return }
        if let event = HIDPPProtocol.receiverConnectionEvent(
            reportID: reportID,
            bytes: reportBytes
        ) {
            // The USB interface itself remains present while the paired mouse
            // is off. Report 0x10/sub-ID 0x40/0x41 is the radio-link signal.
            RuntimeLog.notice(
                "hid-input",
                String(
                    format: "Receiver link event key=0x%llx sub_id=0x%02x slot=%u connected=%@ raw=%@",
                    deviceKey,
                    reportBytes[2],
                    event.deviceIndex,
                    event.isConnected ? "true" : "false",
                    reportBytes.map { String(format: "%02x", $0) }.joined()
                )
            )
            controller.observeReceiverConnection(deviceKey: deviceKey, event: event)
            return
        }
        if reportID == UInt32(HIDPPProtocol.shortReportID) {
            let subID = reportBytes.count > 2 ? reportBytes[2] : 0
            if subID == HIDPPProtocol.getShortRegisterSubID
                || subID == HIDPPProtocol.setShortRegisterSubID
                || subID == HIDPPProtocol.shortErrorSubID {
                RuntimeLog.warning(
                    "hid-input",
                    String(
                        format: "Unmatched Receiver short response key=0x%llx sub_id=0x%02x raw=%@",
                        deviceKey,
                        subID,
                        reportBytes.map { String(format: "%02x", $0) }.joined()
                    )
                )
            }
            return
        }
        guard HIDPPProtocol.isLongInputReport(reportID) else { return }
        processLongReport(
            deviceKey: deviceKey,
            reportBytes: reportBytes,
            timestamp: timestamp
        )
    }

    private func processLongReport(
        deviceKey: UInt,
        reportBytes: [UInt8],
        timestamp: UInt64
    ) {
        guard controller.acceptsDevice(key: deviceKey),
              reportBytes.count == HIDPPProtocol.longReportLength,
              reportBytes.first == HIDPPProtocol.longReportID else { return }

        let deviceIndex = reportBytes.count > 1 ? reportBytes[1] : 0
        let eventTimestamp = MonotonicClock.toNanoseconds(timestamp)

        let wheelEvent = HIDPPReportDecoder.decodeWheelEvent(
            reportID: UInt32(HIDPPProtocol.longReportID),
            bytes: reportBytes,
            expectedFeatureIndex: controller.featureIndex(for: deviceIndex)
                ?? HIDPPReportDecoder.currentHiResWheelFeatureIndex
        )
        if let wheelEvent {
            controller.observeWheelRoute(
                deviceIndex: wheelEvent.deviceIndex,
                featureIndex: wheelEvent.featureIndex
            )
            publishWheelEvent(wheelEvent, timestampNs: eventTimestamp)
        }

        let thumbwheelEvent = HIDPPReportDecoder.decodeThumbwheelEvent(
            reportID: UInt32(HIDPPProtocol.longReportID),
            bytes: reportBytes,
            expectedFeatureIndex: controller.thumbwheelFeatureIndex(for: deviceIndex)
                ?? HIDPPReportDecoder.currentThumbwheelFeatureIndex
        )
        if let thumbwheelEvent {
            controller.observeThumbwheelRoute(
                deviceIndex: thumbwheelEvent.deviceIndex,
                featureIndex: thumbwheelEvent.featureIndex
            )
            publishThumbwheelEvent(thumbwheelEvent, timestampNs: eventTimestamp)
        }
    }

    /// Wheel callbacks are the high-frequency data path. They are delivered on
    /// `hidQueue`; the coordinator wires them to `ScrollOutputPipeline`, which
    /// performs model work without enqueueing one main-actor task per report.
    /// Low-frequency controller/UI callbacks retain their explicit main-queue
    /// handoff inside `HIDPPController`.
    private func publishWheelEvent(_ event: HIDPPWheelEvent, timestampNs: UInt64) {
        onWheelEvent?(event, timestampNs)
    }

    private func publishThumbwheelEvent(_ event: HIDPPThumbwheelEvent, timestampNs: UInt64) {
        onThumbwheelEvent?(event, timestampNs)
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        // Never identify the control channel by product name. Names are
        // localized and shared across collections; VID/PID/usage/transport are
        // stable descriptor properties suitable for hardware routing.
        let vendorID = Self.integerProperty(kIOHIDVendorIDKey, device: device)
        let productID = Self.integerProperty(kIOHIDProductIDKey, device: device)
        let usagePage = Self.integerProperty(kIOHIDPrimaryUsagePageKey, device: device)
        let usage = Self.integerProperty(kIOHIDPrimaryUsageKey, device: device)
        let transportName = Self.stringProperty(kIOHIDTransportKey, device: device) ?? ""

        guard vendorID == Self.logitechVendorID else { return }
        let transport: HIDPPTransport
        if productID == Self.unifyingReceiverProductID,
           usagePage == 0xff00, usage == 1 {
            transport = .usbReceiver
        } else if let productID,
                  MouseConnectionResolver.supportedBluetoothProductIDs.contains(productID),
                  Self.hasUsagePair(
                      page: Self.bluetoothUsagePage,
                      usage: Self.bluetoothUsage,
                      device: device
                  ),
                  transportName.localizedCaseInsensitiveContains("Bluetooth") {
            transport = .bluetooth
        } else {
            return
        }
        let key = Self.deviceKey(device)
        RuntimeLog.notice(
            "hid-input",
            String(
                format: "Matched HID++ device key=0x%llx transport=%@ vid=0x%04x pid=0x%04x usagePage=0x%04x usage=0x%04x",
                key,
                transportName,
                vendorID ?? 0,
                productID ?? 0,
                usagePage ?? 0,
                usage ?? 0
            )
        )
        pendingDevices[key] = PendingDevice(device: device, transport: transport)
        if managerIsOpen { activatePendingDevices() }
    }

    /// Matching callbacks may run while IOHIDManagerOpen is still in progress.
    /// Defer report registration until the manager reports a successful open so
    /// USB and Bluetooth use the same activation order.
    private func activatePendingDevices() {
        guard managerIsOpen else { return }
        RuntimeLog.info("hid-input", "Activating pending HID++ devices count=\(pendingDevices.count)")
        var activatedKeys: [UInt] = []
        for (key, pending) in pendingDevices {
            activatedKeys.append(key)
            controller.considerDevice(pending.device, key: key, transport: pending.transport)
        }
        for key in activatedKeys { pendingDevices.removeValue(forKey: key) }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        // Remove the controller route before freeing the callback context so a
        // concurrent late report cannot be accepted as the active transport.
        let key = Self.deviceKey(device)
        RuntimeLog.notice("hid-input", String(format: "HID++ device removed key=0x%llx", key))
        pendingDevices.removeValue(forKey: key)
        controller.removeDevice(key: key)
    }

    private static func deviceKey(_ device: IOHIDDevice) -> UInt {
        // IOHIDDevice has no public Hashable identity. The CF object address is
        // stable for its callback lifetime and is never persisted across runs.
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private static func integerProperty(_ key: String, device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ key: String, device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func hasUsagePair(page: Int, usage: Int, device: IOHIDDevice) -> Bool {
        guard let pairs = IOHIDDeviceGetProperty(
            device,
            kIOHIDDeviceUsagePairsKey as CFString
        ) as? [[String: Any]] else { return false }
        return pairs.contains { pair in
            (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue == page
                && (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue == usage
        }
    }

    deinit {
        stop()
    }
}
