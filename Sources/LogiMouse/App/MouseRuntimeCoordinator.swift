import Foundation

/// Application-level owner of mouse runtime state and side effects.
///
/// The coordinator implements a small unidirectional state machine:
///
///     callback/UI/timer -> MouseRuntimeEvent -> reducer
///                       -> MouseRuntimeState + MouseRuntimeEffect
///                       -> monitor/controller command -> result event
///
/// `HIDMonitor` and `HIDPPController` still own callback-lifetime IOKit objects
/// and serialized HID++ transactions. They do not decide application lifecycle
/// or whether old callbacks remain valid; this coordinator is the only owner of
/// those decisions through `runtimeState.generation`.
@MainActor
final class MouseRuntimeCoordinator {
    static let modelDiagnosticSampleLimit = ScrollOutputPipeline.diagnosticSampleLimit

    private(set) var runtimeState = MouseRuntimeState()

    /// Compatibility-facing name used by the current settings window. Its
    /// meaning is user intent, not proof that firmware is currently diverted.
    var isTakeoverEnabled: Bool { runtimeState.takeoverRequested }
    var isRunning: Bool { runtimeState.isRunning }

    var onRuntimeStateChange: ((MouseRuntimeState) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onControllerStateChange: ((HIDPPController.State) -> Void)?
    var onConnectionChange: ((MouseConnection) -> Void)?
    var onBatteryStateChange: ((HIDPPBatteryState) -> Void)?

    private var reducer = MouseRuntimeReducer()
    private let systemLifecycleMonitor = SystemLifecycleMonitor()
    private var connectionMonitor: DeviceConnectionMonitor?
    private var hidMonitor: HIDMonitor?
    private var eventMonitor: CGEventMonitor?
    private var wakeRetryWorkItem: DispatchWorkItem?
    private var takeoverRetryWorkItem: DispatchWorkItem?
    private var commandSequence: UInt64 = 0
    private var activeCommand: UInt64?
    private var hardwareCommandInFlight: Bool { activeCommand != nil }
    private let preferences: MouseUserPreferences
    private var eventSequence: UInt64 = 0
    private var sleepBeganAt: Date?
    private(set) var scrollDirection: ScrollDirectionMapping = .natural
    /// The only owner of high-frequency model state and native-scroll
    /// correlation. Keeping it outside the main actor prevents one task per HID
    /// report from competing with pointer event delivery.
    private let scrollOutputPipeline = ScrollOutputPipeline()

    init(preferences: MouseUserPreferences = MouseUserPreferences()) {
        self.preferences = preferences
        runtimeState.takeoverRequested = preferences.smoothScrollingEnabled
        scrollDirection = preferences.scrollDirection
        systemLifecycleMonitor.onWillSleep = { [weak self] in
            self?.handleSystemWillSleep()
        }
        systemLifecycleMonitor.onDidWake = { [weak self] in
            self?.handleSystemDidWake()
        }
    }

    /// Starts the control-plane power observer and the first data-plane
    /// generation. Startup remains throwing so permission errors can be shown
    /// synchronously by the existing settings window.
    func start() throws {
        systemLifecycleMonitor.start()
        try send(.startRequested)
        if !runtimeState.takeoverRequested { onStatusChange?("已就绪") }
    }

    func setTakeoverEnabled(
        _ enabled: Bool,
        completion: @escaping (Result<HIDPPController.State, Error>) -> Void
    ) {
        RuntimeLog.notice(
            "takeover",
            "User takeover change requested enabled=\(enabled) state={\(runtimeDiagnosticSnapshot)}"
        )
        if !enabled {
            takeoverRetryWorkItem?.cancel()
            takeoverRetryWorkItem = nil
            if !isRunning {
                guard runtimeState.lifecycle == .stopped else {
                    completion(.failure(HIDPPControllerError.noHIDPPChannel))
                    return
                }
                try? send(.takeoverIntentChanged(false))
                preferences.smoothScrollingEnabled = false
                syncScrollOutputPipeline()
                completion(.success(.unavailable))
                return
            }
        }
        guard isRunning, let hidMonitor else {
            RuntimeLog.warning(
                "takeover",
                "User takeover change rejected enabled=\(enabled) reason=no-active-hid-monitor "
                    + "state={\(runtimeDiagnosticSnapshot)}"
            )
            completion(.failure(HIDPPControllerError.noHIDPPChannel))
            return
        }

        let generation = runtimeState.generation
        let command = beginCommand()
        preferences.smoothScrollingEnabled = enabled
        if enabled {
            try? send(.takeoverIntentChanged(true))
            try? send(.takeoverStarted(generation: generation))
            onStatusChange?("正在接管鼠标滚轮…")
            hidMonitor.takeOverWheel { [weak self] result in
                // The request may finish after sleep or a monitor rebuild.
                // Its hardware result and UI completion both belong to the old
                // generation and must not overwrite durable wake state.
                guard let self,
                      self.runtimeState.generation == generation else { return }
                guard self.finishCommand(command) else { return }
                if case .failure(HIDPPControllerError.transportChanged) = result {
                    self.retryAfterRouteChange()
                    completion(result)
                    return
                }
                switch result {
                case let .success(controllerState):
                    self.preferences.smoothScrollingEnabled = true
                    self.armModelDiagnostics(reason: "user-takeover-succeeded")
                    RuntimeLog.notice(
                        "takeover",
                        "User takeover succeeded generation=\(generation) controller={\(controllerState)} "
                            + "state={\(self.runtimeDiagnosticSnapshot)}"
                    )
                    try? self.send(.takeoverSucceeded(generation: generation))
                case let .failure(error):
                    RuntimeLog.error(
                        "takeover",
                        "User takeover failed generation=\(generation) error=\(error.localizedDescription) "
                            + "state={\(self.runtimeDiagnosticSnapshot)}"
                    )
                    // A direct user action is transactional: failure returns the
                    // switch to OFF. Sleep recovery uses a separate effect that
                    // deliberately preserves intent across bounded failures.
                    self.preferences.smoothScrollingEnabled = false
                    try? self.send(.takeoverIntentChanged(false))
                    try? self.send(.takeoverFailed(
                        message: error.localizedDescription,
                        recoveryAttempt: nil,
                        generation: generation
                    ))
                }
                completion(result)
            }
        } else {
            try? send(.takeoverIntentChanged(false))
            try? send(.restorationStarted(generation: generation))
            onStatusChange?("正在恢复系统原生滚动…")
            hidMonitor.restoreWheel { [weak self] result in
                guard let self,
                      self.runtimeState.generation == generation else { return }
                guard self.finishCommand(command) else { return }
                switch result {
                case .failure(HIDPPControllerError.transportChanged):
                    // The old physical route is gone. Preserve the OFF intent
                    // instead of re-arming takeover on the replacement device.
                    self.preferences.smoothScrollingEnabled = false
                    completion(.success(.unavailable))
                    return
                case let .success(controllerState):
                    RuntimeLog.notice(
                        "takeover",
                        "User restoration succeeded generation=\(generation) controller={\(controllerState)} "
                            + "state={\(self.runtimeDiagnosticSnapshot)}"
                    )
                    self.preferences.smoothScrollingEnabled = false
                    try? self.send(.restorationSucceeded(generation: generation))
                case let .failure(error):
                    RuntimeLog.error(
                        "takeover",
                        "User restoration failed generation=\(generation) error=\(error.localizedDescription) "
                            + "state={\(self.runtimeDiagnosticSnapshot)}"
                    )
                    self.preferences.smoothScrollingEnabled = true
                    try? self.send(.restorationFailed(
                        message: error.localizedDescription,
                        generation: generation
                    ))
                }
                completion(result)
            }
        }
    }

    func setDirection(_ direction: ScrollDirectionMapping) {
        let previous = scrollDirection
        scrollDirection = direction
        preferences.scrollDirection = direction
        syncScrollOutputPipeline()
        RuntimeLog.notice(
            "takeover",
            "Scroll direction applied from=\(previous.rawValue) to=\(direction.rawValue) "
                + "multiplier=\(direction.multiplier) generation=\(runtimeState.generation)"
        )
    }

    /// Performs a low-frequency read-back when the control window opens.
    /// Ordinary scroll reports remain pure data events and never enter this path.
    func verifyTakeoverMode() {
        guard isRunning, isTakeoverEnabled, !hardwareCommandInFlight else {
            RuntimeLog.debug(
                "takeover",
                "Verification skipped running=\(isRunning) requested=\(isTakeoverEnabled) "
                    + "state={\(runtimeDiagnosticSnapshot)}"
            )
            return
        }
        let generation = runtimeState.generation
        let command = beginCommand()
        RuntimeLog.notice(
            "takeover",
            "Verification requested generation=\(generation) state={\(runtimeDiagnosticSnapshot)}"
        )
        try? send(.verificationStarted(generation: generation))
        hidMonitor?.verifyWheelMode { [weak self] result in
            guard let self,
                  self.runtimeState.generation == generation else { return }
            guard self.finishCommand(command) else { return }
            switch result {
            case let .success(axes):
                self.armModelDiagnostics(reason: "verification-succeeded")
                RuntimeLog.notice(
                    "takeover",
                    "Verification succeeded generation=\(generation) "
                        + "axes={vertical:\(axes.vertical),horizontal:\(axes.horizontal)}"
                )
                try? self.send(.verificationSucceeded(axes, generation: generation))
            case .failure(HIDPPControllerError.transportChanged):
                self.retryAfterRouteChange()
            case let .failure(error):
                RuntimeLog.error(
                    "takeover",
                    "Verification failed generation=\(generation) error=\(error.localizedDescription) "
                        + "state={\(self.runtimeDiagnosticSnapshot)}"
                )
                try? self.send(.verificationFailed(
                    message: error.localizedDescription,
                    generation: generation
                ))
            }
        }
    }

    func refreshBattery() {
        guard isRunning else { return }
        hidMonitor?.refreshBattery()
    }

    /// Stops permanently and restores hardware when possible. System sleep must
    /// use the reducer's suspend effect instead; conflating the two paths caused
    /// synchronous HID timeouts while the machine was going to sleep.
    func stop() {
        try? send(.stopRequested)
        systemLifecycleMonitor.stop()
        resetModelsAndCorrelation()
        syncScrollOutputPipeline()
    }

    // MARK: - State machine

    private func handleSystemWillSleep() {
        sleepBeganAt = Date()
        RuntimeLog.notice(
            "power",
            "========== SYSTEM WILL SLEEP | before={\(runtimeDiagnosticSnapshot)} =========="
        )
        handleLifecycleEvent(.systemWillSleep)
        RuntimeLog.notice(
            "power",
            "========== SYSTEM SUSPEND HANDLING FINISHED | after={\(runtimeDiagnosticSnapshot)} =========="
        )
        RuntimeLog.flush()
    }

    private func handleSystemDidWake() {
        let now = Date()
        let sleepDuration = sleepBeganAt.map { now.timeIntervalSince($0) }
        RuntimeLog.notice(
            "power",
            "========== SYSTEM DID WAKE | elapsedSinceWillSleepSeconds=\(sleepDuration.map { String(format: "%.3f", $0) } ?? "unknown") before={\(runtimeDiagnosticSnapshot)} =========="
        )
        handleLifecycleEvent(.systemDidWake)
        RuntimeLog.notice(
            "power",
            "========== SYSTEM WAKE HANDLING SCHEDULED | after={\(runtimeDiagnosticSnapshot)} =========="
        )
        sleepBeganAt = nil
    }

    private func handleLifecycleEvent(_ event: MouseRuntimeEvent) {
        do {
            try send(event)
        } catch {
            RuntimeLog.error("runtime", "Lifecycle event failed event=\(String(describing: event)) error=\(error.localizedDescription)")
            onStatusChange?(error.localizedDescription)
        }
    }

    /// Reduces one event, publishes the new aggregate state, then executes the
    /// returned effects in order. Effects report completion by sending another
    /// event; no effect mutates `runtimeState` directly.
    private func send(_ event: MouseRuntimeEvent) throws {
        eventSequence &+= 1
        let sequence = eventSequence
        let eventName = String(describing: event)
        let previous = runtimeState
        RuntimeLog.info(
            "state-machine",
            "BEGIN sequence=\(sequence) event=\(eventName) before={\(runtimeDiagnosticSnapshot)}"
        )
        let effects = reducer.reduce(state: &runtimeState, event: event)
        let effectsDescription = effects.isEmpty
            ? "[]"
            : "[\(effects.map { String(describing: $0) }.joined(separator: ", "))]"
        syncScrollOutputPipeline()
        if runtimeState != previous {
            RuntimeLog.notice(
                "state-machine",
                "REDUCED sequence=\(sequence) changed=true event=\(eventName) effects=\(effectsDescription) "
                    + "before={\(previous.diagnosticDescription)} after={\(runtimeState.diagnosticDescription)}"
            )
            onRuntimeStateChange?(runtimeState)
        } else {
            RuntimeLog.debug(
                "state-machine",
                "REDUCED sequence=\(sequence) changed=false event=\(eventName) effects=\(effectsDescription) "
                    + "before={\(previous.diagnosticDescription)} after={\(runtimeState.diagnosticDescription)}"
            )
        }
        for effect in effects {
            RuntimeLog.info(
                "state-machine",
                "EFFECT-BEGIN sequence=\(sequence) effect=\(String(describing: effect)) state={\(runtimeDiagnosticSnapshot)}"
            )
            try execute(effect)
            RuntimeLog.info(
                "state-machine",
                "EFFECT-END sequence=\(sequence) effect=\(String(describing: effect)) state={\(runtimeDiagnosticSnapshot)}"
            )
        }
        RuntimeLog.info(
            "state-machine",
            "END sequence=\(sequence) event=\(eventName) after={\(runtimeDiagnosticSnapshot)}"
        )
        // Keep the hot-path gate in sync with the reduced state without making
        // HID reports themselves enter this actor.
        syncScrollOutputPipeline()
    }

    private var runtimeDiagnosticSnapshot: String {
        runtimeState.diagnosticDescription
            + " direction=\(scrollDirection.rawValue)"
            + " directionMultiplier=\(scrollDirection.multiplier)"
            + " outputGate={vertical:\(outputIsActive(.vertical)),horizontal:\(outputIsActive(.horizontal))}"
            + " monitors={lifecycle:true,connection:\(connectionMonitor != nil),hid:\(hidMonitor != nil),cgEvent:\(eventMonitor != nil)}"
            + " work={wakeTimer:\(wakeRetryWorkItem != nil),takeoverRetryTimer:\(takeoverRetryWorkItem != nil),takeoverRecovery:\(hardwareCommandInFlight)}"
    }

    private func execute(_ effect: MouseRuntimeEffect) throws {
        switch effect {
        case let .startMonitoring(generation):
            do {
                RuntimeLog.info("runtime", "Starting runtime monitors generation=\(generation)")
                try startRuntimeMonitors(generation: generation)
                try send(.monitoringStarted(generation: generation))
            } catch {
                RuntimeLog.error("runtime", "Runtime monitor start failed generation=\(generation) error=\(error.localizedDescription)")
                try? send(.monitoringStartFailed(
                    message: error.localizedDescription,
                    generation: generation
                ))
                throw error
            }

        case let .suspendMonitoring(generation):
            RuntimeLog.notice("runtime", "Suspending runtime monitors generation=\(generation)")
            cancelScheduledWork()
            stopRuntimeMonitors(restoringHardware: false)
            resetModelsAndCorrelation()
            try send(.monitoringSuspended(generation: generation))
            onStatusChange?("系统已睡眠，鼠标监听已安全挂起")

        case let .scheduleWakeStart(attempt, generation, delay):
            RuntimeLog.notice("runtime", "Scheduling wake rebuild generation=\(generation) attempt=\(attempt) delaySeconds=\(delay)")
            wakeRetryWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.wakeRetryWorkItem = nil
                RuntimeLog.info("runtime", "Wake rebuild timer fired generation=\(generation) attempt=\(attempt)")
                do {
                    try self.send(.wakeRetryTimerFired(attempt: attempt, generation: generation))
                } catch {
                    RuntimeLog.error("runtime", "Wake rebuild failed generation=\(generation) attempt=\(attempt) error=\(error.localizedDescription)")
                }
            }
            wakeRetryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            onStatusChange?("系统已唤醒，等待 HID 服务恢复…")

        case let .scheduleTakeoverRecovery(attempt, generation, delay):
            RuntimeLog.notice(
                "runtime",
                "Scheduling takeover recovery generation=\(generation) attempt=\(attempt) delaySeconds=\(delay)"
            )
            takeoverRetryWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.takeoverRetryWorkItem = nil
                RuntimeLog.info(
                    "runtime",
                    "Takeover recovery timer fired generation=\(generation) attempt=\(attempt)"
                )
                do {
                    try self.send(.takeoverRetryTimerFired(
                        attempt: attempt,
                        generation: generation
                    ))
                } catch {
                    RuntimeLog.error(
                        "runtime",
                        "Scheduled takeover recovery failed generation=\(generation) attempt=\(attempt) error=\(error.localizedDescription)"
                    )
                }
            }
            takeoverRetryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            onStatusChange?("恢复失败，\(Int(delay)) 秒后重试（第 \(attempt) 次）…")

        case let .recoverTakeover(attempt, generation):
            recoverTakeover(attempt: attempt, generation: generation)

        case let .stopMonitoring(generation):
            RuntimeLog.notice("runtime", "Stopping runtime monitors generation=\(generation) restoringHardware=true")
            cancelScheduledWork()
            stopRuntimeMonitors(restoringHardware: true)
            try send(.monitoringStopped(generation: generation))
        }
    }

    // MARK: - Monitor generations

    private func startRuntimeMonitors(generation: UInt64) throws {
        // Never layer a new generation over partially alive resources. This is
        // also the cleanup path after a failed wake attempt.
        stopRuntimeMonitors(restoringHardware: false)

        let connectionMonitor = DeviceConnectionMonitor()
        let hidMonitor = HIDMonitor()
        let eventMonitor = CGEventMonitor()
        wire(
            connectionMonitor: connectionMonitor,
            hidMonitor: hidMonitor,
            eventMonitor: eventMonitor,
            generation: generation
        )

        self.connectionMonitor = connectionMonitor
        self.hidMonitor = hidMonitor
        self.eventMonitor = eventMonitor
        RuntimeLog.info("runtime", "Monitor rebuild stage=connection-start generation=\(generation)")
        connectionMonitor.start()
        do {
            RuntimeLog.info("runtime", "Monitor rebuild stage=hid-start generation=\(generation)")
            try hidMonitor.start()
            RuntimeLog.info("runtime", "Monitor rebuild stage=cg-event-start generation=\(generation) suppressionEnabled=true")
            try eventMonitor.start(suppressionEnabled: true)
            RuntimeLog.info("runtime", "All runtime monitors started generation=\(generation)")
        } catch {
            RuntimeLog.error("runtime", "Partial monitor startup rolled back generation=\(generation) error=\(error.localizedDescription)")
            stopRuntimeMonitors(restoringHardware: false)
            throw error
        }
    }

    private func stopRuntimeMonitors(restoringHardware: Bool) {
        RuntimeLog.info(
            "runtime",
            "Releasing runtime monitors restoringHardware=\(restoringHardware) cgEvent=\(eventMonitor != nil) connection=\(connectionMonitor != nil) hid=\(hidMonitor != nil)"
        )
        // Close the output gate before tearing down listeners. Any report that
        // races with cancellation is then rejected by generation/enable checks.
        scrollOutputPipeline.deactivate(generation: runtimeState.generation)
        if eventMonitor != nil { RuntimeLog.info("runtime", "Monitor teardown stage=cg-event-stop") }
        eventMonitor?.stop()
        if connectionMonitor != nil { RuntimeLog.info("runtime", "Monitor teardown stage=connection-stop") }
        connectionMonitor?.stop()
        if hidMonitor != nil {
            RuntimeLog.info(
                "runtime",
                "Monitor teardown stage=hid-\(restoringHardware ? "stop-and-restore" : "suspend-without-write")"
            )
        }
        if restoringHardware {
            hidMonitor?.stop()
        } else {
            hidMonitor?.suspend()
        }
        eventMonitor = nil
        connectionMonitor = nil
        hidMonitor = nil
        RuntimeLog.info(
            "runtime",
            "Runtime monitor release completed restoringHardware=\(restoringHardware) cgEvent=false connection=false hid=false"
        )
    }

    private func wire(
        connectionMonitor: DeviceConnectionMonitor,
        hidMonitor: HIDMonitor,
        eventMonitor: CGEventMonitor,
        generation: UInt64
    ) {
        connectionMonitor.onConnectionChange = { [weak self] connection in
            guard let self,
                  self.runtimeState.generation == generation else { return }
            self.onConnectionChange?(connection)
        }
        // These callbacks run on HIDMonitor's dedicated queue. Capture only the
        // pipeline and generation; touching the @MainActor coordinator here
        // would recreate the per-report main-run-loop backlog.
        let pipeline = scrollOutputPipeline
        hidMonitor.onWheelEvent = { event, timestamp in
            pipeline.enqueueWheel(event, timestampNs: timestamp, generation: generation)
        }
        hidMonitor.onThumbwheelEvent = { event, timestamp in
            pipeline.enqueueThumbwheel(event, timestampNs: timestamp, generation: generation)
        }
        hidMonitor.onControllerStateChange = { [weak self] controllerState in
            guard let self,
                  self.runtimeState.generation == generation else { return }
            try? self.send(.controllerState(controllerState, generation: generation))
            self.onControllerStateChange?(controllerState)
            self.publishStatus(for: controllerState)
        }
        hidMonitor.onTakeoverAxesChange = { [weak self] axes in
            guard let self,
                  self.runtimeState.generation == generation else { return }
            let previousAxes = self.runtimeState.verifiedAxes
            try? self.send(.takeoverAxesChanged(axes, generation: generation))
            self.syncScrollOutputPipeline()
            RuntimeLog.notice(
                "takeover",
                "Axis evidence changed generation=\(generation) "
                    + "from={vertical:\(previousAxes.vertical),horizontal:\(previousAxes.horizontal)} "
                    + "to={vertical:\(axes.vertical),horizontal:\(axes.horizontal)} "
                    + "state={\(self.runtimeDiagnosticSnapshot)}"
            )
        }
        hidMonitor.onBatteryStateChange = { [weak self] batteryState in
            guard let self,
                  self.runtimeState.generation == generation else { return }
            self.onBatteryStateChange?(batteryState)
        }
        eventMonitor.shouldSuppressVerticalScroll = { [pipeline] in
            pipeline.shouldSuppress(
                .vertical,
                timestampNs: MonotonicClock.nowNanoseconds()
            )
        }
        eventMonitor.shouldSuppressHorizontalScroll = { [pipeline] in
            pipeline.shouldSuppress(
                .horizontal,
                timestampNs: MonotonicClock.nowNanoseconds()
            )
        }
        eventMonitor.scrollDiagnosticContext = { [weak self] in
            guard let self else { return "runtime=deallocated generation=\(generation)" }
            return "generation=\(generation) current_generation=\(self.runtimeState.generation) "
                + "direction=\(self.scrollDirection.rawValue) "
                + "direction_multiplier=\(self.scrollDirection.multiplier) "
                + "takeover_requested=\(self.runtimeState.takeoverRequested) "
                + "verified_axes={vertical:\(self.runtimeState.verifiedAxes.vertical),horizontal:\(self.runtimeState.verifiedAxes.horizontal)} "
                + "output_gate={vertical:\(self.outputIsActive(.vertical)),horizontal:\(self.outputIsActive(.horizontal))}"
        }
    }

    private func recoverTakeover(attempt: Int, generation: UInt64) {
        guard runtimeState.generation == generation,
              runtimeState.takeoverRequested,
              runtimeState.isRunning,
              !hardwareCommandInFlight,
              let hidMonitor else {
            RuntimeLog.debug(
                "runtime",
                "Takeover recovery skipped generation=\(generation) attempt=\(attempt) currentGeneration=\(runtimeState.generation) requested=\(runtimeState.takeoverRequested) running=\(runtimeState.isRunning) inFlight=\(hardwareCommandInFlight) hidAvailable=\(self.hidMonitor != nil)"
            )
            return
        }
        RuntimeLog.notice("runtime", "Starting takeover recovery generation=\(generation) attempt=\(attempt)")
        takeoverRetryWorkItem?.cancel()
        takeoverRetryWorkItem = nil
        let command = beginCommand()
        try? send(.takeoverStarted(generation: generation))
        onStatusChange?("设备通道已就绪，正在恢复鼠标接管…")
        hidMonitor.takeOverWheel { [weak self] result in
            guard let self,
                  self.runtimeState.generation == generation,
                  self.runtimeState.isRunning else { return }
            guard self.finishCommand(command) else { return }
            switch result {
            case .success:
                self.armModelDiagnostics(reason: "wake-takeover-recovery-succeeded")
                RuntimeLog.notice("runtime", "Takeover recovery succeeded generation=\(generation) attempt=\(attempt)")
                try? self.send(.takeoverSucceeded(generation: generation))
                self.onStatusChange?("平滑滚动已恢复")
            case .failure(HIDPPControllerError.transportChanged):
                self.retryAfterRouteChange()
            case let .failure(error):
                RuntimeLog.error("runtime", "Takeover recovery failed generation=\(generation) attempt=\(attempt) error=\(error.localizedDescription)")
                try? self.send(.takeoverFailed(
                    message: error.localizedDescription,
                    recoveryAttempt: attempt,
                    generation: generation
                ))
                if attempt > MouseRuntimeReducer.takeoverRecoveryRetryDelays.count {
                    self.onStatusChange?("恢复重试已耗尽，等待设备重新连接：\(error.localizedDescription)")
                }
            }
        }
    }

    private func beginCommand() -> UInt64 {
        commandSequence &+= 1
        activeCommand = commandSequence
        return commandSequence
    }

    private func finishCommand(_ command: UInt64) -> Bool {
        guard activeCommand == command else { return false }
        activeCommand = nil
        return true
    }

    private func retryAfterRouteChange() {
        // The stale operation must not overwrite deviceReady from the new route.
        // Once its busy gate is released, consume that readiness through the
        // same reducer event and bounded recovery path.
        try? send(.takeoverRecoveryRequested)
    }

    private func cancelScheduledWork() {
        if wakeRetryWorkItem != nil || takeoverRetryWorkItem != nil || hardwareCommandInFlight {
            RuntimeLog.info(
                "runtime",
                "Cancelling scheduled runtime work wakeTimer=\(wakeRetryWorkItem != nil) takeoverRetryTimer=\(takeoverRetryWorkItem != nil) takeoverRecovery=\(hardwareCommandInFlight)"
            )
        }
        wakeRetryWorkItem?.cancel()
        wakeRetryWorkItem = nil
        takeoverRetryWorkItem?.cancel()
        takeoverRetryWorkItem = nil
        activeCommand = nil
    }

    private func outputIsActive(_ axis: ScrollAxis) -> Bool {
        runtimeState.outputIsVerified(for: axis)
    }

    /// Copies the low-frequency application gate into the dedicated input
    /// pipeline. The copy is value-based and synchronous only with the small
    /// pipeline configuration/reset operation; no HID event waits on the main
    /// actor after this method returns.
    private func syncScrollOutputPipeline() {
        scrollOutputPipeline.configure(
            generation: runtimeState.generation,
            direction: scrollDirection,
            verticalEnabled: outputIsActive(.vertical),
            horizontalEnabled: outputIsActive(.horizontal)
        )
    }

    private func resetModelsAndCorrelation() {
        scrollOutputPipeline.reset()
    }

    private func armModelDiagnostics(reason: String) {
        scrollOutputPipeline.armDiagnostics(reason: reason)
    }

    private func publishStatus(for state: HIDPPController.State) {
        guard runtimeState.takeoverRequested else { return }
        switch state {
        case .unavailable:
            onStatusChange?("鼠标 HID++ 通道已断开，等待重新连接…")
        case let .channelReady(transport), let .deviceReady(transport):
            onStatusChange?("正在通过 \(transport) 恢复滚轮接管…")
        case .discovering:
            onStatusChange?("正在重新发现鼠标滚轮能力…")
        case .ready:
            onStatusChange?("平滑滚动已开启")
        case let .failed(message):
            onStatusChange?("鼠标连接恢复失败，等待设备事件：\(message)")
        }
    }
}
