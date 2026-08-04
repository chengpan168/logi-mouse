import Foundation
import Testing
@testable import LogiMouse

private let constantGainParameters = ScrollDynamicsParameters(
    decayTimeConstant: 0.030,
    minimumGain: 1,
    maximumGain: 1,
    activityMidpoint: 3,
    steepness: 8
)

@Test func expandsHIDPPPeriodsIntoRepeatedPixelEvents() {
    var model = ScrollDynamicsModel(parameters: constantGainParameters)
    let output = model.process(delta: -2, flags: 0x12, timestampNs: 1_000_000)

    #expect(output.periods == 2)
    #expect(output.pixelDeltas == [-2, -2])
    #expect(output.activityAfterInput == 4)
}

@Test func naturalAndTraditionalDirectionsAreExactOpposites() {
    var natural = ScrollDynamicsModel(parameters: constantGainParameters, directionMapping: .natural)
    var traditional = ScrollDynamicsModel(parameters: constantGainParameters, directionMapping: .traditional)

    let naturalOutput = natural.process(delta: -3, flags: 0x11, timestampNs: 1)
    let traditionalOutput = traditional.process(delta: -3, flags: 0x11, timestampNs: 1)

    #expect(naturalOutput.pixelDeltas == [-3])
    #expect(traditionalOutput.pixelDeltas == [3])
}

@Test func errorDiffusionPreservesSubpixelMovement() {
    let parameters = ScrollDynamicsParameters(
        decayTimeConstant: 0.030,
        minimumGain: 0.75,
        maximumGain: 0.75,
        activityMidpoint: 3,
        steepness: 8
    )
    var model = ScrollDynamicsModel(parameters: parameters)

    let first = model.process(delta: -2, flags: 0x11, timestampNs: 1_000_000)
    let second = model.process(delta: -2, flags: 0x11, timestampNs: 1_000_000_000)

    #expect(first.pixelDeltas == [-1])
    #expect(second.pixelDeltas == [-2])
    #expect(first.totalPixels + second.totalPixels == -3)
}

@Test func activityUsesContinuousDecayAndRaisesGain() {
    var model = ScrollDynamicsModel()

    let first = model.process(delta: -3, flags: 0x11, timestampNs: 0)
    let second = model.process(delta: -3, flags: 0x11, timestampNs: 8_000_000)
    let third = model.process(delta: -6, flags: 0x11, timestampNs: 16_000_000)
    let fourth = model.process(delta: -8, flags: 0x11, timestampNs: 24_000_000)
    let afterPause = model.process(delta: -3, flags: 0x11, timestampNs: 1_024_000_000)

    #expect(first.gain < second.gain)
    #expect(second.gain < third.gain)
    #expect(third.gain > 3)
    #expect(fourth.gain > 5)
    #expect(afterPause.gain < 1)
}

@Test func reversingDirectionClearsOnlyFractionalRemainder() {
    let parameters = ScrollDynamicsParameters(
        decayTimeConstant: 1,
        minimumGain: 0.75,
        maximumGain: 0.75,
        activityMidpoint: 3,
        steepness: 8
    )
    var model = ScrollDynamicsModel(parameters: parameters)

    _ = model.process(delta: -2, flags: 0x11, timestampNs: 0)
    let activityBeforeReverse = model.activity
    let reversed = model.process(delta: 2, flags: 0x11, timestampNs: 1_000_000)

    #expect(reversed.pixelDeltas == [1])
    #expect(reversed.activityBeforeInput > activityBeforeReverse * 0.99)
}
