import Foundation
import HIDReportBridge
import IOKit.hid

private final class HIDDeviceCallbackContext {
    /// Weak to avoid a retain cycle: HIDMonitor owns the subscription, the
    /// subscription owns this context, and IOHIDLib only borrows its pointer.
    weak var monitor: HIDMonitor?
    /// Stable identity for one IOHIDDevice during its registered lifetime.
    let deviceKey: UInt

    init(monitor: HIDMonitor, deviceKey: UInt) {
        self.monitor = monitor
        self.deviceKey = deviceKey
    }
}

/// Swift ABI entry point called by the C report filter. Pointer report 0x02 never reaches
/// this function; only HID++ 0x11 traffic and the Receiver's low-frequency
/// device-connection notifications cross into Swift.
///
/// The raw buffer belongs to IOHIDLib and is valid only for this callback. It
/// is copied before returning; retaining `report` would be a use-after-free.
@_cdecl("LogiMouseReceiveHIDPPReport")
func logiMouseReceiveHIDPPReport(
    _ context: UnsafeMutableRawPointer?,
    _ reportID: UInt32,
    _ report: UnsafeMutablePointer<UInt8>?,
    _ reportLength: Int,
    _ timestamp: UInt64
) {
    guard let context, let report, reportLength > 0 else { return }
    let callback = Unmanaged<HIDDeviceCallbackContext>
        .fromOpaque(context).takeUnretainedValue()
    callback.monitor?.receiveFilteredReport(
        deviceKey: callback.deviceKey,
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
    private final class RawReportSubscription {
        /// Retaining IOHIDDevice keeps the callback target alive until unregister.
        let device: IOHIDDevice
        /// Retains the object whose unowned pointer is passed through C.
        let context: HIDDeviceCallbackContext
        /// IOHIDLib writes each report into this reusable allocation.
        let buffer: UnsafeMutablePointer<UInt8>
        let capacity: Int

        init(device: IOHIDDevice, context: HIDDeviceCallbackContext, capacity: Int) {
            self.device = device
            self.context = context
            self.capacity = capacity
            buffer = .allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
        }

        deinit {
            buffer.deinitialize(count: capacity)
            buffer.deallocate()
        }
    }

    private struct PendingDevice {
        /// A match can arrive synchronously from IOHIDManagerOpen; activation is
        /// deferred until `managerIsOpen` so registration order is deterministic.
        let device: IOHIDDevice
        let transport: HIDPPTransport
    }

    private let controller = HIDPPController()
    private var manager: IOHIDManager?
    private var managerIsOpen = false
    private var pendingDevices: [UInt: PendingDevice] = [:]
    private var reportSubscriptions: [UInt: RawReportSubscription] = [:]

    init() {
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
            break
        case kIOHIDAccessTypeDenied:
            RuntimeLog.error("hid-input", "Input Monitoring permission denied")
            throw HIDMonitorError.permissionDenied
        default:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            RuntimeLog.warning("hid-input", "Input Monitoring permission pending; requested access")
            throw HIDMonitorError.permissionPending
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
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
                // Do not add a usage constraint here. The Bluetooth mouse is a
                // single composite IOHIDDevice whose primary usage is keyboard;
                // FF43/0202 appears only in DeviceUsagePairs and is not reliably
                // honored by IOHIDManager's device-matching dictionary. The
                // callback below validates that pair before opening a channel.
            ])
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        RuntimeLog.info("hid-input", "Configured HID matching dictionaries count=\(matching.count)")

        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, result, _, device in
                guard let context else { return }
                guard result == kIOReturnSuccess else {
                    RuntimeLog.error("hid-input", String(format: "HID device matching callback failed result=0x%08x", result))
                    return
                }
                Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, result, _, device in
                guard let context else { return }
                guard result == kIOReturnSuccess else {
                    RuntimeLog.error("hid-input", String(format: "HID device removal callback failed result=0x%08x", result))
                    return
                }
                Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        // IOHIDManager callbacks are delivered on the main run loop. The raw
        // report is timestamped in the kernel before this scheduling hop, so
        // model timing uses the hardware timestamp rather than callback time.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        RuntimeLog.info("hid-input", "Registered HID match/removal callbacks and scheduled manager on main run loop")

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            RuntimeLog.error("hid-input", String(format: "IOHIDManagerOpen failed result=0x%08x", result))
            stop()
            throw HIDMonitorError.managerOpenFailed(result)
        }
        managerIsOpen = true
        RuntimeLog.info("hid-input", "IOHIDManager opened successfully")
        activatePendingDevices()
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
        guard let manager else {
            RuntimeLog.debug("hid-input", "HID monitor teardown skipped because manager is not active")
            return
        }
        RuntimeLog.notice(
            "hid-input",
            "Tearing down HID monitor restoringHardware=\(restoringHardware) subscriptions=\(reportSubscriptions.count) pendingDevices=\(pendingDevices.count)"
        )
        if restoringHardware {
            // Restore hardware before unregistering the report callback: restore
            // requests need their 0x11 replies to wake HIDPPController.call().
            controller.restoreSynchronously()
        } else {
            // Reject late reports before unregistering their callback contexts.
            // The old controller generation must never recover independently.
            controller.invalidateForSystemSleep()
        }
        removeAllSubscriptions()
        managerIsOpen = false
        pendingDevices.removeAll()
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
        RuntimeLog.info("hid-input", "HID monitor teardown completed restoringHardware=\(restoringHardware)")
    }

    fileprivate func receiveFilteredReport(
        deviceKey: UInt,
        reportID: UInt32,
        bytes: UnsafePointer<UInt8>,
        length: Int,
        timestamp: UInt64
    ) {
        guard controller.acceptsDevice(key: deviceKey) else { return }
        let reportBytes = Array(UnsafeBufferPointer(start: bytes, count: length))
        if let event = HIDPPProtocol.receiverConnectionEvent(
            reportID: reportID,
            bytes: reportBytes
        ) {
            // The USB interface itself remains present while the paired mouse
            // is off. Report 0x10/sub-ID 0x41 is the actual radio-link signal.
            RuntimeLog.notice(
                "hid-input",
                String(format: "Receiver link event key=0x%llx event=%@", deviceKey, String(describing: event))
            )
            controller.observeReceiverConnection(deviceKey: deviceKey, event: event)
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

        // Command replies and unsolicited wheel events share report 0x11. Give
        // the controller the report first so an exact pending request can wake
        // before attempting event decoding.
        controller.observeReport(reportBytes)
        let deviceIndex = reportBytes.count > 1 ? reportBytes[1] : 0

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
            onWheelEvent?(wheelEvent, MonotonicClock.toNanoseconds(timestamp))
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
            onThumbwheelEvent?(thumbwheelEvent, MonotonicClock.toNanoseconds(timestamp))
        }
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
            installRawReportSubscription(device: pending.device, key: key)
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
        removeSubscription(key: key)
    }

    /// Installs one device-wide raw-report callback.
    ///
    /// The buffer must outlive callback registration, so it is stored inside
    /// RawReportSubscription rather than allocated on the stack. Capacity is
    /// at least one HID++ long report and otherwise follows the descriptor's
    /// `MaxInputReportSize`. USB exposes only HID++, while Bluetooth is
    /// composite; LMHIDPPFilteredReportCallback drops high-rate pointer reports
    /// before any Swift allocation or locking occurs.
    private func installRawReportSubscription(device: IOHIDDevice, key: UInt) {
        guard reportSubscriptions[key] == nil else { return }
        let capacity = max(
            HIDPPProtocol.longReportLength,
            Self.integerProperty(kIOHIDMaxInputReportSizeKey, device: device) ?? 32
        )
        let context = HIDDeviceCallbackContext(monitor: self, deviceKey: key)
        let subscription = RawReportSubscription(
            device: device,
            context: context,
            capacity: capacity
        )
        reportSubscriptions[key] = subscription
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            device,
            subscription.buffer,
            subscription.capacity,
            LMHIDPPFilteredReportCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )
        RuntimeLog.info(
            "hid-input",
            String(format: "Registered raw HID++ report callback key=0x%llx capacity=%d", key, capacity)
        )
    }

    private func removeSubscription(key: UInt) {
        if let subscription = reportSubscriptions.removeValue(forKey: key) {
            // Unregister while both buffer and context are still retained by
            // the local `subscription`; deallocation happens after this call.
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                subscription.device,
                subscription.buffer,
                subscription.capacity,
                nil,
                nil
            )
            RuntimeLog.info("hid-input", String(format: "Unregistered raw HID++ report callback key=0x%llx", key))
        }
    }

    private func removeAllSubscriptions() {
        for key in Array(reportSubscriptions.keys) { removeSubscription(key: key) }
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
