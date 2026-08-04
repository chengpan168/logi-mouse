import Foundation
import Testing
@testable import LogiMouse

@Test func analyzesSyntheticCaptureWithNaturalDirection() throws {
    let parameters = ScrollDynamicsParameters(
        decayTimeConstant: 0.030,
        minimumGain: 1,
        maximumGain: 1,
        activityMidpoint: 3,
        steepness: 8
    )
    let jsonl = """
    {"scenario":"synthetic","layer":"hid_report","event_timestamp_ns":1000000,"hidpp_wheel_flags":18,"hidpp_wheel_delta":-2}
    {"scenario":"synthetic","layer":"cg_event","event_timestamp_ns":1100000,"point_delta_y":-2}
    {"scenario":"synthetic","layer":"cg_event","event_timestamp_ns":1200000,"point_delta_y":-2}
    {"scenario":"synthetic","layer":"hid_report","event_timestamp_ns":1000000000,"hidpp_wheel_flags":17,"hidpp_wheel_delta":-2}
    {"scenario":"synthetic","layer":"cg_event","event_timestamp_ns":1000100000,"point_delta_y":-2}
    """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scroll-analysis-\(UUID().uuidString).jsonl")
    try Data(jsonl.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let analysis = try ScrollCaptureAnalyzer.analyze(
        fileURL: url,
        parameters: parameters,
        directionMapping: .natural
    )

    #expect(analysis.hidEventCount == 2)
    #expect(analysis.cgEventCount == 3)
    #expect(analysis.observedAbsolutePixels == 6)
    #expect(analysis.predictedAbsolutePixels == 6)
}
