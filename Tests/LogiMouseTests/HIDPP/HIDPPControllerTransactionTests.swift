import Foundation
import Testing
@testable import LogiMouse

/// Stateful firmware substitute: writes take effect even if the reply is lost.
private final class Firmware {
    struct State {
        var wheel: UInt8 = 0x02
        var thumbwheel: UInt8 = 0
        var inverted = true
        var unitID: UInt32 = 0x12345678
        var wheelFeature: UInt8 = 14
        var thumbwheelFeature: UInt8 = 15
        var loseWheelRead = false
        var loseThumbwheelWrite = false
        var rejectThumbwheelRestore = false
        var rejectDiscovery = false
        var rejectIdentityRead = false
        var beforeReply: (() -> Void)?
        var beforeDiscoveryReply: (() -> Void)?
        var beforeThumbwheelReadReply: (() -> Void)?
        var writes: [(UInt8, UInt8)] = []
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ change: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&state)
    }

    var snapshot: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func channel(key: UInt) -> HIDPPCommandChannel {
        HIDPPCommandChannel(key: key, transport: .bluetooth, send: send)
    }

    func send(_ request: HIDPPCommandChannel.Request) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard case let .feature(device, feature, function, payload, _, _) = request else {
            throw HIDPPControllerError.unexpectedResponse
        }
        var response = [UInt8](repeating: 0, count: 20)
        response[0] = 0x11
        response[1] = device
        response[2] = feature
        switch (feature, function) {
        case (0, 0):
            if state.rejectDiscovery { throw HIDPPControllerError.timeout }
            let id = UInt16(payload[0]) << 8 | UInt16(payload[1])
            response[4] = id == 0x2121 ? state.wheelFeature
                : (id == 0x2150 ? state.thumbwheelFeature : (id == 0x0003 ? 3 : 0))
            let callback = state.beforeDiscoveryReply
            state.beforeDiscoveryReply = nil
            callback?()
        case (3, 0):
            if state.rejectIdentityRead { throw HIDPPControllerError.timeout }
            response[4] = 1 // Firmware entity count precedes the four-byte unit ID.
            for offset in 0..<4 {
                response[5 + offset] = UInt8(truncatingIfNeeded: state.unitID >> (24 - offset * 8))
            }
            response[10] = 3 // Bluetooth and BLE transport flags.
            response[11] = 0xb0
            response[12] = 0x23
        case (state.wheelFeature, 1):
            if state.loseWheelRead {
                state.loseWheelRead = false
                throw HIDPPControllerError.timeout
            }
            response[4] = state.wheel
        case (state.wheelFeature, 2):
            state.wheel = payload[0]
            state.writes.append((feature, payload[0]))
            response[4] = state.wheel
            let callback = state.beforeReply
            state.beforeReply = nil
            callback?()
        case (state.thumbwheelFeature, 1):
            response[4] = state.thumbwheel
            response[5] = state.inverted ? 1 : 0
            if state.thumbwheel == 1 {
                let callback = state.beforeThumbwheelReadReply
                state.beforeThumbwheelReadReply = nil
                callback?()
            }
        case (state.thumbwheelFeature, 2):
            if payload[0] == 0, state.rejectThumbwheelRestore {
                throw HIDPPControllerError.timeout
            }
            state.thumbwheel = payload[0]
            state.inverted = payload[1] != 0
            state.writes.append((feature, payload[0]))
            if state.loseThumbwheelWrite {
                state.loseThumbwheelWrite = false
                throw HIDPPControllerError.timeout
            }
        default:
            throw HIDPPControllerError.unexpectedResponse
        }
        return response
    }
}

private func receiverChannel(_ slots: [UInt8: Firmware]) -> HIDPPCommandChannel {
    HIDPPCommandChannel(key: 1, transport: .usbReceiver) { request in
        switch request {
        case let .receiverRegister(subID, address, _, _):
            return [0x10, 0xff, subID, address, 0, 1, 0]
        case let .feature(deviceIndex, _, _, _, _, _):
            guard let firmware = slots[deviceIndex] else { throw HIDPPControllerError.timeout }
            return try firmware.send(request)
        }
    }
}

private func receiverEvent(slot: UInt8, connected: Bool) -> HIDPPProtocol.ReceiverConnectionEvent {
    HIDPPProtocol.ReceiverConnectionEvent(
        deviceIndex: slot, isConnected: connected,
        notificationSubID: connected ? 0x41 : 0x40, deviceType: 2, detail: 0
    )
}

private func takeover(_ controller: HIDPPController) async -> Result<HIDPPController.State, Error> {
    await withCheckedContinuation { continuation in
        controller.takeOverWheel { continuation.resume(returning: $0) }
    }
}

private func restore(_ controller: HIDPPController) async -> Result<HIDPPController.State, Error> {
    await withCheckedContinuation { continuation in
        controller.restoreWheel { continuation.resume(returning: $0) }
    }
}

@Test @MainActor func verificationTimeoutPreservesBothRestorationSnapshots() async throws {
    let controller = HIDPPController()
    let firmware = Firmware()
    controller.considerChannel(firmware.channel(key: 1))
    _ = try await takeover(controller).get()
    firmware.update { $0.loseWheelRead = true }
    let verification = await withCheckedContinuation { continuation in
        controller.verifyMode { continuation.resume(returning: $0) }
    }
    #expect(throws: HIDPPControllerError.timeout) { try verification.get() }
    #expect(firmware.snapshot.wheel == 0x03)
    _ = try await restore(controller).get()
    #expect(firmware.snapshot.wheel == 0x02)
    #expect(firmware.snapshot.thumbwheel == 0)
    #expect(firmware.snapshot.inverted)
    #expect(firmware.snapshot.writes.count == 4)
}

@Test @MainActor func lostThumbwheelWriteReplyRollsBackBothAxes() async {
    let controller = HIDPPController()
    let firmware = Firmware()
    firmware.update { $0.loseThumbwheelWrite = true }
    controller.considerChannel(firmware.channel(key: 1))
    let result = await takeover(controller)
    #expect(throws: HIDPPControllerError.timeout) { try result.get() }
    #expect(firmware.snapshot.wheel == 0x02)
    #expect(firmware.snapshot.thumbwheel == 0)
    #expect(firmware.snapshot.inverted)
}

@Test @MainActor func failedRollbackRetainsSnapshotForLaterRestore() async throws {
    let controller = HIDPPController()
    let firmware = Firmware()
    firmware.update {
        $0.loseThumbwheelWrite = true
        $0.rejectThumbwheelRestore = true
    }
    controller.considerChannel(firmware.channel(key: 1))
    let result = await takeover(controller)
    let failure: HIDPPTakeoverFailure
    switch result {
    case .success:
        Issue.record("Takeover unexpectedly succeeded")
        return
    case let .failure(error):
        failure = try #require(error as? HIDPPTakeoverFailure)
    }
    #expect(failure.cause as? HIDPPControllerError == .timeout)
    #expect(failure.pendingRestorationAxes == HIDPPTakeoverAxes(vertical: false, horizontal: true))
    #expect(firmware.snapshot.wheel == 0x02)
    #expect(firmware.snapshot.thumbwheel == 1)
    firmware.update { $0.rejectThumbwheelRestore = false }
    _ = try await restore(controller).get()
    #expect(firmware.snapshot.thumbwheel == 0)
    #expect(firmware.snapshot.inverted)
}

@Test(arguments: [HIDPPTransport.bluetooth, .usbReceiver]) @MainActor
func sleepRebuildPreservesNativeValuesAndRediscoversFeatureAddresses(transport: HIDPPTransport) async throws {
    let controller = HIDPPController()
    let firmware = Firmware()
    firmware.update { $0.wheel = 0x06 }
    controller.considerChannel(transport == .bluetooth ? firmware.channel(key: 1) : receiverChannel([1: firmware]))
    _ = try await takeover(controller).get()
    controller.invalidateSession()
    firmware.update {
        $0.wheelFeature = 20
        $0.thumbwheelFeature = 21
    }
    controller.considerChannel(transport == .bluetooth ? firmware.channel(key: 2) : receiverChannel([3: firmware]))
    if transport == .usbReceiver {
        controller.observeReceiverConnection(deviceKey: 1, event: receiverEvent(slot: 3, connected: true))
    }
    _ = try await takeover(controller).get()
    _ = try await restore(controller).get()
    #expect(firmware.snapshot.wheel == 0x06)
    #expect(firmware.snapshot.thumbwheel == 0)
    #expect(firmware.snapshot.inverted)
}

@Test @MainActor func restoreImmediatelyAfterWakeUsesRetainedValuesAndFreshAddresses() async throws {
    let controller = HIDPPController()
    let firmware = Firmware()
    firmware.update { $0.wheel = 0x06 }
    controller.considerChannel(firmware.channel(key: 1))
    _ = try await takeover(controller).get()
    controller.invalidateSession()
    firmware.update {
        $0.wheelFeature = 20
        $0.thumbwheelFeature = 21
    }
    controller.considerChannel(firmware.channel(key: 2))
    _ = try await restore(controller).get()
    #expect(firmware.snapshot.wheel == 0x06)
    #expect(firmware.snapshot.thumbwheel == 0)
    #expect(firmware.snapshot.inverted)
}

@Test @MainActor func restorationValuesBelongToPhysicalIdentityAcrossReplacements() async throws {
    let controller = HIDPPController()
    let first = Firmware()
    first.update { $0.wheel = 0x06 }
    controller.considerChannel(first.channel(key: 1))
    _ = try await takeover(controller).get()
    controller.invalidateSession()

    let replacement = Firmware()
    replacement.update {
        $0.unitID = 0x87654321
        $0.inverted = false
    }
    controller.considerChannel(replacement.channel(key: 2))
    _ = try await takeover(controller).get()
    _ = try await restore(controller).get()
    #expect(replacement.snapshot.wheel == 0x02)
    #expect(!replacement.snapshot.inverted)
    controller.invalidateSession()

    controller.considerChannel(first.channel(key: 3))
    _ = try await takeover(controller).get()
    _ = try await restore(controller).get()
    #expect(first.snapshot.wheel == 0x06)
    #expect(first.snapshot.inverted)

    // A successful restore releases that baseline for the next user session.
    first.update {
        $0.wheel = 0x02
        $0.inverted = false
    }
    _ = try await takeover(controller).get()
    _ = try await restore(controller).get()
    #expect(first.snapshot.wheel == 0x02)
    #expect(!first.snapshot.inverted)
}

@Test @MainActor func invalidDeviceIdentityRejectsTakeoverBeforeAnyModeWrites() async {
    let controller = HIDPPController()
    let firmware = Firmware()
    firmware.update { $0.unitID = 0 }
    controller.considerChannel(firmware.channel(key: 1))
    let result = await takeover(controller)
    #expect(throws: HIDPPControllerError.unexpectedResponse) { try result.get() }
    #expect(firmware.snapshot.writes.isEmpty)
}

@Test @MainActor func unreadableIdentityAfterWakeCannotCommitAnIncompleteRollback() async throws {
    let controller = HIDPPController()
    let firmware = Firmware()
    controller.considerChannel(firmware.channel(key: 1))
    _ = try await takeover(controller).get()
    controller.invalidateSession()
    firmware.update { $0.rejectIdentityRead = true }
    controller.considerChannel(firmware.channel(key: 2))
    let result = await takeover(controller)
    guard case let .failure(error) = result else {
        Issue.record("Takeover unexpectedly succeeded without device identity")
        return
    }
    let failure = try #require(error as? HIDPPTakeoverFailure)
    #expect(failure.pendingRestorationAxes.isComplete)
    #expect(firmware.snapshot.writes.count == 2)
    firmware.update { $0.rejectIdentityRead = false }
    _ = try await restore(controller).get()
    #expect(firmware.snapshot.wheel == 0x02)
    #expect(firmware.snapshot.thumbwheel == 0)
    #expect(firmware.snapshot.inverted)
}

@Test @MainActor func otherReceiverSlotCannotRedirectTakeoverOrRestoration() async throws {
    let controller = HIDPPController()
    let first = Firmware()
    let second = Firmware()
    second.update { $0.unitID = 0x87654321 }
    controller.considerChannel(receiverChannel([1: first, 2: second]))
    controller.observeReceiverConnection(deviceKey: 1, event: receiverEvent(slot: 1, connected: true))
    _ = try await takeover(controller).get()

    #expect(controller.acceptsDeviceIndex(1))
    #expect(!controller.acceptsDeviceIndex(2))

    controller.observeReceiverConnection(deviceKey: 1, event: receiverEvent(slot: 2, connected: true))
    controller.observeWheelRoute(deviceIndex: 2, featureIndex: 14)
    controller.observeThumbwheelRoute(deviceIndex: 2, featureIndex: 15)
    _ = try await takeover(controller).get()
    _ = try await restore(controller).get()

    #expect(second.snapshot.writes.isEmpty)
    #expect(second.snapshot.thumbwheel == 0)
    #expect(first.snapshot.wheel == 0x02)
    #expect(first.snapshot.thumbwheel == 0)
    #expect(first.snapshot.inverted)
}

@Test @MainActor func pinnedReceiverSlotDoesNotScanAnotherMouseOnTimeout() async throws {
    let controller = HIDPPController()
    let first = Firmware()
    let second = Firmware()
    second.update { $0.unitID = 0x87654321 }
    controller.considerChannel(receiverChannel([1: first, 2: second]))
    controller.observeReceiverConnection(deviceKey: 1, event: receiverEvent(slot: 1, connected: true))
    _ = try await takeover(controller).get()
    first.update { $0.rejectDiscovery = true }
    let result = await takeover(controller)
    #expect(throws: HIDPPControllerError.deviceNotFound) { try result.get() }
    #expect(second.snapshot.writes.isEmpty)
}

@Test(arguments: [ScrollAxis.vertical, .horizontal]) @MainActor
func verificationDriftRevokesTheAffectedAxisBeforePublishingReady(axis: ScrollAxis) async throws {
    let controller = HIDPPController()
    let firmware = Firmware()
    controller.considerChannel(firmware.channel(key: 1))
    _ = try await takeover(controller).get()
    firmware.update {
        if axis == .vertical { $0.wheel = 0x06 } else { $0.thumbwheel = 0 }
    }
    var evidence: [HIDPPTakeoverAxes] = []
    controller.onTakeoverAxesChange = { evidence.append($0) }
    let result = await withCheckedContinuation { continuation in
        controller.verifyMode { continuation.resume(returning: $0) }
    }
    #expect(try result.get().isComplete)
    #expect(evidence.first == HIDPPTakeoverAxes(vertical: axis != .vertical, horizontal: axis != .horizontal))
    #expect(evidence.last?.isComplete == true)
    _ = try await restore(controller).get()
    #expect(firmware.snapshot.inverted)
}

@Test @MainActor func activeReceiverDisconnectIsRecognizedAfterAnotherMouseAppears() async throws {
    let controller = HIDPPController()
    let first = Firmware()
    controller.considerChannel(receiverChannel([1: first]))
    controller.observeReceiverConnection(deviceKey: 1, event: receiverEvent(slot: 1, connected: true))
    _ = try await takeover(controller).get()
    var disconnected = false
    controller.onStateChange = { if $0 == .unavailable { disconnected = true } }
    controller.observeReceiverConnection(deviceKey: 1, event: receiverEvent(slot: 2, connected: true))
    controller.observeReceiverConnection(deviceKey: 1, event: receiverEvent(slot: 1, connected: false))
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(disconnected)
}

@Test @MainActor func routeChangeDuringWriteCannotCommitOrWriteToReplacement() async throws {
    let controller = HIDPPController()
    let oldFirmware = Firmware()
    let replacement = Firmware()
    controller.considerChannel(oldFirmware.channel(key: 1))
    oldFirmware.update { state in
        state.beforeReply = {
            controller.removeDevice(key: 1)
            controller.considerChannel(replacement.channel(key: 2))
        }
    }
    let result = await takeover(controller)
    #expect(throws: HIDPPControllerError.transportChanged) { try result.get() }
    #expect(replacement.snapshot.writes.isEmpty)
    #expect(oldFirmware.snapshot.writes.count == 1)
    _ = try await takeover(controller).get()
    _ = try await restore(controller).get()
    #expect(replacement.snapshot.wheel == 0x02)
    #expect(replacement.snapshot.thumbwheel == 0)
}

@Test @MainActor func shutdownRestoresAfterVerificationTimeout() async throws {
    let controller = HIDPPController()
    let firmware = Firmware()
    controller.considerChannel(firmware.channel(key: 1))
    _ = try await takeover(controller).get()
    firmware.update { $0.loseWheelRead = true }
    let verification = await withCheckedContinuation { continuation in
        controller.verifyMode { continuation.resume(returning: $0) }
    }
    #expect(throws: HIDPPControllerError.timeout) { try verification.get() }
    controller.restoreSynchronously()
    controller.invalidateSession()
    #expect(firmware.snapshot.wheel == 0x02)
    #expect(firmware.snapshot.thumbwheel == 0)
    #expect(firmware.snapshot.inverted)
}

@Test @MainActor func retiredSessionRejectsTakeoverWithoutWriting() async {
    let controller = HIDPPController()
    let firmware = Firmware()
    controller.considerChannel(firmware.channel(key: 1))
    controller.invalidateSession()
    let result = await takeover(controller)
    #expect(throws: HIDPPControllerError.noHIDPPChannel) { try result.get() }
    #expect(firmware.snapshot.writes.isEmpty)
}

@Test @MainActor func queuedTakeoverKeepsItsOriginalRoute() async throws {
    let controller = HIDPPController()
    let oldFirmware = Firmware()
    let replacement = Firmware()
    let probeStarted = DispatchSemaphore(value: 0)
    let releaseProbe = DispatchSemaphore(value: 0)
    defer { releaseProbe.signal() }
    oldFirmware.update { state in
        state.beforeDiscoveryReply = {
            probeStarted.signal()
            _ = releaseProbe.wait(timeout: .now() + 2)
        }
    }
    controller.considerChannel(oldFirmware.channel(key: 1))
    let started = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: probeStarted.wait(timeout: .now() + 2))
        }
    }
    try #require(started == .success)
    let result = await withCheckedContinuation { continuation in
        controller.takeOverWheel { continuation.resume(returning: $0) }
        controller.removeDevice(key: 1)
        controller.considerChannel(replacement.channel(key: 2))
        releaseProbe.signal()
    }
    #expect(throws: HIDPPControllerError.transportChanged) { try result.get() }
    #expect(oldFirmware.snapshot.writes.isEmpty)
    #expect(replacement.snapshot.writes.isEmpty)
}

@Test @MainActor func routeChangeBeforeMainQueueDeliveryDropsReadyAndAxisEvidence() async {
    let controller = HIDPPController()
    let firmware = Firmware()
    var readyCount = 0
    var completeAxesCount = 0
    controller.onStateChange = { state in
        if case .ready = state { readyCount += 1 }
    }
    controller.onTakeoverAxesChange = { axes in
        if axes.isComplete { completeAxesCount += 1 }
    }
    firmware.update { state in
        state.beforeThumbwheelReadReply = {
            DispatchQueue.main.async { controller.removeDevice(key: 1) }
        }
    }
    controller.considerChannel(firmware.channel(key: 1))
    let result = await takeover(controller)
    #expect(throws: HIDPPControllerError.transportChanged) { try result.get() }
    #expect(readyCount == 0)
    #expect(completeAxesCount == 0)
}
