import Foundation
import Testing
@testable import LogiMouse

@Test func parsesArguments() throws {
    let configuration = try Configuration.parse([
        "--scenario", "options-on-fast-stop",
        "--duration", "12.5",
        "--diagnostic-capture",
        "--output", "/tmp/capture.jsonl"
    ][...])

    #expect(configuration.scenario == "options-on-fast-stop")
    #expect(configuration.duration == 12.5)
    #expect(configuration.output?.path == "/tmp/capture.jsonl")
    #expect(configuration.captureProfile == .diagnostic)
}

@Test func runtimeCaptureFiltersHighFrequencyLayers() {
    #expect(!CaptureProfile.runtime.records(layer: "hid_report"))
    #expect(!CaptureProfile.runtime.records(layer: "cg_event_suppressed"))
    #expect(!CaptureProfile.runtime.records(layer: "model_output"))
    #expect(!CaptureProfile.runtime.records(layer: "view"))
    #expect(CaptureProfile.runtime.records(layer: "capture_start"))
    #expect(CaptureProfile.runtime.records(layer: "hidpp_mode_drift_detected"))
    #expect(CaptureProfile.diagnostic.records(layer: "hid_report"))
}

@Test func loggerFlushesBufferedRuntimeRecordsAndFiltersDetail() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("logi-mouse-tests-\(UUID().uuidString)", isDirectory: true)
    let output = directory.appendingPathComponent("runtime.jsonl")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = try JSONLLogger(outputURL: output, scenario: "runtime-test", profile: .runtime)
    logger.write(layer: "capture_start", timestampNs: logger.startTimestampNs) { _ in }
    logger.write(layer: "hid_report", timestampNs: logger.startTimestampNs + 1) { record in
        record.reportHex = "deadbeef"
    }
    logger.close()

    let contents = try String(contentsOf: output, encoding: .utf8)
    #expect(contents.contains("\"layer\":\"capture_start\""))
    #expect(!contents.contains("hid_report"))
    #expect(!contents.contains("deadbeef"))
}

@Test func scrollAxisClassifierPassesHorizontalAndSuppressesVertical() {
    #expect(CGScrollAxisClassifier.isPrimarilyVertical(
        pointX: 8, pointY: 0, fixedX: 0, fixedY: 0, lineX: 0, lineY: 0
    ) == false)
    #expect(CGScrollAxisClassifier.isPrimarilyVertical(
        pointX: 0, pointY: -8, fixedX: 0, fixedY: 0, lineX: 0, lineY: 0
    ))
    #expect(CGScrollAxisClassifier.isPrimarilyVertical(
        pointX: 9, pointY: 2, fixedX: 0, fixedY: 0, lineX: 0, lineY: 0
    ) == false)
    #expect(CGScrollAxisClassifier.isPrimarilyVertical(
        pointX: 0, pointY: 0, fixedX: 0, fixedY: 0, lineX: 1, lineY: 0
    ) == false)
}

@Test func rejectsInvalidDuration() {
    #expect(throws: ConfigurationError.invalidValue("--duration must be greater than zero")) {
        try Configuration.parse(["--duration", "0"][...])
    }
}

@Test func parsesAnalysisAndDirectionArguments() throws {
    let configuration = try Configuration.parse([
        "--analyze", "/tmp/capture.jsonl",
        "--traditional-scroll"
    ][...])

    #expect(configuration.analyze?.path == "/tmp/capture.jsonl")
    #expect(configuration.scrollDirection == .traditional)
}

@Test func createsSafeDefaultFilename() {
    let configuration = Configuration(scenario: "free spin / down")
    let output = configuration.resolvedOutput(
        now: Date(timeIntervalSince1970: 0),
        workingDirectory: URL(fileURLWithPath: "/tmp/logi-mouse")
    )

    #expect(output.path == "/tmp/logi-mouse/captures/19700101-000000-free-spin---down.jsonl")
}
