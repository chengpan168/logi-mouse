import Foundation

enum ScrollDirectionMapping: String, Equatable, Sendable {
    /// Mapping measured while macOS/Options+ natural scrolling was enabled:
    /// HID++ and CGEvent vertical deltas have the same sign.
    case natural
    /// Traditional wheel direction is the exact sign inverse of the measured
    /// natural-scrolling profile.
    case traditional

    var multiplier: Int {
        switch self {
        case .natural: 1
        case .traditional: -1
        }
    }
}

struct ScrollDynamicsParameters: Equatable, Sendable {
    var decayTimeConstant: TimeInterval
    var minimumGain: Double
    var maximumGain: Double
    var activityMidpoint: Double
    var steepness: Double

    static let fittedDefault = ScrollDynamicsParameters(
        decayTimeConstant: 0.080,
        minimumGain: 0.85,
        maximumGain: 5.75,
        activityMidpoint: 5.3,
        steepness: 6.0
    )

    func gain(activity: Double) -> Double {
        // Clamp the exponent before `exp` to keep corrupted/extreme input from
        // producing infinity. The clamp lies far outside the fitted operating
        // range and therefore does not change normal curve values.
        let normalized = activity / activityMidpoint - 1
        let exponent = max(-60, min(60, -steepness * normalized))
        return minimumGain + (maximumGain - minimumGain) / (1 + Foundation.exp(exponent))
    }
}

struct ScrollDynamicsOutput: Equatable, Sendable {
    let pixelDeltas: [Int]
    let gain: Double
    let activityBeforeInput: Double
    let activityAfterInput: Double
    let periods: Int

    var totalPixels: Int {
        pixelDeltas.reduce(0, +)
    }
}

/// A continuous leaky-activity model inferred from the Options+ recordings.
///
/// This is deliberately not a slow/fast/stop state machine. Recent physical
/// movement forms a continuously decaying activity value. A steep logistic
/// curve maps that value to output gain, and error diffusion preserves motion
/// below one pixel. In compact form:
///
/// `activity(t) = previousActivity * exp(-elapsed / tau)`
///
/// `gain = minGain + (maxGain-minGain) / (1 + exp(-k*(activity/midpoint-1)))`
///
/// The current report updates activity only after its output is calculated,
/// matching the cold first report visible in the captures.
struct ScrollDynamicsModel: Sendable {
    private(set) var parameters: ScrollDynamicsParameters
    private(set) var directionMapping: ScrollDirectionMapping
    /// Core Graphics' broadly supported point-delta field is integer-valued.
    /// Keep the fitted 0.85 low-speed curve for analysis, but use a 1.0 runtime
    /// floor so an isolated one-unit hardware movement cannot quantize to zero.
    private let minimumInjectableGain: Double
    private(set) var activity: Double = 0
    private(set) var fractionalRemainder: Double = 0

    private var lastTimestampNs: UInt64?
    private var lastRawDirection = 0

    init(
        parameters: ScrollDynamicsParameters = .fittedDefault,
        directionMapping: ScrollDirectionMapping = .natural,
        minimumInjectableGain: Double = 1.0
    ) {
        self.parameters = parameters
        self.directionMapping = directionMapping
        self.minimumInjectableGain = minimumInjectableGain
    }

    mutating func setDirectionMapping(_ mapping: ScrollDirectionMapping) {
        guard directionMapping != mapping else { return }
        directionMapping = mapping
        fractionalRemainder = 0
    }

    mutating func reset() {
        activity = 0
        fractionalRemainder = 0
        lastTimestampNs = nil
        lastRawDirection = 0
    }

    mutating func process(delta: Int, flags: UInt8, timestampNs: UInt64) -> ScrollDynamicsOutput {
        // Low four flag bits encode how many sampling periods the reported
        // displacement represents. Bluetooth commonly batches more periods in
        // one HID++ notification than the USB receiver. Replaying each period
        // through the complete model makes those two transport shapes
        // mathematically equivalent instead of applying one stale gain to the
        // whole Bluetooth batch.
        let periods = max(1, Int(flags & 0x0f))
        let rawDirection = delta.signum()
        if rawDirection != 0, lastRawDirection != 0, rawDirection != lastRawDirection {
            fractionalRemainder = 0
        }

        var pixelDeltas: [Int] = []
        pixelDeltas.reserveCapacity(periods)
        let elapsedPerPeriod: TimeInterval?
        if let lastTimestampNs, timestampNs >= lastTimestampNs {
            elapsedPerPeriod = Double(timestampNs - lastTimestampNs)
                / 1_000_000_000
                / Double(periods)
        } else {
            elapsedPerPeriod = nil
        }

        var activityBeforeInput = activity
        var firstGain = max(minimumInjectableGain, parameters.gain(activity: activity))
        // Error diffusion carries sub-pixel output forward instead of rounding
        // each event independently. This is what keeps extremely slow code-view
        // scrolling responsive without introducing a minimum one-pixel jump.
        for period in 0..<periods {
            if let elapsedPerPeriod {
                decayActivity(elapsed: elapsedPerPeriod)
            }
            let gain = max(minimumInjectableGain, parameters.gain(activity: activity))
            if period == 0 {
                activityBeforeInput = activity
                firstGain = gain
            }
            let signedExactDelta = Double(delta * directionMapping.multiplier) * gain
            fractionalRemainder += signedExactDelta
            let pixels = Int(fractionalRemainder.rounded(.towardZero))
            fractionalRemainder -= Double(pixels)
            if pixels != 0 {
                pixelDeltas.append(pixels)
            }
            activity += Double(abs(delta))
        }

        if rawDirection != 0 {
            lastRawDirection = rawDirection
        }
        lastTimestampNs = timestampNs

        return ScrollDynamicsOutput(
            pixelDeltas: pixelDeltas,
            gain: firstGain,
            activityBeforeInput: activityBeforeInput,
            activityAfterInput: activity,
            periods: periods
        )
    }

    private mutating func decayActivity(elapsed: TimeInterval) {
        activity *= Foundation.exp(-elapsed / parameters.decayTimeConstant)
        if activity < 1e-12 {
            activity = 0
        }
    }
}
