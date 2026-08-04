import Foundation

struct EventRecord: Codable {
    let schemaVersion: Int
    let sequence: UInt64
    let scenario: String
    let layer: String
    let eventTimestampNs: UInt64
    let elapsedNs: UInt64

    var deviceID: UInt64?
    var deviceProduct: String?
    var transport: String?
    var vendorID: Int?
    var productID: Int?
    var primaryUsagePage: Int?
    var primaryUsage: Int?
    var usagePage: UInt32?
    var usage: UInt32?
    var reportID: UInt32?
    var hidValue: Int?
    var hidLogicalMin: Int?
    var hidLogicalMax: Int?
    var reportType: Int?
    var reportLength: Int?
    var reportHex: String?
    var hidppDeviceIndex: UInt8?
    var hidppFeatureIndex: UInt8?
    var hidppEventID: UInt8?
    var hidppWheelFlags: UInt8?
    var hidppWheelDelta: Int?
    var hidppThumbwheelRotation: Int?
    var hidppThumbwheelStatus: UInt8?

    var lineDeltaY: Double?
    var lineDeltaX: Double?
    var fixedDeltaY: Double?
    var fixedDeltaX: Double?
    var pointDeltaY: Double?
    var pointDeltaX: Double?
    var rawDeltaY: Double?
    var rawDeltaX: Double?
    var acceleratedDeltaY: Double?
    var acceleratedDeltaX: Double?
    var isContinuous: Bool?
    var scrollPhase: Int64?
    var momentumPhase: Int64?
    var scrollCount: Int64?
    var sourcePID: Int64?

    var viewOffsetY: Double?
    var viewOffsetX: Double?
    var viewDocumentHeight: Double?
    var viewViewportHeight: Double?
    var viewRemainingY: Double?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sequence, scenario, layer
        case eventTimestampNs = "event_timestamp_ns"
        case elapsedNs = "elapsed_ns"
        case deviceID = "device_id"
        case deviceProduct = "device_product"
        case transport
        case vendorID = "vendor_id"
        case productID = "product_id"
        case primaryUsagePage = "primary_usage_page"
        case primaryUsage = "primary_usage"
        case usagePage = "usage_page"
        case usage
        case reportID = "report_id"
        case hidValue = "hid_value"
        case hidLogicalMin = "hid_logical_min"
        case hidLogicalMax = "hid_logical_max"
        case reportType = "report_type"
        case reportLength = "report_length"
        case reportHex = "report_hex"
        case hidppDeviceIndex = "hidpp_device_index"
        case hidppFeatureIndex = "hidpp_feature_index"
        case hidppEventID = "hidpp_event_id"
        case hidppWheelFlags = "hidpp_wheel_flags"
        case hidppWheelDelta = "hidpp_wheel_delta"
        case hidppThumbwheelRotation = "hidpp_thumbwheel_rotation"
        case hidppThumbwheelStatus = "hidpp_thumbwheel_status"
        case lineDeltaY = "line_delta_y"
        case lineDeltaX = "line_delta_x"
        case fixedDeltaY = "fixed_delta_y"
        case fixedDeltaX = "fixed_delta_x"
        case pointDeltaY = "point_delta_y"
        case pointDeltaX = "point_delta_x"
        case rawDeltaY = "raw_delta_y"
        case rawDeltaX = "raw_delta_x"
        case acceleratedDeltaY = "accelerated_delta_y"
        case acceleratedDeltaX = "accelerated_delta_x"
        case isContinuous = "is_continuous"
        case scrollPhase = "scroll_phase"
        case momentumPhase = "momentum_phase"
        case scrollCount = "scroll_count"
        case sourcePID = "source_pid"
        case viewOffsetY = "view_offset_y"
        case viewOffsetX = "view_offset_x"
        case viewDocumentHeight = "view_document_height"
        case viewViewportHeight = "view_viewport_height"
        case viewRemainingY = "view_remaining_y"
        case message
    }

    init(sequence: UInt64, scenario: String, layer: String, eventTimestampNs: UInt64, startTimestampNs: UInt64) {
        self.schemaVersion = 1
        self.sequence = sequence
        self.scenario = scenario
        self.layer = layer
        self.eventTimestampNs = eventTimestampNs
        self.elapsedNs = eventTimestampNs >= startTimestampNs ? eventTimestampNs - startTimestampNs : 0
    }
}
