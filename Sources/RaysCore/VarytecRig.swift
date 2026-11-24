import Foundation

/// Manufacturer channel maps checked against the official Thomann manuals dated
/// 08.05.2024, IDs 585812 (TRI 180) and 585819 (TRI 380).
public enum VarytecRig {
    public static let tri180Manual = "https://images.thomann.de/pics/atg/atgdata/document/manual/585812_c_585812_en_online.pdf"
    public static let tri380Manual = "https://images.thomann.de/pics/atg/atgdata/document/manual/585819_c_585819_en_online.pdf"

    /// The TRI mirrors: triangles with their RGB zones around the centre.
    public static let triangle = FixtureAppearance(kind: .triangle, zones: .radial)

    public static let profiles: [FixtureProfile] = [
        .init(
            id: "varytec.tri180.5", name: "Retro Blinder TRI 180", manufacturer: "Varytec", mode: "05 CH",
            isGeneric: false, isVerified: true,
            notes: "Manuale ufficiale ID 585812, p.26. R/G/B, COB bianco, strobo aperto a 0. \(tri180Manual)",
            channels: [.init(.red), .init(.green), .init(.blue), .init(.white), .init(.ignore)],
            visual: triangle),
        .init(
            id: "varytec.tri180.8", name: "Retro Blinder TRI 180", manufacturer: "Varytec", mode: "08 CH",
            isGeneric: false, isVerified: true,
            notes: "Manuale ufficiale ID 585812, pp.27–28. Riserva tutti gli 8 canali: non usare indirizzi 8 e 15 insieme. \(tri180Manual)",
            channels: [
                .init(.dimmer), .init(.ignore), .init(.red), .init(.green), .init(.blue), .init(.blinder), .init(.ignore), .init(.ignore),
            ],
            visual: triangle),
        .init(
            id: "varytec.tri380.5", name: "Retro Blinder TRI 380", manufacturer: "Varytec", mode: "05 CH",
            isGeneric: false, isVerified: true,
            notes: "Manuale ufficiale ID 585819, p.28. R/G/B, COB bianco, strobo aperto a 0. \(tri380Manual)",
            channels: [.init(.red), .init(.green), .init(.blue), .init(.white), .init(.ignore)],
            visual: triangle),
        .init(
            id: "varytec.tri380.25", name: "Retro Blinder TRI 380", manufacturer: "Varytec", mode: "25 CH",
            isGeneric: false, isVerified: true,
            notes:
                "Manuale ufficiale ID 585819, pp.34–36. Dimmer RGB; tre COB indipendenti; sei segmenti RGB. Strobo e programmi a 0. \(tri380Manual)",
            channels: [.init(.dimmer), .init(.blinder), .init(.blinder), .init(.blinder), .init(.ignore)]
                + (0..<6).flatMap { _ in [ChannelDefinition(.red), .init(.green), .init(.blue)] }
                + [.init(.ignore), .init(.ignore)],
            visual: triangle),
    ]

    /// Single TRI 180 bench test confirmed on the real light: 08CH, A008, Art-Net universe 1.
    /// Returned unconfirmed: the user still ticks the checkbox once.
    public static let tri180TestTitle = String(localized: "TRI180 test · 08CH · A008 · U1")
    public static let tri180TestInstruction = String(localized: "On the light: Mode → DMX, CH Mode → 08CH, Address → 008")

    public static func tri180Test(universe: Int = 1) -> Patch {
        Patch(fixtures: [.init(label: "TRI 180 · test", profileID: "varytec.tri180.8", universe: universe, address: 8)])
    }

    /// Physical settings the full rig preset assumes on each light.
    public static let fullRigTitle = String(localized: "Reference rig · 2× TRI180 + TRI380")
    public static let fullRigInstructions = [
        String(localized: "Left TRI 180: Mode → DMX, CH Mode → 08CH, Address → 008"),
        String(localized: "Right TRI 180: Mode → DMX, CH Mode → 08CH, Address → 016"),
        String(localized: "Center TRI 380: Mode → DMX, CH Mode → 25CH, Address → 024"),
    ]

    /// Production rig preserves the physically tested TRI180 at 08CH / A008.
    /// The old PDF's A015/A022 patch overlaps in eight-channel mode, so the
    /// remaining fixtures receive nonoverlapping addresses once on their displays.
    public static func referenceRig(universe: Int = 1) -> Patch {
        Patch(fixtures: [
            .init(label: "TRI 180 · sinistra", profileID: "varytec.tri180.8", universe: universe, address: 8, role: .left),
            .init(label: "TRI 380 · centro", profileID: "varytec.tri380.25", universe: universe, address: 24, role: .center),
            .init(label: "TRI 180 · destra", profileID: "varytec.tri180.8", universe: universe, address: 16, role: .right),
        ])
    }

}
