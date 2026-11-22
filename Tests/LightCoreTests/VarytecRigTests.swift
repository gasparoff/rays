import XCTest
@testable import LightCore

final class VarytecRigTests: XCTestCase {
    func testPresetPreservesAddressesWithoutOverlaps() {
        let patch = VarytecRig.referenceRig()
        let lib = ProfileLibrary()
        XCTAssertTrue(patch.validate(library: lib).isEmpty)
        XCTAssertEqual(patch.fixtures.map(\.address), [8, 24, 16])
        XCTAssertEqual(patch.fixtures.map(\.profileID), ["varytec.tri180.8", "varytec.tri380.25", "varytec.tri180.8"])
        XCTAssertFalse(patch.isConfirmed(library: lib))
        XCTAssertTrue(VarytecRig.profiles.allSatisfy { $0.isVerified && !$0.isGeneric })
    }

    func test380MasterAlsoDimsIndependentWhiteCOBs() throws {
        let lib = ProfileLibrary()
        let profile = try XCTUnwrap(lib.profile(id: "varytec.tri380.25"))
        XCTAssertEqual(profile.footprint, 25)
        let full = DMXComposer.channelValues(profile: profile, color: .init(1, 0.5, 0.2, 1), master: 1)
        XCTAssertEqual(Array(full[0..<5]), [255, 255, 255, 255, 0])
        for offset in [5, 8, 11, 14, 17, 20] { XCTAssertEqual(full[offset], 255) }
        XCTAssertEqual(Array(full[23..<25]), [0, 0])
        let zero = DMXComposer.channelValues(profile: profile, color: .init(1, 1, 1, 1), master: 0)
        XCTAssertEqual(zero[0], 0)
        XCTAssertEqual(Array(zero[1...3]), [0, 0, 0], "RGB master must also silence independent COB channels")
    }

    func test180FiveChannelsAndNoHardwareStrobe() throws {
        let p = try XCTUnwrap(ProfileLibrary().profile(id: "varytec.tri180.5"))
        XCTAssertEqual(DMXComposer.channelValues(profile: p, color: .init(1, 0, 0, 0.4), master: 0.5), [128, 0, 0, 51, 0])
        for profile in VarytecRig.profiles {
            for (i, channel) in profile.channels.enumerated() where channel.kind == .ignore {
                XCTAssertEqual(DMXComposer.channelValues(profile: profile, color: .init(1, 1, 1, 1), master: 1)[i], 0)
            }
        }
    }

    func testOriginalPdfSevenChannelAssumptionWouldOverlapInEightChannelMode() {
        let patch = Patch(fixtures: [
            .init(label: "a", profileID: "varytec.tri180.8", universe: 0, address: 8),
            .init(label: "b", profileID: "varytec.tri180.8", universe: 0, address: 15)
        ])
        XCTAssertFalse(patch.validate(library: ProfileLibrary()).isEmpty)
    }
}
