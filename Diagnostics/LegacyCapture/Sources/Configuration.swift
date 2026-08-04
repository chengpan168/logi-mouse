import Foundation

enum CaptureProfile: String, CaseIterable, Equatable, Sendable {
    case runtime
    case diagnostic

    var displayName: String {
        switch self {
        case .runtime: "Runtime (low overhead)"
        case .diagnostic: "Diagnostic (full capture)"
        }
    }

    func records(layer: String) -> Bool {
        guard self == .runtime else { return true }
        switch layer {
        case "hid", "hid_report", "cg_event", "cg_event_suppressed", "ns_event", "model_output", "view":
            return false
        default:
            return true
        }
    }
}

struct Configuration: Equatable {
    var scenario: String = "options-on-observation"
    var output: URL?
    var duration: TimeInterval?
    var analyze: URL?
    var scrollDirection: ScrollDirectionMapping = .natural
    var captureProfile: CaptureProfile = .runtime

    static func parse(_ arguments: ArraySlice<String>) throws -> Configuration {
        var configuration = Configuration()
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--scenario":
                guard let value = iterator.next(), !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ConfigurationError.invalidValue("--scenario requires a non-empty value")
                }
                configuration.scenario = value
            case "--output":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw ConfigurationError.invalidValue("--output requires a path")
                }
                configuration.output = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
            case "--duration":
                guard let value = iterator.next(), let seconds = TimeInterval(value), seconds > 0 else {
                    throw ConfigurationError.invalidValue("--duration must be greater than zero")
                }
                configuration.duration = seconds
            case "--analyze":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw ConfigurationError.invalidValue("--analyze requires a JSONL path")
                }
                configuration.analyze = URL(
                    fileURLWithPath: value,
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
            case "--natural-scroll":
                configuration.scrollDirection = .natural
            case "--traditional-scroll":
                configuration.scrollDirection = .traditional
            case "--diagnostic-capture":
                configuration.captureProfile = .diagnostic
            case "--runtime-capture":
                configuration.captureProfile = .runtime
            case "-h", "--help":
                throw ConfigurationError.helpRequested
            default:
                throw ConfigurationError.invalidValue("unknown argument: \(argument)")
            }
        }
        return configuration
    }

    func resolvedOutput(now: Date = Date(), workingDirectory: URL? = nil) -> URL {
        if let output { return output }
        let directory = workingDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logi-mouse", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeScenario = scenario.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        return directory
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: now))-\(String(safeScenario)).jsonl")
    }
}

enum ConfigurationError: LocalizedError, Equatable {
    case helpRequested
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested: return nil
        case let .invalidValue(message): return message
        }
    }
}

let commandHelp = """
logi-mouse

USAGE:
  logi-mouse [--scenario NAME] [--output FILE] [--duration SECONDS]
                     [--runtime-capture|--diagnostic-capture]
  logi-mouse --analyze CAPTURE.jsonl [--natural-scroll|--traditional-scroll]

The app opens a controlled scroll view. Runtime capture keeps only lifecycle
and HID++ control diagnostics; --diagnostic-capture records raw HID, CGEvent,
NSEvent, model-output and view-offset samples on one monotonic timeline.

Analysis mode replays decoded HID++ events through the continuous scroll model
and compares its predicted pixel output with the captured CGEvents.
"""
