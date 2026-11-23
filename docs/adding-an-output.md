# Add an output driver

An output driver turns the engine's DMX frames into something on the wire: UDP packets
(Art-Net, sACN), bytes on a serial port (DMX USB Pro) or anything else. Drivers live in
`Sources/RaysOutput`, which may only import Foundation.

Open an issue first so we can agree on the protocol and how it will be tested without hardware.

## 1. Implement the core

A driver is a class conforming to `OutputDriver`. Only these members have no default:

| Member | What it does |
|---|---|
| `driverID` | Stable id, persisted in the preferences (`"artnet"`, `"sacn"`, `"dmxusbpro"`) |
| `isOpen`, `open(queue:now:)`, `close()` | Acquire and release the socket or device. `open` sets `socketError` when it fails |
| `target(now:patchUniverses:)` | Where frames go now and which universes it accepts; nil keeps output off |
| `sendDMX(_:to:)` | One frame per patch universe. Return false when a frame could not be sent |
| `socketError`, `sendError` | Short, localized messages shown in Setup |
| `diagnosis(now:)` | Hints for Setup, most important first |

```swift
public final class MyDriver: OutputDriver {
    public static let driverID = "mydriver"
    public var driverID: String { Self.driverID }
    public private(set) var isOpen = false
    public private(set) var socketError: String?
    public private(set) var sendError: String?

    public func open(queue: DispatchQueue, now: @escaping () -> TimeInterval) { isOpen = true }
    public func close() { isOpen = false }

    public func target(now: TimeInterval, patchUniverses: [PortAddress]) -> OutputTarget? {
        guard isOpen else { return nil }
        return OutputTarget(
            ip: IPv4Address(0, 0, 0, 0), name: "My output", universes: patchUniverses,
            verified: false, fresh: false, endpoint: "my device")
    }

    @discardableResult
    public func sendDMX(_ frames: [PortAddress: [UInt8]], to target: OutputTarget) -> Bool { true }

    public func diagnosis(now: TimeInterval) -> [String] { [] }
}
```

`verified: false` tells the engine the device can't confirm it is there; set `verified: true`
only when discovery saw it, and then keep `fresh` up to date.

## 2. Add discovery only if the protocol has it

`reopenInterval` (default 2 s), `pollIfDue`, `forcePoll`, `nodes`, `preferredIdentity`,
`manualIP`, `onPreferredIdentityChanged`, `select(identity:)`, `interfaces` and `pollError` have
inert defaults: nothing to discover, nothing to select, settable members ignore writes. Declare
your own version of any of them and the engine uses it. A settable one needs a public getter
and setter (`public var preferredIdentity: String?`): with `private(set)` it would not satisfy
the requirement and the default would be used instead. `ArtNetController` implements them all;
`SACNDriver` and `DMXUSBProDriver` implement only the ones they need.

## 3. Rules for the engine path

- Every member is called on the engine's serial queue, 30 times a second for `sendDMX`. Never
  block it: a slow device gets its own queue, as `DMXUSBProDriver` does with its writer (newest
  frame only, see `LatestMailbox`). State the engine reads must stay on its queue or behind a lock.
- Blackout always wins: when output is disarmed the engine sends black frames and may close the
  driver right after. `close()` must not drop the last frame.
- Never send anything before the engine calls `sendDMX`: opening a driver must not turn lights on.
- User-facing strings use `String(localized:)`, with the Italian translation in
  `Localization/it.lproj/Localizable.strings`.

## 4. Register it

Add it to `OutputSettings.registry` (`Sources/RaysEngine/ConfigStore.swift`) with its settings,
and to the driver picker in `Sources/RaysApp/Setup/OutputDriverSetup.swift`. Other code can
build an engine with its own registry:

```swift
var registry = OutputDriverRegistry.builtIn
registry.register(.init(id: MyDriver.driverID, name: "My output") { _, _ in MyDriver() })
let engine = LightEngine(tempo: tempo, transport: transport, outputDrivers: registry, outputDriverID: MyDriver.driverID)
```

## 5. Test it

Tests run without hardware. Abstract the device the way `DatagramTransport` (`FakeTransport`) and
`SerialPort` (`FakeSerialPort`) do, and cover framing, `target`, error reporting and reopen. See
`SACNTests`, `DMXUSBProTests` and `OutputDriverProtocolTests`, which also runs a core-only driver
through `LightEngine` end to end. If your driver adds a `Codable` settings type, add a
compatibility test that decodes an old or partial JSON sample.
