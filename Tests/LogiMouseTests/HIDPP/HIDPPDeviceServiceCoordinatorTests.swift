import Foundation
import Testing
@testable import LogiMouse

@Test(arguments: [false, true])
func queuedReadinessProbeSkipsStaleOrAlreadyReadyDevice(alreadyReady: Bool) throws {
    let queue = DispatchQueue(label: "test.readiness")
    let finished = DispatchSemaphore(value: 0)
    let services = HIDPPDeviceServiceCoordinator(operationQueue: queue)
    queue.suspend()
    services.probeReadiness(
        generation: 7,
        operation: {
            Issue.record("An obsolete readiness probe accessed the device")
            return HIDPPReadyDevice(deviceIndex: 1, transport: .usbReceiver)
        },
        isCurrent: { _ in alreadyReady },
        onReady: { _, _ in Issue.record("An obsolete readiness probe published readiness") },
        onLog: { layer, _ in
            if layer == "hidpp_readiness_probe_discarded" { finished.signal() }
        }
    )
    if alreadyReady { services.markDeviceReady(generation: 7) }
    queue.resume()
    try #require(finished.wait(timeout: .now() + 2) == .success)
}

@Test func queuedBatteryRefreshSkipsStaleRoute() throws {
    let queue = DispatchQueue(label: "test.battery")
    let finished = DispatchSemaphore(value: 0)
    let services = HIDPPDeviceServiceCoordinator(operationQueue: queue)
    services.refreshBattery(
        generation: 7,
        operation: {
            Issue.record("An obsolete battery refresh accessed the device")
            throw HIDPPControllerError.deviceNotFound
        },
        isCurrent: { _ in false },
        onState: { state in
            #expect(state == .loading)
        },
        onLog: { layer, _ in
            if layer == "hidpp_battery_discarded" { finished.signal() }
        }
    )
    try #require(finished.wait(timeout: .now() + 2) == .success)
}

@Test func readinessProbeDiscardsResultWhenRouteChangesDuringOperation() throws {
    let queue = DispatchQueue(label: "test.readiness-result")
    let finished = DispatchSemaphore(value: 0)
    let services = HIDPPDeviceServiceCoordinator(operationQueue: queue)
    var current = true
    services.probeReadiness(
        generation: 7,
        operation: {
            current = false
            return HIDPPReadyDevice(deviceIndex: 1, transport: .usbReceiver)
        },
        isCurrent: { _ in current },
        onReady: { _, _ in Issue.record("A stale result published readiness") },
        onLog: { layer, _ in
            if layer == "hidpp_readiness_probe_discarded" { finished.signal() }
        }
    )
    try #require(finished.wait(timeout: .now() + 2) == .success)
}
