import Foundation
import Testing
@testable import RiffaCore

struct TextExternalChangeCoordinationTests {
    @Test("External change state starts clear and establishes a fresh baseline")
    func baselineLifecycle() {
        var state = TextExternalChangeCoordinationState()
        #expect(state.pendingChange == nil)

        state.observe(.changed)
        #expect(state.pendingChange == .changed)

        state.establishBaseline()
        #expect(state.pendingChange == nil)
    }

    @Test("A burst keeps the event requiring the strongest attention")
    func coalescesEventSeverity() {
        var state = TextExternalChangeCoordinationState()
        state.observe(.changed)
        state.observe(.moved)
        state.observe(.changed)
        #expect(state.pendingChange == .moved)

        state.observe(.deleted)
        state.observe(.unavailable)
        #expect(state.pendingChange == .unavailable)
    }

    @Test("Keep Current dismisses the notice without changing reload safety")
    func keepCurrent() {
        var state = TextExternalChangeCoordinationState(pendingChange: .changed)
        #expect(state.reloadSafety(hasUnsavedEdits: false) == .safeToReload)
        #expect(state.reloadSafety(hasUnsavedEdits: true) == .requiresDiscardConfirmation)

        state.keepCurrent()
        #expect(state.pendingChange == nil)
        #expect(state.reloadSafety(hasUnsavedEdits: true) == .requiresDiscardConfirmation)
    }

    @Test("Codable representation contains no path or text payload")
    func pathFreeCodableRepresentation() throws {
        let state = TextExternalChangeCoordinationState(pendingChange: .deleted)
        let data = try JSONEncoder().encode(state)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("deleted"))
        #expect(!json.contains("/Users/"))
        #expect(try JSONDecoder().decode(
            TextExternalChangeCoordinationState.self,
            from: data
        ) == state)
    }
}
