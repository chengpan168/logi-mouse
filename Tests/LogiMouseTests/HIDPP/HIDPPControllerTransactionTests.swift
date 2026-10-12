import Foundation
import Testing
@testable import LogiMouse

/// Stateful firmware substitute: writes take effect even if the reply is lost.
private final class Firmware {
    struct State {
        var wheel: UInt8 = 0x02
        var thumbwheel: UInt8 = 0
        var inverted = true
        var loseWheelRead = false
        var loseThumbwheelWrite = false
        var rejectThumbwheelRestore = false
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

    private func send(_ request: HIDPPCommandChannel.Request) throws -> [UInt8] {
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
            let id = UInt16(payload[0]) << 8 | UInt16(payload[1])
            response[4] = id == 0x2121 ? 14 : (id == 0x2150 ? 15 : 0)
            let callback = state.beforeDiscoveryReply
            state.beforeDiscoveryReply = nil
            callback?()
        case (14, 1):
            if state.loseWheelRead {
                state.loseWheelRead = false
                throw HIDPPControllerError.timeout
            }
            response[4] = state.wheel
        case (14, 2):
            state.wheel = payload[0]
            state.writes.append((feature, payload[0]))
            response[4] = state.wheel
            let callback = state.beforeReply
            state.beforeReply = nil
            callback?()
        case (15, 1):
            response[4] = state.thumbwheel
            response[5] = state.inverted ? 1 : 0
            if state.thumbwheel == 1 {
                let callback = state.beforeThumbwheelReadReply
                state.beforeThumbwheelReadReply = nil
                callback?()
            }
        case (15, 2):
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
    #expect(throws: HIDPPControllerError.timeout) { try result.get() }
    #expect(firmware.snapshot.wheel == 0x02)
    #expect(firmware.snapshot.thumbwheel == 1)
    firmware.update { $0.rejectThumbwheelRestore = false }
    _ = try await restore(controller).get()
    #expect(firmware.snapshot.thumbwheel == 0)
    #expect(firmware.snapshot.inverted)
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
