import Foundation

struct HIDPPReadyDevice {
    let deviceIndex: UInt8
    let transport: HIDPPTransport
}

/// Schedules low-frequency device services without owning HID++ transport.
///
/// The controller supplies serialized hardware operations. This component owns
/// only retry/deduplication state, keeping readiness policy and optional battery
/// refresh independent from wheel takeover transactions.
final class HIDPPDeviceServiceCoordinator {
    static let readinessProbeDelays: [TimeInterval] = [0, 1, 2, 3]

    private let operationQueue: DispatchQueue
    private let lock = NSLock()
    private var readinessProbeScheduledGeneration: UInt64?
    private var deviceReadyGeneration: UInt64?
    private var batteryRefreshScheduledGeneration: UInt64?

    init(operationQueue: DispatchQueue) {
        self.operationQueue = operationQueue
    }

    func markDeviceReady(generation: UInt64) {
        lock.lock()
        deviceReadyGeneration = generation
        lock.unlock()
    }

    func probeReadiness(
        generation: UInt64,
        attempt: Int = 0,
        operation: @escaping () throws -> HIDPPReadyDevice,
        isCurrent: @escaping (UInt64) -> Bool,
        onReady: @escaping (HIDPPReadyDevice, Int) -> Void,
        onLog: @escaping (String, String) -> Void
    ) {
        guard attempt < Self.readinessProbeDelays.count else {
            onLog(
                "hidpp_readiness_probe_rejected",
                "route_generation=\(generation) attempt=\(attempt + 1) reason=attempt-out-of-range"
            )
            return
        }
        lock.lock()
        let alreadyReady = deviceReadyGeneration == generation
        let alreadyScheduled = readinessProbeScheduledGeneration == generation
        guard !alreadyReady, !alreadyScheduled else {
            lock.unlock()
            onLog(
                "hidpp_readiness_probe_deduplicated",
                "route_generation=\(generation) attempt=\(attempt + 1) "
                    + "already_ready=\(alreadyReady) already_scheduled=\(alreadyScheduled)"
            )
            return
        }
        readinessProbeScheduledGeneration = generation
        lock.unlock()

        let delay = Self.readinessProbeDelays[attempt]
        onLog(
            "hidpp_readiness_probe_scheduled",
            "route_generation=\(generation) attempt=\(attempt + 1)/\(Self.readinessProbeDelays.count) "
                + "delay=\(delay)"
        )
        operationQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let readyBeforeOperation = self.deviceReadyGeneration == generation
            self.lock.unlock()
            guard isCurrent(generation), !readyBeforeOperation else {
                self.lock.lock()
                if self.readinessProbeScheduledGeneration == generation {
                    self.readinessProbeScheduledGeneration = nil
                }
                self.lock.unlock()
                onLog("hidpp_readiness_probe_discarded", "route_generation=\(generation) before_operation=true")
                return
            }
            onLog(
                "hidpp_readiness_probe_started",
                "route_generation=\(generation) attempt=\(attempt + 1)/\(Self.readinessProbeDelays.count)"
            )
            let result = Result { try operation() }

            self.lock.lock()
            if self.readinessProbeScheduledGeneration == generation {
                self.readinessProbeScheduledGeneration = nil
            }
            let alreadyReady = self.deviceReadyGeneration == generation
            self.lock.unlock()

            let current = isCurrent(generation)
            guard current, !alreadyReady else {
                onLog(
                    "hidpp_readiness_probe_discarded",
                    "route_generation=\(generation) attempt=\(attempt + 1) "
                        + "route_current=\(current) already_ready=\(alreadyReady)"
                )
                return
            }
            switch result {
            case let .success(device):
                self.markDeviceReady(generation: generation)
                onLog(
                    "hidpp_readiness_probe_succeeded",
                    "route_generation=\(generation) attempt=\(attempt + 1) "
                        + "device=\(device.deviceIndex) transport=\(device.transport)"
                )
                onReady(device, attempt + 1)

            case let .failure(error):
                let nextAttempt = attempt + 1
                guard nextAttempt < Self.readinessProbeDelays.count else {
                    onLog(
                        "hidpp_readiness_probe_exhausted",
                        "route_generation=\(generation) attempts=\(Self.readinessProbeDelays.count) "
                            + "error=\(error.localizedDescription)"
                    )
                    return
                }
                let nextDelay = Self.readinessProbeDelays[nextAttempt]
                onLog(
                    "hidpp_readiness_probe_retry",
                    "route_generation=\(generation) completed_attempt=\(attempt + 1) "
                        + "next_attempt=\(nextAttempt + 1) delay=\(nextDelay) "
                        + "error=\(error.localizedDescription)"
                )
                self.probeReadiness(
                    generation: generation,
                    attempt: nextAttempt,
                    operation: operation,
                    isCurrent: isCurrent,
                    onReady: onReady,
                    onLog: onLog
                )
            }
        }
    }

    func refreshBattery(
        generation: UInt64,
        delay: TimeInterval = 0,
        operation: @escaping () throws -> HIDPPProtocol.BatteryInfo,
        isCurrent: @escaping (UInt64) -> Bool,
        onState: @escaping (HIDPPBatteryState) -> Void,
        onLog: @escaping (String, String) -> Void
    ) {
        lock.lock()
        guard batteryRefreshScheduledGeneration != generation else {
            lock.unlock()
            return
        }
        batteryRefreshScheduledGeneration = generation
        lock.unlock()

        onState(.loading)
        operationQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard isCurrent(generation) else {
                self.lock.lock()
                if self.batteryRefreshScheduledGeneration == generation {
                    self.batteryRefreshScheduledGeneration = nil
                }
                self.lock.unlock()
                onLog("hidpp_battery_discarded", "route_generation=\(generation) before_operation=true")
                return
            }
            let result = Result { try operation() }

            self.lock.lock()
            if self.batteryRefreshScheduledGeneration == generation {
                self.batteryRefreshScheduledGeneration = nil
            }
            self.lock.unlock()

            guard isCurrent(generation) else { return }
            switch result {
            case let .success(battery):
                onState(.available(battery))
                onLog(
                    "hidpp_battery_read",
                    "level=\(battery.percentage.map(String.init) ?? "approximate") "
                        + "state=\(battery.chargingState)"
                )
            case let .failure(error):
                onState(.unavailable)
                onLog("hidpp_battery_read_failed", error.localizedDescription)
            }
        }
    }
}
