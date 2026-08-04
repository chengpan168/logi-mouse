import Foundation

final class JSONLLogger {
    let outputURL: URL
    let scenario: String
    let startTimestampNs: UInt64

    private static let flushThreshold = 64 * 1024
    private static let runtimeSizeLimit = 10 * 1024 * 1024

    private let queue = DispatchQueue(label: "dev.logi-mouse.logger", qos: .utility)
    private let recordLock = NSLock()
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let profile: CaptureProfile
    private var sequence: UInt64 = 0
    private var buffer = Data()
    private var bytesWritten = 0
    private var bytesAccepted = 0
    private var acceptingWrites = true
    private var flushScheduled = false
    private var flushTimer: DispatchSourceTimer?

    init(outputURL: URL, scenario: String, profile: CaptureProfile) throws {
        self.outputURL = outputURL
        self.scenario = scenario
        self.startTimestampNs = MonotonicClock.nowNanoseconds()
        self.profile = profile
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = try FileHandle(forWritingTo: outputURL)
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.flushBuffer()
        }
        self.flushTimer = timer
        timer.resume()
    }

    deinit {
        close()
    }

    func records(layer: String) -> Bool {
        profile.records(layer: layer)
    }

    func write(layer: String, timestampNs: UInt64, fill: (inout EventRecord) -> Void) {
        guard records(layer: layer) else { return }
        recordLock.lock()
        guard acceptingWrites else {
            recordLock.unlock()
            return
        }
        sequence += 1
        var record = EventRecord(
            sequence: sequence,
            scenario: scenario,
            layer: layer,
            eventTimestampNs: timestampNs,
            startTimestampNs: startTimestampNs
        )
        fill(&record)
        var encoded = try? encoder.encode(record)
        encoded?.append(0x0A)
        guard let encoded else {
            recordLock.unlock()
            return
        }
        if profile == .runtime, bytesAccepted + encoded.count > Self.runtimeSizeLimit {
            recordLock.unlock()
            return
        }
        bytesAccepted += encoded.count
        buffer.append(encoded)
        let shouldScheduleFlush = buffer.count >= Self.flushThreshold && !flushScheduled
        if shouldScheduleFlush {
            flushScheduled = true
        }
        recordLock.unlock()

        if shouldScheduleFlush {
            queue.async { [weak self] in
                self?.flushBuffer()
            }
        }
    }

    func synchronize() {
        queue.sync {
            flushBuffer()
            try? handle.synchronize()
        }
    }

    func close() {
        recordLock.lock()
        guard acceptingWrites else {
            recordLock.unlock()
            return
        }
        acceptingWrites = false
        recordLock.unlock()
        queue.sync {
            flushTimer?.cancel()
            flushTimer = nil
            flushBuffer()
            try? handle.synchronize()
            try? handle.close()
        }
    }

    private func flushBuffer() {
        recordLock.lock()
        flushScheduled = false
        guard !buffer.isEmpty else {
            recordLock.unlock()
            return
        }
        let pending = buffer
        buffer.removeAll(keepingCapacity: true)
        recordLock.unlock()
        do {
            try handle.write(contentsOf: pending)
            bytesWritten += pending.count
        } catch {
            fputs("warning: failed to write capture: \(error)\n", stderr)
        }
    }
}
