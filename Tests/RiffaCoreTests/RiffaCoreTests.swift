import Testing
@testable import RiffaCore

@Test("Core exposes a semantic version")
func coreVersion() {
    #expect(RiffaCore.version == "0.1.0")
}
