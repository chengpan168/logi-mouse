import Testing
@testable import LogiMouse

@Test func resolvesUSBReceiverConnection() {
    let connection = MouseConnectionResolver.resolve([
        HIDDeviceIdentity(
            registryID: 1,
            product: "USB Receiver",
            transport: "USB",
            vendorID: 0x046d,
            productID: 0xc52b,
            primaryUsagePage: 0xff00,
            primaryUsage: 1
        )
    ])

    #expect(connection == .usbReceiver(product: "USB Receiver"))
    #expect(connection.supportsSmoothScrolling)
}

@Test func resolvesBluetoothAndMarksItUnsupportedForTakeover() {
    let connection = MouseConnectionResolver.resolve([
        HIDDeviceIdentity(
            registryID: 2,
            product: "MX Master 3 for Mac",
            transport: "Bluetooth Low Energy",
            vendorID: 0x046d,
            productID: 0xb033,
            primaryUsagePage: 1,
            primaryUsage: 2
        )
    ])

    #expect(connection == .bluetooth(product: "MX Master 3 for Mac"))
    #expect(!connection.supportsSmoothScrolling)
}

@Test func ignoresUnrelatedHIDDevices() {
    let connection = MouseConnectionResolver.resolve([
        HIDDeviceIdentity(
            registryID: 3,
            product: "Other Mouse",
            transport: "USB",
            vendorID: 0x1234,
            productID: 0x5678,
            primaryUsagePage: 1,
            primaryUsage: 2
        )
    ])

    #expect(connection == .disconnected)
}
