import Foundation
import IOKit.hid

enum MouseConnection: Equatable, Sendable {
    case disconnected
    case usbReceiver(product: String)
    case bluetooth(product: String)

    var supportsSmoothScrolling: Bool {
        if case .usbReceiver = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .disconnected:
            "未检测到设备"
        case let .usbReceiver(product):
            product
        case let .bluetooth(product):
            product
        }
    }

    var transportName: String {
        switch self {
        case .disconnected: "未连接"
        case .usbReceiver: "USB Receiver"
        case .bluetooth: "Bluetooth"
        }
    }
}

struct HIDDeviceIdentity: Equatable, Sendable {
    let registryID: UInt64
    let product: String
    let transport: String
    let vendorID: Int
    let productID: Int
    let primaryUsagePage: Int
    let primaryUsage: Int
}

enum MouseConnectionResolver {
    static let logitechVendorID = 0x046d
    static let unifyingReceiverProductID = 0xc52b
    static let supportedBluetoothProductIDs: Set<Int> = [0xb033]

    static func resolve(_ devices: [HIDDeviceIdentity]) -> MouseConnection {
        // Prefer a directly connected Bluetooth mouse over a Receiver entry if
        // both exist; this represents the transport currently used by the mouse
        // rather than merely reporting that a dormant USB dongle is plugged in.
        if let bluetooth = devices.first(where: {
            $0.vendorID == logitechVendorID
                && supportedBluetoothProductIDs.contains($0.productID)
                && $0.transport.localizedCaseInsensitiveContains("Bluetooth")
        }) {
            return .bluetooth(product: bluetooth.product)
        }
        if let receiver = devices.first(where: {
            $0.vendorID == logitechVendorID
                && $0.productID == unifyingReceiverProductID
                && $0.primaryUsagePage == 0xff00
                && $0.primaryUsage == 1
        }) {
            return .usbReceiver(product: receiver.product)
        }
        return .disconnected
    }
}

/// Observes IORegistry device arrival/removal without opening HID input
/// collections. This is deliberately separate from `HIDMonitor`: connection
/// badges must work before Input Monitoring permission is granted, and merely
/// displaying a device must not subscribe to high-frequency pointer reports.
final class DeviceConnectionMonitor {
    var onConnectionChange: ((MouseConnection) -> Void)?

    private var notificationPort: IONotificationPortRef?
    private var firstMatchIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var devices: [UInt64: HIDDeviceIdentity] = [:]
    private(set) var connection: MouseConnection = .disconnected

    func start() {
        guard notificationPort == nil,
              let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port

        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("IOHIDDevice"),
            { context, iterator in
                guard let context else { return }
                Unmanaged<DeviceConnectionMonitor>.fromOpaque(context)
                    .takeUnretainedValue()
                    .consume(iterator: iterator, arrived: true)
            },
            context,
            &firstMatchIterator
        )
        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOHIDDevice"),
            { context, iterator in
                guard let context else { return }
                Unmanaged<DeviceConnectionMonitor>.fromOpaque(context)
                    .takeUnretainedValue()
                    .consume(iterator: iterator, arrived: false)
            },
            context,
            &terminatedIterator
        )

        // Registration returns an iterator containing all devices that already
        // exist. It must be drained once to arm future notifications.
        consume(iterator: firstMatchIterator, arrived: true)
        consume(iterator: terminatedIterator, arrived: false)
    }

    func stop() {
        if firstMatchIterator != 0 {
            IOObjectRelease(firstMatchIterator)
            firstMatchIterator = 0
        }
        if terminatedIterator != 0 {
            IOObjectRelease(terminatedIterator)
            terminatedIterator = 0
        }
        if let notificationPort {
            let source = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        devices.removeAll()
        publishIfChanged(.disconnected)
    }

    private func consume(iterator: io_iterator_t, arrived: Bool) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else {
                continue
            }
            if arrived, let device = Self.readDevice(service, registryID: registryID) {
                devices[registryID] = device
            } else if !arrived {
                devices.removeValue(forKey: registryID)
            }
        }
        publishIfChanged(MouseConnectionResolver.resolve(Array(devices.values)))
    }

    private func publishIfChanged(_ newConnection: MouseConnection) {
        guard connection != newConnection else { return }
        connection = newConnection
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionChange?(newConnection)
        }
    }

    private static func readDevice(_ service: io_service_t, registryID: UInt64) -> HIDDeviceIdentity? {
        guard let vendorID = integerProperty(kIOHIDVendorIDKey, service: service),
              vendorID == MouseConnectionResolver.logitechVendorID,
              let productID = integerProperty(kIOHIDProductIDKey, service: service) else {
            return nil
        }
        return HIDDeviceIdentity(
            registryID: registryID,
            product: stringProperty(kIOHIDProductKey, service: service) ?? "Logitech Mouse",
            transport: stringProperty(kIOHIDTransportKey, service: service) ?? "Unknown",
            vendorID: vendorID,
            productID: productID,
            primaryUsagePage: integerProperty(kIOHIDPrimaryUsagePageKey, service: service) ?? 0,
            primaryUsage: integerProperty(kIOHIDPrimaryUsageKey, service: service) ?? 0
        )
    }

    private static func integerProperty(_ key: String, service: io_service_t) -> Int? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let value = property.takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }

    private static func stringProperty(_ key: String, service: io_service_t) -> String? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let value = property.takeRetainedValue()
        return value as? String
    }

    deinit {
        stop()
    }
}
