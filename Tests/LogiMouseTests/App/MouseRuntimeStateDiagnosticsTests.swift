import Testing
@testable import LogiMouse

@Test func runtimeDiagnosticDescriptionContainsEverySafetyRelevantField() {
    let state = MouseRuntimeState(
        lifecycle: .waking(attempt: 2),
        device: .deviceReady(.bluetooth),
        takeoverRequested: true,
        verifiedAxes: HIDPPTakeoverAxes(vertical: true, horizontal: false),
        generation: 9,
        selectedTransport: .bluetooth
    )

    #expect(state.diagnosticDescription.contains("generation=9"))
    #expect(state.diagnosticDescription.contains("lifecycle=waking(attempt:2)"))
    #expect(state.diagnosticDescription.contains("device=deviceReady(transport:Bluetooth)"))
    #expect(state.diagnosticDescription.contains("selectedTransport=Bluetooth"))
    #expect(state.diagnosticDescription.contains("takeoverRequested=true"))
    #expect(state.diagnosticDescription.contains("verifiedAxes={vertical:true,horizontal:false}"))
    #expect(state.diagnosticDescription.contains("outputVerified={vertical:false,horizontal:false}"))
}
