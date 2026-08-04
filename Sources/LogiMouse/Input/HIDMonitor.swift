import Foundation
import HIDReportBridge
import IOKit.hid
import os

private final class HIDDeviceCallbackContext {
    weak var monitor: HIDMonitor?
    let deviceKey: UInt

    init(monitor: HIDMonitor, deviceKey: UInt) {
        self.monitor = monitor
        self.deviceKey = deviceKey
    }
}

/// Entry point called by the C report filter. Pointer report 0x02 never reaches
/// this function; only HID++ 0x11 traffic and the Receiver's low-frequency
/// device-connection notifications cross into Swift.
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
/// Bluetooth is one composite device, so its raw callback also receives pointer
/// report 0x02. A tiny C bridge rejects those reports before entering Swift;
/// only complete HID++ 0x11 reports reach the product path.
final class HIDMonitor {
    var onWheelEvent: ((HIDPPWheelEvent, UInt64) -> Void)?
    var onThumbwheelEvent: ((HIDPPThumbwheelEvent, UInt64) -> Void)?
    var onControllerStateChange: ((HIDPPController.State) -> Void)?

    private static let logitechVendorID = 0x046d
    private static let unifyingReceiverProductID = 0xc52b
    private static let bluetoothUsagePage = 0xff43
    private static let bluetoothUsage = 0x0202
    private static let logger = Logger(subsystem: "dev.logi-mouse", category: "hid-input")

    private final class RawReportSubscription {
        let device: IOHIDDevice
        let context: HIDDeviceCallbackContext
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
    }

    func takeOverWheel(completion: @escaping (Result<HIDPPController.State, Error>) -> Void) {
        controller.takeOverWheel(completion: completion)
    }

    func restoreWheel(completion: @escaping (Result<HIDPPController.State, Error>) -> Void) {
        controller.restoreWheel(completion: completion)
    }

    func verifyWheelModeSoon() {
        controller.verifyModeSoon()
    }

    func start() throws {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            break
        case kIOHIDAccessTypeDenied:
            throw HIDMonitorError.permissionDenied
        default:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            throw HIDMonitorError.permissionPending
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
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

        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, result, _, device in
                guard let context, result == kIOReturnSuccess else { return }
                Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            stop()
            throw HIDMonitorError.managerOpenFailed(result)
        }
        managerIsOpen = true
        activatePendingDevices()
    }

    func stop() {
        guard let manager else { return }
        controller.restoreSynchronously()
        removeAllSubscriptions()
        managerIsOpen = false
        pendingDevices.removeAll()
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
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
        Self.logger.info("Matched HID++ device on \(transportName, privacy: .public)")
        pendingDevices[key] = PendingDevice(device: device, transport: transport)
        if managerIsOpen { activatePendingDevices() }
    }

    /// Matching callbacks may run while IOHIDManagerOpen is still in progress.
    /// Defer report registration until the manager reports a successful open so
    /// USB and Bluetooth use the same activation order.
    private func activatePendingDevices() {
        guard managerIsOpen else { return }
        var activatedKeys: [UInt] = []
        for (key, pending) in pendingDevices {
            installRawReportSubscription(device: pending.device, key: key)
            activatedKeys.append(key)
            controller.considerDevice(pending.device, key: key, transport: pending.transport)
        }
        for key in activatedKeys { pendingDevices.removeValue(forKey: key) }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let key = Self.deviceKey(device)
        pendingDevices.removeValue(forKey: key)
        controller.removeDevice(key: key)
        removeSubscription(key: key)
    }

    /// Both transports use the same lossless raw-report path. USB exposes only
    /// HID++, while Bluetooth is composite; LMHIDPPFilteredReportCallback drops
    /// its high-rate pointer reports in C before any Swift work occurs.
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
        Self.logger.info("Raw HID++ report path active")
    }

    private func removeSubscription(key: UInt) {
        if let subscription = reportSubscriptions.removeValue(forKey: key) {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                subscription.device,
                subscription.buffer,
                subscription.capacity,
                nil,
                nil
            )
        }
    }

    private func removeAllSubscriptions() {
        for key in Array(reportSubscriptions.keys) { removeSubscription(key: key) }
    }

    private static func deviceKey(_ device: IOHIDDevice) -> UInt {
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
