import Foundation

/// A physical command endpoint. Keeping IOKit behind this closure also lets
/// transaction tests simulate lost replies and device removal without hardware.
struct HIDPPCommandChannel {
    enum Request {
        case feature(deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8,
                     payload: [UInt8], timeout: TimeInterval, quietly: Bool)
        case receiverRegister(subID: UInt8, address: UInt8,
                              parameters: [UInt8], timeout: TimeInterval)
    }

    let key: UInt
    let transport: HIDPPTransport
    let send: (Request) throws -> [UInt8]
}
