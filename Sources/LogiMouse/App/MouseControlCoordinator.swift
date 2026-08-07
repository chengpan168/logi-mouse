import Foundation

/// Runtime composition root for smooth scrolling.
///
/// This coordinator contains no capture, file logging or test-surface logic.
/// It owns only the production path:
/// HID++ wheel event → independent axis model → marked global CGEvent.
///
/// Safety gates are intentionally separate:
/// - `isLiveModelEnabled`: the mathematical model and CGEvent tap are ready.
/// - `isTakeoverEnabled`: the user still wants hardware diversion, including
///   across a temporary disconnect.
/// - `isGlobalOutputEnabled`: synthesized events may be posted globally.
/// - `takeoverAxes`: firmware mode was actually written and read back for each
///   sensor. Native events are suppressed only when all relevant gates agree.
final class MouseControlCoordinator {
    private(set) var isRunning = false
    private(set) var isLiveModelEnabled = false
    private(set) var isTakeoverEnabled = false
    private(set) var isGlobalOutputEnabled = false

    var onStatusChange: ((String) -> Void)?
    var onControllerStateChange: ((HIDPPController.State) -> Void)?
    var onBatteryStateChange: ((HIDPPBatteryState) -> Void)?

    private var hidMonitor: HIDMonitor?
    private var eventMonitor: CGEventMonitor?
    private var verticalModel = ScrollDynamicsModel()
    private var horizontalModel = ScrollDynamicsModel()
    private var takeoverAxes = HIDPPTakeoverAxes.none
    /// Prevents the session-wide event tap from suppressing a trackpad or a
    /// second mouse merely because the target Logitech mouse is diverted.
    private let targetScrollCorrelation = TargetScrollCorrelation()

    func start() throws {
        stop()
        let hidMonitor = HIDMonitor()
        let eventMonitor = CGEventMonitor()

        hidMonitor.onWheelEvent = { [weak self] event, timestamp in
            self?.processVertical(event, timestampNs: timestamp)
        }
        hidMonitor.onThumbwheelEvent = { [weak self] event, timestamp in
            self?.processHorizontal(event, timestampNs: timestamp)
        }
        hidMonitor.onControllerStateChange = { [weak self] state in
            guard let self else { return }
            self.onControllerStateChange?(state)
            guard self.isTakeoverEnabled else { return }
            switch state {
            case .unavailable:
                self.onStatusChange?("鼠标 HID++ 通道已断开，等待重新连接…")
            case let .channelReady(transport):
                self.onStatusChange?("正在通过 \(transport) 恢复滚轮接管…")
            case .discovering:
                self.onStatusChange?("正在重新发现鼠标滚轮能力…")
            case .ready:
                self.onStatusChange?("平滑滚动已开启")
            case let .failed(message):
                self.onStatusChange?("鼠标连接恢复失败，等待设备事件：\(message)")
            }
        }
        hidMonitor.onTakeoverAxesChange = { [weak self] axes in
            guard let self else { return }
            self.takeoverAxes = axes
            // Invalidate model history as soon as firmware verification is
            // lost. Reusing pre-disconnect activity would create a speed jump.
            if !axes.vertical {
                self.verticalModel.reset()
                self.targetScrollCorrelation.reset(.vertical)
            }
            if !axes.horizontal {
                self.horizontalModel.reset()
                self.targetScrollCorrelation.reset(.horizontal)
            }
        }
        hidMonitor.onBatteryStateChange = { [weak self] state in
            self?.onBatteryStateChange?(state)
        }
        eventMonitor.shouldSuppressVerticalScroll = { [weak self] in
            guard let self else { return false }
            // Both conditions are required: verified takeover establishes
            // ownership, while correlation ties this otherwise anonymous
            // CGEvent to a recent HID++ notification from the target axis.
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
        do {
            try hidMonitor.start()
            try eventMonitor.start()
        } catch {
            hidMonitor.stop()
            eventMonitor.stop()
            throw error
        }

        self.hidMonitor = hidMonitor
        self.eventMonitor = eventMonitor
        isRunning = true
        resetModels()
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
            resetModels()
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
        if enabled {
            guard isLiveModelEnabled else {
                completion(.failure(MouseControlRequirementError.liveModelRequired))
                return
            }
            onStatusChange?("正在接管鼠标滚轮…")
            hidMonitor.takeOverWheel { [weak self] result in
                if case .success = result { self?.isTakeoverEnabled = true }
                completion(result)
            }
        } else {
            onStatusChange?("正在恢复系统原生滚动…")
            hidMonitor.restoreWheel { [weak self] result in
                if case .success = result { self?.isTakeoverEnabled = false }
                completion(result)
            }
        }
    }

    func setDirection(_ direction: ScrollDirectionMapping) {
        verticalModel.setDirectionMapping(direction)
        horizontalModel.setDirectionMapping(direction)
    }

    /// Performs one explicit hardware read-back when the control window opens.
    /// Normal scroll traffic never enters this path.
    func verifyTakeoverMode() {
        guard isRunning, isTakeoverEnabled else { return }
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
        resetModels()
    }

    func stop() {
        eventMonitor?.stop()
        hidMonitor?.stop()
        eventMonitor = nil
        hidMonitor = nil
        isRunning = false
        isLiveModelEnabled = false
        isTakeoverEnabled = false
        isGlobalOutputEnabled = false
        takeoverAxes = .none
        targetScrollCorrelation.reset()
        resetModels()
    }

    private func processVertical(_ event: HIDPPWheelEvent, timestampNs: UInt64) {
        guard outputIsActive(.vertical) else {
            verticalModel.reset()
            return
        }
        // flags[0...3] is the number of device sampling periods represented by
        // this report. Reserve the same number of native events for suppression
        // before injecting the model's expanded output.
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

        // 0x2150 rotation has the opposite sign from the horizontal CGEvent
        // observed under macOS natural scrolling. Normalize the hardware sign
        // before applying the same user direction mapping as the vertical axis.
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
        // Firmware read-back is the final authority. User intent alone cannot
        // justify suppressing native events: a failed SetMode would otherwise
        // make the physical wheel appear broken.
        guard isLiveModelEnabled, isTakeoverEnabled, isGlobalOutputEnabled else {
            return false
        }
        return switch axis {
        case .vertical: takeoverAxes.vertical
        case .horizontal: takeoverAxes.horizontal
        }
    }

    private func resetModels() {
        verticalModel.reset()
        horizontalModel.reset()
    }
}

enum MouseControlRequirementError: LocalizedError {
    case liveModelRequired

    var errorDescription: String? {
        "必须先启用平滑滚动模型，才能接管鼠标滚轮。"
    }
}
