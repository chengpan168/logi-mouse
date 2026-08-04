import Foundation

/// Runtime composition root for smooth scrolling.
///
/// This coordinator contains no capture, file logging or test-surface logic.
/// It owns only the production path:
/// HID++ wheel event → independent axis model → marked global CGEvent.
final class MouseControlCoordinator {
    private(set) var isRunning = false
    private(set) var isLiveModelEnabled = false
    private(set) var isTakeoverEnabled = false
    private(set) var isGlobalOutputEnabled = false

    var onStatusChange: ((String) -> Void)?
    var onControllerStateChange: ((HIDPPController.State) -> Void)?

    private var hidMonitor: HIDMonitor?
    private var eventMonitor: CGEventMonitor?
    private var verticalModel = ScrollDynamicsModel()
    private var horizontalModel = ScrollDynamicsModel()

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
                self.onStatusChange?("鼠标连接恢复重试中：\(message)")
            }
        }
        let shouldSuppress: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.isLiveModelEnabled
                && self.isTakeoverEnabled
                && self.isGlobalOutputEnabled
        }
        eventMonitor.shouldSuppressVerticalScroll = shouldSuppress
        eventMonitor.shouldSuppressHorizontalScroll = shouldSuppress
        eventMonitor.onExternalScrollEvent = { [weak self] in
            guard let self, self.isTakeoverEnabled else { return }
            self.hidMonitor?.verifyWheelModeSoon()
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
        resetModels()
    }

    private func processVertical(_ event: HIDPPWheelEvent, timestampNs: UInt64) {
        guard outputIsActive else {
            verticalModel.reset()
            return
        }
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
        guard outputIsActive else {
            horizontalModel.reset()
            return
        }
        guard event.rotation != 0 else { return }

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

    private var outputIsActive: Bool {
        isLiveModelEnabled && isTakeoverEnabled && isGlobalOutputEnabled
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
