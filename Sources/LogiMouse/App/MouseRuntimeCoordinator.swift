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
    private(set) var runtimeState = MouseRuntimeState()
    private(set) var isLiveModelEnabled = false
    private(set) var isGlobalOutputEnabled = false

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

    private var verticalModel = ScrollDynamicsModel()
    private var horizontalModel = ScrollDynamicsModel()
    /// Prevents the session-wide event tap from suppressing a trackpad or a
    /// second mouse merely because the target Logitech mouse is diverted.
    private let targetScrollCorrelation = TargetScrollCorrelation()

    init() {
        systemLifecycleMonitor.onWillSleep = { [weak self] in
            self?.handleLifecycleEvent(.systemWillSleep)
        }
        systemLifecycleMonitor.onDidWake = { [weak self] in
            self?.handleLifecycleEvent(.systemDidWake)
        }
    }

    /// Starts the control-plane power observer and the first data-plane
    /// generation. Startup remains throwing so permission errors can be shown
    /// synchronously by the existing settings window.
    func start() throws {
        systemLifecycleMonitor.start()
        try send(.startRequested)
        onStatusChange?("已就绪")
    }

    func setLiveModelEnabled(_ enabled: Bool, direction: ScrollDirectionMapping) throws {
        guard isRunning, let eventMonitor else { return }
        if enabled {
            verticalModel = ScrollDynamicsModel(directionMapping: direction)
            horizontalModel = ScrollDynamicsModel(directionMapping: direction)
            try eventMonitor.setSuppressionEnabled(true)
            isLiveModelEnabled = true
        } else {
            isLiveModelEnabled = false
            isGlobalOutputEnabled = false
            resetModelsAndCorrelation()
            try eventMonitor.setSuppressionEnabled(false)
        }
    }

    func setTakeoverEnabled(
        _ enabled: Bool,
        completion: @escaping (Result<HIDPPController.State, Error>) -> Void
    ) {
        guard isRunning, let hidMonitor else {
            completion(.failure(HIDPPControllerError.noHIDPPChannel))
            return
        }

        let generation = runtimeState.generation
        if enabled {
            guard isLiveModelEnabled else {
                completion(.failure(MouseControlRequirementError.liveModelRequired))
                return
            }
            try? send(.takeoverIntentChanged(true))
            try? send(.takeoverStarted(generation: generation))
            onStatusChange?("正在接管鼠标滚轮…")
            hidMonitor.takeOverWheel { [weak self] result in
                // The request may finish after sleep or a monitor rebuild.
                // Its hardware result and UI completion both belong to the old
                // generation and must not overwrite durable wake state.
                guard let self,
                      self.runtimeState.generation == generation else { return }
                switch result {
                case .success:
                    try? self.send(.takeoverSucceeded(generation: generation))
                case let .failure(error):
                    // A direct user action is transactional: failure returns the
                    // switch to OFF. Sleep recovery uses a separate effect that
                    // deliberately preserves intent across bounded failures.
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
                if case .failure = result {
                    // The settings window restores its ON state on failure; keep
                    // the coordinator's durable intent consistent with that UI.
                    try? self.send(.takeoverIntentChanged(true))
                }
                completion(result)
            }
        }
    }

    func setDirection(_ direction: ScrollDirectionMapping) {
        verticalModel.setDirectionMapping(direction)
        horizontalModel.setDirectionMapping(direction)
    }

    /// Performs a low-frequency read-back when the control window opens.
    /// Ordinary scroll reports remain pure data events and never enter this path.
    func verifyTakeoverMode() {
        guard isRunning, isTakeoverEnabled else { return }
        try? send(.verificationStarted(generation: runtimeState.generation))
        hidMonitor?.verifyWheelMode()
    }

    func refreshBattery() {
        guard isRunning else { return }
        hidMonitor?.refreshBattery()
    }

    func setGlobalOutputEnabled(_ enabled: Bool) {
        guard isRunning, isLiveModelEnabled else {
            isGlobalOutputEnabled = false
            return
        }
        isGlobalOutputEnabled = enabled
        resetModelsAndCorrelation()
    }

    /// Stops permanently and restores hardware when possible. System sleep must
    /// use the reducer's suspend effect instead; conflating the two paths caused
    /// synchronous HID timeouts while the machine was going to sleep.
    func stop() {
        try? send(.stopRequested)
        systemLifecycleMonitor.stop()
        isLiveModelEnabled = false
        isGlobalOutputEnabled = false
        resetModelsAndCorrelation()
    }

    // MARK: - State machine

    private func handleLifecycleEvent(_ event: MouseRuntimeEvent) {
        do {
            try send(event)
        } catch {
            onStatusChange?(error.localizedDescription)
        }
    }

    /// Reduces one event, publishes the new aggregate state, then executes the
    /// returned effects in order. Effects report completion by sending another
    /// event; no effect mutates `runtimeState` directly.
    private func send(_ event: MouseRuntimeEvent) throws {
        let previous = runtimeState
        let effects = reducer.reduce(state: &runtimeState, event: event)
        if runtimeState != previous {
            onRuntimeStateChange?(runtimeState)
        }
        for effect in effects {
            try execute(effect)
        }
    }

    private func execute(_ effect: MouseRuntimeEffect) throws {
        switch effect {
        case let .startMonitoring(generation):
            do {
                try startRuntimeMonitors(generation: generation)
                try send(.monitoringStarted(generation: generation))
            } catch {
                try? send(.monitoringStartFailed(
                    message: error.localizedDescription,
                    generation: generation
                ))
                throw error
            }

        case let .suspendMonitoring(generation):
            cancelScheduledWork()
            stopRuntimeMonitors(restoringHardware: false)
            resetModelsAndCorrelation()
            try send(.monitoringSuspended(generation: generation))
            onStatusChange?("系统已睡眠，鼠标监听已安全挂起")

        case let .scheduleWakeStart(attempt, generation, delay):
            wakeRetryWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                try? self.send(.wakeRetryTimerFired(
                    attempt: attempt,
                    generation: generation
                ))
            }
            wakeRetryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            onStatusChange?("系统已唤醒，等待 HID 服务恢复…")

        case let .recoverTakeover(attempt, generation):
            recoverTakeover(attempt: attempt, generation: generation)

        case let .scheduleTakeoverRecovery(attempt, generation, delay):
            takeoverRetryWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self,
                      self.runtimeState.generation == generation,
                      self.runtimeState.takeoverRequested,
                      self.runtimeState.isRunning else { return }
                self.recoverTakeover(attempt: attempt, generation: generation)
            }
            takeoverRetryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)

        case let .stopMonitoring(generation):
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
        connectionMonitor.start()
        do {
            try hidMonitor.start()
            try eventMonitor.start(suppressionEnabled: isLiveModelEnabled)
        } catch {
            stopRuntimeMonitors(restoringHardware: false)
            throw error
        }
    }

    private func stopRuntimeMonitors(restoringHardware: Bool) {
        eventMonitor?.stop()
        connectionMonitor?.stop()
        if restoringHardware {
            hidMonitor?.stop()
        } else {
            hidMonitor?.suspend()
        }
        eventMonitor = nil
        connectionMonitor = nil
        hidMonitor = nil
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
        hidMonitor.onWheelEvent = { [weak self] event, timestamp in
            guard let self,
                  self.runtimeState.generation == generation else { return }
            self.processVertical(event, timestampNs: timestamp)
        }
        hidMonitor.onThumbwheelEvent = { [weak self] event, timestamp in
            guard let self,
                  self.runtimeState.generation == generation else { return }
            self.processHorizontal(event, timestampNs: timestamp)
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
            try? self.send(.takeoverAxesChanged(axes, generation: generation))
            // HIDPPController can recover from a later Bluetooth match or
            // Receiver link-up event before our bounded timer fires. Both axes
            // being read-back verified is authoritative success, so cancel the
            // now-obsolete timer and avoid a duplicate takeover transaction.
            if axes.isComplete {
                self.takeoverRetryWorkItem?.cancel()
                self.takeoverRetryWorkItem = nil
            }
            self.invalidateModels(forLostAxes: axes)
        }
        hidMonitor.onBatteryStateChange = { [weak self] batteryState in
            guard let self,
                  self.runtimeState.generation == generation else { return }
            self.onBatteryStateChange?(batteryState)
        }
        eventMonitor.shouldSuppressVerticalScroll = { [weak self] in
            guard let self else { return false }
            return self.outputIsActive(.vertical)
                && self.targetScrollCorrelation.consumeMatch(
                    .vertical,
                    timestampNs: MonotonicClock.nowNanoseconds()
                )
        }
        eventMonitor.shouldSuppressHorizontalScroll = { [weak self] in
            guard let self else { return false }
            return self.outputIsActive(.horizontal)
                && self.targetScrollCorrelation.consumeMatch(
                    .horizontal,
                    timestampNs: MonotonicClock.nowNanoseconds()
                )
        }
    }

    private func recoverTakeover(attempt: Int, generation: UInt64) {
        guard runtimeState.generation == generation,
              runtimeState.takeoverRequested,
              runtimeState.isRunning,
              let hidMonitor else { return }
        try? send(.takeoverStarted(generation: generation))
        onStatusChange?("正在恢复鼠标接管（第 \(attempt) 次）…")
        hidMonitor.takeOverWheel(preserveRequestOnFailure: true) { [weak self] result in
            guard let self,
                  self.runtimeState.generation == generation,
                  self.runtimeState.isRunning else { return }
            switch result {
            case .success:
                try? self.send(.takeoverSucceeded(generation: generation))
                self.onStatusChange?("平滑滚动已恢复")
            case let .failure(error):
                try? self.send(.takeoverFailed(
                    message: error.localizedDescription,
                    recoveryAttempt: attempt,
                    generation: generation
                ))
                if attempt >= MouseRuntimeReducer.recoveryDelays.count {
                    self.onStatusChange?("恢复失败，等待下一次设备连接事件：\(error.localizedDescription)")
                }
            }
        }
    }

    private func cancelScheduledWork() {
        wakeRetryWorkItem?.cancel()
        takeoverRetryWorkItem?.cancel()
        wakeRetryWorkItem = nil
        takeoverRetryWorkItem = nil
    }

    // MARK: - Data path

    private func processVertical(_ event: HIDPPWheelEvent, timestampNs: UInt64) {
        guard outputIsActive(.vertical) else {
            verticalModel.reset()
            return
        }
        targetScrollCorrelation.record(
            .vertical,
            timestampNs: timestampNs,
            eventCount: max(1, Int(event.flags & 0x0f))
        )
        let output = verticalModel.process(
            delta: event.delta,
            flags: event.flags,
            timestampNs: timestampNs
        )
        for pixels in output.pixelDeltas {
            CGScrollInjector.post(pixelDelta: pixels)
        }
    }

    private func processHorizontal(_ event: HIDPPThumbwheelEvent, timestampNs: UInt64) {
        guard outputIsActive(.horizontal) else {
            horizontalModel.reset()
            return
        }
        guard event.rotation != 0 else { return }
        targetScrollCorrelation.record(.horizontal, timestampNs: timestampNs)
        let output = horizontalModel.process(
            delta: -event.rotation,
            flags: 0x11,
            timestampNs: timestampNs
        )
        for pixels in output.pixelDeltas {
            CGScrollInjector.postHorizontal(pixelDelta: pixels)
        }
    }

    private func outputIsActive(_ axis: ScrollAxis) -> Bool {
        isLiveModelEnabled
            && isGlobalOutputEnabled
            && runtimeState.outputIsVerified(for: axis)
    }

    private func invalidateModels(forLostAxes axes: HIDPPTakeoverAxes) {
        if !axes.vertical {
            verticalModel.reset()
            targetScrollCorrelation.reset(.vertical)
        }
        if !axes.horizontal {
            horizontalModel.reset()
            targetScrollCorrelation.reset(.horizontal)
        }
    }

    private func resetModelsAndCorrelation() {
        verticalModel.reset()
        horizontalModel.reset()
        targetScrollCorrelation.reset()
    }

    private func publishStatus(for state: HIDPPController.State) {
        guard runtimeState.takeoverRequested else { return }
        switch state {
        case .unavailable:
            onStatusChange?("鼠标 HID++ 通道已断开，等待重新连接…")
        case let .channelReady(transport):
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

enum MouseControlRequirementError: LocalizedError {
    case liveModelRequired

    var errorDescription: String? {
        "必须先启用平滑滚动模型，才能接管鼠标滚轮。"
    }
}
