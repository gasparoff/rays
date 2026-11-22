import Foundation

/// The reference rig can be prepared without a patch editor. Only the
/// original single-lamp bench patch is migrated; a custom user's patch is kept.
public enum RigAutoSetup {
    public static func preparedRig(replacing bench: Patch?, library: ProfileLibrary) -> Patch? {
        if let bench {
            guard bench.customProfiles.isEmpty, bench.fixtures.count == 1,
                  let fixture = bench.fixtures.first,
                  fixture.profileID == "varytec.tri180.8", fixture.address == 8, fixture.universe == 1 else { return nil }
        }
        var rig = VarytecRig.referenceRig()
        if let id = bench?.fixtures.first?.id { rig.fixtures[0].id = id }
        guard rig.validate(library: library).isEmpty else { return nil }
        // This is a named, preconfigured rig requested by its owner. Physical
        // addresses remain printed in Setup and cannot be programmed over DMX.
        rig.setConfirmed(true, library: library)
        return rig
    }
}
