import Foundation
import IOKit.hid

enum HIDMonitorError: LocalizedError {
    case permissionDenied
    case permissionPending
    case managerCreationFailed
    case managerOpenFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Input Monitoring permission is denied. Enable logi-mouse in System Settings → Privacy & Security → Input Monitoring, then reopen it."
        case .permissionPending:
            return "macOS has received the Input Monitoring request. Enable logi-mouse in System Settings, then quit and reopen it."
        case .managerCreationFailed:
            return "IOHIDManagerCreate returned nil."
        case let .managerOpenFailed(code):
            return String(format: "Could not open IOHIDManager (IOReturn 0x%08x).", code)
        }
    }
}

/// Owns the macOS `IOHIDManager` and translates hardware callbacks into the
/// two logical scroll axes consumed by `CaptureCoordinator`.
///
/// Runtime mode intentionally opens only the USB Receiver's vendor-defined
/// HID++ collection (`usagePage 0xff00`, `usage 1`). Pointer and keyboard
/// collections emit polling traffic even while the mouse is idle; subscribing
/// to them caused measurable wakeups and CPU use. Diagnostic mode broadens the
/// match only because it must preserve the original raw-input investigation
/// capability.
final class HIDMonitor {
    var onWheelEvent: ((HIDPPWheelEvent, UInt64) -> Void)?
    var onThumbwheelEvent: ((HIDPPThumbwheelEvent, UInt64) -> Void)?
    var onControllerStateChange: ((HIDPPController.State) -> Void)?

    private struct DeviceMetadata {
        let id: UInt64
        let product: String?
        let transport: String?
        let vendorID: Int?
        let productID: Int?
        let primaryUsagePage: Int?
        let primaryUsage: Int?
    }

    private static let logitechVendorID = 0x046d
    private static let unifyingReceiverProductID = 0xc52b
    private static let mxMaster3MacProductID = 0xb033
    private static let genericDesktopPage: UInt32 = 0x01
    private static let wheelUsage: UInt32 = 0x38
    private static let consumerPage: UInt32 = 0x0c
    private static let acPanUsage: UInt32 = 0x0238

    private let logger: JSONLLogger
    private let controller = HIDPPController()
    private let metadataLock = NSLock()
    private var devices: [UInt: DeviceMetadata] = [:]
    private var manager: IOHIDManager?

    init(logger: JSONLLogger) {
        self.logger = logger
        controller.onStateChange = { [weak self] state in
            self?.onControllerStateChange?(state)
        }
        controller.onLog = { [weak logger] layer, message in
            logger?.write(layer: layer, timestampNs: MonotonicClock.nowNanoseconds()) { record in
                record.message = message
            }
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
        // Listening to HID reports is protected by macOS Input Monitoring.
        // Requesting access is asynchronous: a not-yet-decided result must be
        // surfaced to the UI, because the process has to be reopened after the
        // user enables the permission in System Settings.
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

        let capturesRawInput = logger.records(layer: "hid_report")
        let matches: [[String: Int]]
        if capturesRawInput {
            matches = [
                [kIOHIDVendorIDKey: Self.logitechVendorID, kIOHIDProductIDKey: Self.unifyingReceiverProductID],
                [kIOHIDVendorIDKey: Self.logitechVendorID, kIOHIDProductIDKey: Self.mxMaster3MacProductID]
            ]
        } else {
            // Runtime needs only the Receiver's vendor-defined HID++ channel.
            // Excluding pointer and keyboard collections here prevents their
            // polling reports from waking this process at the device boundary.
            matches = [[
                kIOHIDVendorIDKey: Self.logitechVendorID,
                kIOHIDProductIDKey: Self.unifyingReceiverProductID,
                kIOHIDPrimaryUsagePageKey: 0xff00,
                kIOHIDPrimaryUsageKey: 1
            ]]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
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
        // HID++ commands and notifications share the same report callback.
        // The timestamp supplied by IOKit is converted using mach timebase so
        // it stays on the same monotonic timeline as CGEvent and view samples.
        IOHIDManagerRegisterInputReportWithTimeStampCallback(
            manager,
            { context, result, sender, type, reportID, report, reportLength, timestamp in
                guard let context, result == kIOReturnSuccess, reportLength > 0 else { return }
                Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().receiveReport(
                    sender: sender,
                    type: type,
                    reportID: reportID,
                    bytes: report,
                    length: Int(reportLength),
                    timestamp: timestamp
                )
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        if capturesRawInput {
            IOHIDManagerRegisterInputValueCallback(
                manager,
                { context, result, _, value in
                    guard let context, result == kIOReturnSuccess else { return }
                    Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().receive(value)
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
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
        metadataLock.lock()
        devices.removeAll()
        metadataLock.unlock()
    }

    private func receive(_ value: IOHIDValue) {
        guard logger.records(layer: "hid") else { return }
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let isPrimaryWheel = usagePage == Self.genericDesktopPage && usage == Self.wheelUsage
        let isHorizontalWheel = usagePage == Self.consumerPage && usage == Self.acPanUsage
        guard isPrimaryWheel || isHorizontalWheel else { return }

        let integerValue = IOHIDValueGetIntegerValue(value)
        guard integerValue != 0 else { return }

        let device = IOHIDElementGetDevice(element)
        let timestamp = MonotonicClock.toNanoseconds(IOHIDValueGetTimeStamp(value))
        guard timestamp >= logger.startTimestampNs else { return }
        let metadata = metadata(for: device)
        logger.write(layer: "hid", timestampNs: timestamp) { record in
            Self.fillDeviceMetadata(metadata, into: &record)
            record.usagePage = usagePage
            record.usage = usage
            record.reportID = IOHIDElementGetReportID(element)
            record.hidValue = integerValue
            record.hidLogicalMin = IOHIDElementGetLogicalMin(element)
            record.hidLogicalMax = IOHIDElementGetLogicalMax(element)
        }
    }

    private func receiveReport(
        sender: UnsafeMutableRawPointer?,
        type: IOHIDReportType,
        reportID: UInt32,
        bytes: UnsafePointer<UInt8>,
        length: Int,
        timestamp: UInt64
    ) {
        let eventTimestamp = MonotonicClock.toNanoseconds(timestamp)
        guard eventTimestamp >= logger.startTimestampNs else { return }

        let capturesRawReports = logger.records(layer: "hid_report")
        guard HIDPPProtocol.shouldProcessInputReport(
            reportID: reportID,
            capturesRawReports: capturesRawReports
        ) else {
            return
        }

        let key = sender.map { UInt(bitPattern: $0) }
        let metadata = key.flatMap(metadataForKey)
        if metadata?.primaryUsagePage == Int(Self.genericDesktopPage), metadata?.primaryUsage == 6 {
            return
        }

        let reportBytes = Array(UnsafeBufferPointer(start: bytes, count: length))
        // Responses must reach the controller before event decoding. A report
        // can be a reply to an in-flight mode command or an unsolicited wheel
        // event; the controller matches only the exact request header.
        controller.observeReport(reportBytes)
        let reportedDeviceIndex = reportBytes.count > 1 ? reportBytes[1] : 0
        let discoveredFeatureIndex = controller.featureIndex(for: reportedDeviceIndex)
        let discoveredThumbwheelFeatureIndex = controller.thumbwheelFeatureIndex(for: reportedDeviceIndex)
        let wheelEvent = HIDPPReportDecoder.decodeWheelEvent(
            reportID: reportID,
            bytes: reportBytes,
            expectedFeatureIndex: discoveredFeatureIndex
                ?? HIDPPReportDecoder.currentHiResWheelFeatureIndex
        )
        if let wheelEvent {
            controller.observeWheelRoute(
                deviceIndex: wheelEvent.deviceIndex,
                featureIndex: wheelEvent.featureIndex
            )
        }
        let thumbwheelEvent = HIDPPReportDecoder.decodeThumbwheelEvent(
            reportID: reportID,
            bytes: reportBytes,
            expectedFeatureIndex: discoveredThumbwheelFeatureIndex
                ?? HIDPPReportDecoder.currentThumbwheelFeatureIndex
        )
        if let thumbwheelEvent {
            controller.observeThumbwheelRoute(
                deviceIndex: thumbwheelEvent.deviceIndex,
                featureIndex: thumbwheelEvent.featureIndex
            )
        }

        if capturesRawReports {
            let reportHex = reportBytes
                .map { String(format: "%02x", $0) }
                .joined()
            logger.write(layer: "hid_report", timestampNs: eventTimestamp) { record in
                Self.fillDeviceMetadata(metadata, into: &record)
                if record.deviceID == nil, let key {
                    record.deviceID = UInt64(key)
                }
                record.reportType = Int(type.rawValue)
                record.reportID = reportID
                record.reportLength = length
                record.reportHex = reportHex
                record.hidppDeviceIndex = wheelEvent?.deviceIndex ?? thumbwheelEvent?.deviceIndex
                record.hidppFeatureIndex = wheelEvent?.featureIndex ?? thumbwheelEvent?.featureIndex
                record.hidppEventID = wheelEvent?.eventID ?? (thumbwheelEvent == nil ? nil : 0)
                record.hidppWheelFlags = wheelEvent?.flags
                record.hidppWheelDelta = wheelEvent?.delta
                record.hidppThumbwheelRotation = thumbwheelEvent?.rotation
                record.hidppThumbwheelStatus = thumbwheelEvent?.rotationStatus
            }
        }
        if let wheelEvent {
            onWheelEvent?(wheelEvent, eventTimestamp)
        }
        if let thumbwheelEvent {
            onThumbwheelEvent?(thumbwheelEvent, eventTimestamp)
        }
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        let key = Self.deviceKey(device)
        let metadata = Self.makeMetadata(device)
        metadataLock.lock()
        devices[key] = metadata
        metadataLock.unlock()

        // `HIDPPController` repeats the identity check before retaining the
        // IOHIDDevice. Keeping that check at the mutation boundary prevents a
        // diagnostic-mode pointer collection from becoming a writable channel.
        controller.considerReceiverDevice(
            device,
            key: key,
            vendorID: metadata.vendorID,
            productID: metadata.productID,
            primaryUsagePage: metadata.primaryUsagePage,
            primaryUsage: metadata.primaryUsage
        )

        logger.write(layer: "hid_device", timestampNs: MonotonicClock.nowNanoseconds()) { record in
            Self.fillDeviceMetadata(metadata, into: &record)
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let key = Self.deviceKey(device)
        metadataLock.lock()
        let metadata = devices.removeValue(forKey: key)
        metadataLock.unlock()
        controller.removeDevice(key: key)
        logger.write(layer: "hid_device_removed", timestampNs: MonotonicClock.nowNanoseconds()) { record in
            Self.fillDeviceMetadata(metadata, into: &record)
        }
    }

    private func metadata(for device: IOHIDDevice) -> DeviceMetadata {
        let key = Self.deviceKey(device)
        if let cached = metadataForKey(key) { return cached }
        let metadata = Self.makeMetadata(device)
        metadataLock.lock()
        devices[key] = metadata
        metadataLock.unlock()
        return metadata
    }

    private func metadataForKey(_ key: UInt) -> DeviceMetadata? {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        return devices[key]
    }

    private static func makeMetadata(_ device: IOHIDDevice) -> DeviceMetadata {
        DeviceMetadata(
            id: UInt64(deviceKey(device)),
            product: stringProperty(kIOHIDProductKey, device: device),
            transport: stringProperty(kIOHIDTransportKey, device: device),
            vendorID: integerProperty(kIOHIDVendorIDKey, device: device),
            productID: integerProperty(kIOHIDProductIDKey, device: device),
            primaryUsagePage: integerProperty(kIOHIDPrimaryUsagePageKey, device: device),
            primaryUsage: integerProperty(kIOHIDPrimaryUsageKey, device: device)
        )
    }

    private static func fillDeviceMetadata(_ metadata: DeviceMetadata?, into record: inout EventRecord) {
        guard let metadata else { return }
        record.deviceID = metadata.id
        record.deviceProduct = metadata.product
        record.transport = metadata.transport
        record.vendorID = metadata.vendorID
        record.productID = metadata.productID
        record.primaryUsagePage = metadata.primaryUsagePage
        record.primaryUsage = metadata.primaryUsage
    }

    private static func deviceKey(_ device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private static func stringProperty(_ key: String, device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func integerProperty(_ key: String, device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    deinit {
        stop()
    }
}
