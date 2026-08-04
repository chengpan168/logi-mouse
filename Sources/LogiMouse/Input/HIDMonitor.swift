import Foundation
import IOKit.hid

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
            String(format: "无法打开 Receiver HID++ 通道（IOReturn 0x%08x）。", code)
        }
    }
}

/// Runtime-only HID listener.
///
/// It opens exactly one collection: the Logitech USB Receiver vendor-defined
/// HID++ channel (`usagePage 0xff00`, `usage 1`). Pointer/keyboard collections
/// and diagnostic value callbacks are deliberately excluded, which keeps the
/// idle process from waking for polling reports and guarantees that the product
/// build never records raw input data.
final class HIDMonitor {
    var onWheelEvent: ((HIDPPWheelEvent, UInt64) -> Void)?
    var onThumbwheelEvent: ((HIDPPThumbwheelEvent, UInt64) -> Void)?
    var onControllerStateChange: ((HIDPPController.State) -> Void)?

    private static let logitechVendorID = 0x046d
    private static let unifyingReceiverProductID = 0xc52b

    private let controller = HIDPPController()
    private var manager: IOHIDManager?

    init() {
        controller.onStateChange = { [weak self] state in
            self?.onControllerStateChange?(state)
        }
    }

    func takeOverReceiverWheel(completion: @escaping (Result<HIDPPController.State, Error>) -> Void) {
        controller.takeOverReceiverWheel(completion: completion)
    }

    func restoreReceiverWheel(completion: @escaping (Result<HIDPPController.State, Error>) -> Void) {
        controller.restoreReceiverWheel(completion: completion)
    }

    func verifyReceiverWheelModeSoon() {
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
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Self.logitechVendorID,
            kIOHIDProductIDKey: Self.unifyingReceiverProductID,
            kIOHIDPrimaryUsagePageKey: 0xff00,
            kIOHIDPrimaryUsageKey: 1,
        ] as CFDictionary)

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
        IOHIDManagerRegisterInputReportWithTimeStampCallback(
            manager,
            { context, result, _, _, reportID, report, reportLength, timestamp in
                guard let context, result == kIOReturnSuccess, reportLength > 0 else { return }
                Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().receiveReport(
                    reportID: reportID,
                    bytes: report,
                    length: Int(reportLength),
                    timestamp: timestamp
                )
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            stop()
            throw HIDMonitorError.managerOpenFailed(result)
        }
    }

    func stop() {
        guard let manager else { return }
        controller.restoreSynchronously()
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
    }

    private func receiveReport(
        reportID: UInt32,
        bytes: UnsafePointer<UInt8>,
        length: Int,
        timestamp: UInt64
    ) {
        guard HIDPPProtocol.isLongInputReport(reportID) else { return }
        let reportBytes = Array(UnsafeBufferPointer(start: bytes, count: length))

        // Command replies and unsolicited wheel events share report 0x11. Give
        // the controller the report first so an exact pending request can wake
        // before attempting event decoding.
        controller.observeReport(reportBytes)
        let deviceIndex = reportBytes.count > 1 ? reportBytes[1] : 0

        let wheelEvent = HIDPPReportDecoder.decodeWheelEvent(
            reportID: reportID,
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
            reportID: reportID,
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
        controller.considerReceiverDevice(
            device,
            key: Self.deviceKey(device),
            vendorID: Self.integerProperty(kIOHIDVendorIDKey, device: device),
            productID: Self.integerProperty(kIOHIDProductIDKey, device: device),
            primaryUsagePage: Self.integerProperty(kIOHIDPrimaryUsagePageKey, device: device),
            primaryUsage: Self.integerProperty(kIOHIDPrimaryUsageKey, device: device)
        )
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        controller.removeDevice(key: Self.deviceKey(device))
    }

    private static func deviceKey(_ device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private static func integerProperty(_ key: String, device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    deinit {
        stop()
    }
}
