import XCTest
@testable import LightCore

/// The user's physically tested patch (TRI 180 · 08CH · A008 · U1) was confirmed with this
/// fingerprint. Any change to the TRI 180 8CH profile encoding or the fixture encoding would
/// silently un-confirm the real light, so it is pinned here.
final class FingerprintRegressionTests: XCTestCase {
    func testConfirmedSingleTRI180PatchKeepsItsFingerprint() throws {
        let json = #"""
        {
          "confirmedFingerprint" : "b6474640ca34a0b6",
          "customProfiles" : [],
          "fixtures" : [
            {
              "address" : 8,
              "id" : "B0DC4F2C-E823-43C0-AB87-232DE4A330D1",
              "label" : "TRI 180 · test",
              "profileID" : "varytec.tri180.8",
              "universe" : 1
            }
          ]
        }
        """#
        let patch = try JSONDecoder().decode(Patch.self, from: Data(json.utf8))
        XCTAssertEqual(patch.fingerprint(library: ProfileLibrary()), "b6474640ca34a0b6")
        XCTAssertTrue(patch.isConfirmed(library: ProfileLibrary()))
    }
}
