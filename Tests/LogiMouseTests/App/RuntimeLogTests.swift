import Foundation
import Testing
@testable import LogiMouse

@Test func runtimeLogTimestampUsesRequestedLocalOffset() throws {
    let shanghai = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))

    #expect(
        RuntimeLog.timestamp(for: Date(timeIntervalSince1970: 0), timeZone: shanghai)
            == "1970-01-01T08:00:00.000+08:00"
    )
}
