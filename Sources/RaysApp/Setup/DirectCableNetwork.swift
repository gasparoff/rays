import AppKit
import Darwin
import Foundation
import SystemConfiguration
import RaysOutput

struct WiredAdapter: Identifiable, Equatable {
    let id: String
    let name: String
    let active: Bool
    let addresses: [String]
}

/// Reversible preparation of the direct Mac → ODE cable.
/// Merely constructing/refreshing this object never changes system settings.
@MainActor
final class DirectCableNetwork: ObservableObject {
    @Published private(set) var adapters: [WiredAdapter] = []
    @Published var selectedInterface = ""
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var decision: DirectCablePolicy.Decision = .unavailable(String(localized: "Connect the Ethernet adapter."))
    @Published private(set) var canRemoveAlias = false
    private var allAddresses: [DirectCablePolicy.Address] = []
    private var automaticAttempts: Set<String> = []
    private let ownershipKey = "LightSystem.directCableOwnedInterface"

    init() { refresh() }

    func refresh() {
        var collected: [DirectCablePolicy.Address] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&pointer) == 0, let first = pointer {
            defer { freeifaddrs(first) }
            var current: UnsafeMutablePointer<ifaddrs>? = first
            while let item = current {
                let record = item.pointee
                if let address = record.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                   let mask = record.ifa_netmask {
                    var a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var aText = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var mText = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &a, &aText, socklen_t(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &m, &mText, socklen_t(INET_ADDRSTRLEN))
                    collected.append(.init(interface: String(cString: record.ifa_name),
                                           ip: String(cString: aText), mask: String(cString: mText)))
                }
                current = record.ifa_next
            }
        }
        allAddresses = collected
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        adapters = interfaces.compactMap { interface in
            guard SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeEthernet,
                  let rawName = SCNetworkInterfaceGetBSDName(interface) else { return nil }
            let name = rawName as String
            guard name.range(of: "^en[0-9]{1,3}$", options: .regularExpression) != nil else { return nil }
            let link = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any]
            let active = link?["Active"] as? Bool ?? false
            return WiredAdapter(id: name,
                                name: (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? name,
                                active: active,
                                addresses: collected.filter { $0.interface == name }.map(\.ip))
        }.sorted { ($0.active ? 0 : 1, $0.id) < ($1.active ? 0 : 1, $1.id) }
        if !adapters.contains(where: { $0.id == selectedInterface && $0.active }) {
            let active = adapters.filter(\.active)
            selectedInterface = active.count == 1 ? active[0].id : ""
        }
        evaluateSelection()
    }

    func evaluateSelection() {
        guard let adapter = adapters.first(where: { $0.id == selectedInterface }) else {
            decision = .unavailable(adapters.filter(\.active).count > 1
                                    ? String(localized: "Choose the adapter connected to the ENTTEC.")
                                    : String(localized: "Connect the Ethernet adapter and power on the ODE."))
            if case let .unavailable(message) = decision { status = message }
            return
        }
        decision = DirectCablePolicy.evaluate(interface: adapter.id, isWired: true,
                                               isActive: adapter.active, addresses: allAddresses)
        switch decision {
        case .ready: status = String(localized: "Ethernet ready · \(String(describing: adapter.id)) · the Internet stays on the current connection.")
        case .addAlias: status = String(localized: "Prepare the direct cable to the ODE. macOS will ask for administrator permission.")
        case let .unavailable(message): status = message
        }
        canRemoveAlias = UserDefaults.standard.string(forKey: ownershipKey) == adapter.id &&
            allAddresses.contains { $0.interface == adapter.id && $0.ip == DirectCablePolicy.localAddress }
    }

    /// One automatic attempt per wired adapter per launch. A cancelled macOS
    /// authorization never causes repeated password dialogs in the timer.
    func prepareAutomaticallyIfNeeded() async {
        guard !busy else { return }
        refresh()
        guard case .addAlias = decision, !automaticAttempts.contains(selectedInterface) else { return }
        automaticAttempts.insert(selectedInterface)
        await prepare()
    }

    func prepare() async {
        guard !busy else { return }
        refresh()
        guard case let .addAlias(command) = decision else { return }
        let selected = selectedInterface
        busy = true
        let result = await Self.runAdministratorCommand(command,
            prompt: String(localized: "RAYS adds a temporary address to the lights' Ethernet cable only. Wi-Fi, DHCP and the Internet are not changed."))
        busy = false
        if result.code == 0 {
            UserDefaults.standard.set(selected, forKey: ownershipKey)
            refresh()
        } else {
            status = result.message.contains("-128") ? String(localized: "Preparation canceled.") : String(localized: "Could not prepare Ethernet: \(String(describing: result.message))")
        }
    }

    func removeOwnedAlias() async {
        guard !busy, canRemoveAlias,
              let owned = UserDefaults.standard.string(forKey: ownershipKey),
              owned == selectedInterface,
              let command = DirectCablePolicy.removalCommand(interface: owned) else { return }
        busy = true
        let result = await Self.runAdministratorCommand(command,
            prompt: String(localized: "RAYS removes only the temporary address it added to the lights' cable."))
        busy = false
        if result.code == 0 {
            UserDefaults.standard.removeObject(forKey: ownershipKey)
            refresh()
        } else { status = String(localized: "Restore canceled or failed.") }
    }

    private nonisolated static func runAdministratorCommand(_ command: String, prompt: String) async -> (code: Int32, message: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Both the interface and every command token originate in the
                // validated policy. No paths or free-form user strings enter a shell.
                let quotedCommand = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let quotedPrompt = prompt.replacingOccurrences(of: "\"", with: "\\\"")
                let script = "do shell script \"\(quotedCommand)\" with administrator privileges with prompt \"\(quotedPrompt)\""
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch { continuation.resume(returning: (-1, error.localizedDescription)) }
            }
        }
    }
}
