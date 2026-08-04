import Foundation

struct ScrollCaptureAnalysis: Equatable, Sendable, CustomStringConvertible {
    let scenario: String
    let directionMapping: ScrollDirectionMapping
    let hidEventCount: Int
    let cgEventCount: Int
    let multiPeriodHIDEventCount: Int
    let observedAbsolutePixels: Int
    let predictedAbsolutePixels: Int
    let totalDistanceErrorPercent: Double
    let meanAbsolutePixelError: Double
    let movementWeightedGainError: Double
    let observedSignAgreement: Double

    var description: String {
        """
        scenario: \(scenario)
        direction: \(directionMapping.rawValue)
        HID++ events: \(hidEventCount)
        CGEvents: \(cgEventCount)
        multi-period HID++ events: \(multiPeriodHIDEventCount)
        observed absolute pixels: \(observedAbsolutePixels)
        predicted absolute pixels: \(predictedAbsolutePixels)
        total distance error: \(Self.format(totalDistanceErrorPercent))%
        mean absolute pixels/event: \(Self.format(meanAbsolutePixelError))
        movement-weighted gain error: \(Self.format(movementWeightedGainError))
        observed HID/CG sign agreement: \(Self.format(observedSignAgreement * 100))%
        """
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

enum ScrollCaptureAnalyzerError: LocalizedError {
    case noWheelEvents

    var errorDescription: String? {
        switch self {
        case .noWheelEvents: "capture contains no decoded HID++ wheel events"
        }
    }
}

enum ScrollCaptureAnalyzer {
    private struct Record: Decodable {
        let scenario: String
        let layer: String
        let eventTimestampNs: UInt64
        let hidppWheelFlags: UInt8?
        let hidppWheelDelta: Int?
        let pointDeltaY: Double?

        enum CodingKeys: String, CodingKey {
            case scenario, layer
            case eventTimestampNs = "event_timestamp_ns"
            case hidppWheelFlags = "hidpp_wheel_flags"
            case hidppWheelDelta = "hidpp_wheel_delta"
            case pointDeltaY = "point_delta_y"
        }
    }

    private struct PendingEvent {
        let delta: Int
        let periods: Int
        let prediction: ScrollDynamicsOutput
        var observedPixels = 0
    }

    static func analyze(
        fileURL: URL,
        parameters: ScrollDynamicsParameters = .optionsCaptureInitial,
        directionMapping: ScrollDirectionMapping = .natural
    ) throws -> ScrollCaptureAnalysis {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        var records: [Record] = []
        records.reserveCapacity(max(1, data.count / 250))
        for line in data.split(separator: 0x0a) where !line.isEmpty {
            records.append(try decoder.decode(Record.self, from: Data(line)))
        }

        var model = ScrollDynamicsModel(parameters: parameters, directionMapping: directionMapping)
        var pending: PendingEvent?
        var scenario = records.first?.scenario ?? fileURL.deletingPathExtension().lastPathComponent
        var hidEventCount = 0
        var cgEventCount = 0
        var multiPeriodCount = 0
        var observedAbsolutePixels = 0
        var predictedAbsolutePixels = 0
        var absolutePixelError = 0
        var weightedGainError = 0.0
        var inputMovement = 0
        var signMatches = 0
        var signComparisons = 0

        func consume(_ event: PendingEvent) {
            let predicted = event.prediction.totalPixels
            let observed = event.observedPixels
            let movement = abs(event.delta) * event.periods
            observedAbsolutePixels += abs(observed)
            predictedAbsolutePixels += abs(predicted)
            absolutePixelError += abs(predicted - observed)
            inputMovement += movement
            if movement > 0 {
                let observedGain = Double(abs(observed)) / Double(movement)
                let predictedGain = Double(abs(predicted)) / Double(movement)
                weightedGainError += Double(movement) * abs(predictedGain - observedGain)
            }
            if observed != 0, event.delta != 0 {
                signComparisons += 1
                if observed.signum() == event.delta.signum() {
                    signMatches += 1
                }
            }
        }

        for record in records {
            scenario = record.scenario
            if record.layer == "hid_report", let delta = record.hidppWheelDelta {
                if let pending { consume(pending) }
                let flags = record.hidppWheelFlags ?? 1
                let prediction = model.process(
                    delta: delta,
                    flags: flags,
                    timestampNs: record.eventTimestampNs
                )
                let periods = max(1, Int(flags & 0x0f))
                pending = PendingEvent(delta: delta, periods: periods, prediction: prediction)
                hidEventCount += 1
                if periods > 1 { multiPeriodCount += 1 }
            } else if record.layer == "cg_event", let delta = record.pointDeltaY, delta != 0, pending != nil {
                pending?.observedPixels += Int(delta.rounded())
                cgEventCount += 1
            }
        }
        if let pending { consume(pending) }
        guard hidEventCount > 0 else { throw ScrollCaptureAnalyzerError.noWheelEvents }

        return ScrollCaptureAnalysis(
            scenario: scenario,
            directionMapping: directionMapping,
            hidEventCount: hidEventCount,
            cgEventCount: cgEventCount,
            multiPeriodHIDEventCount: multiPeriodCount,
            observedAbsolutePixels: observedAbsolutePixels,
            predictedAbsolutePixels: predictedAbsolutePixels,
            totalDistanceErrorPercent: observedAbsolutePixels == 0
                ? 0
                : Double(abs(predictedAbsolutePixels - observedAbsolutePixels))
                    / Double(observedAbsolutePixels) * 100,
            meanAbsolutePixelError: Double(absolutePixelError) / Double(hidEventCount),
            movementWeightedGainError: inputMovement == 0 ? 0 : weightedGainError / Double(inputMovement),
            observedSignAgreement: signComparisons == 0 ? 0 : Double(signMatches) / Double(signComparisons)
        )
    }
}
