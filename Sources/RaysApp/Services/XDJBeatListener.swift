import Foundation
import RaysTempo

/// Starts a private, headless Beat Link adapter. Native Link/DMX remain in Swift.
/// Console discovery and tempo-master selection use the same library as BLT.
@MainActor
final class XDJBeatListener: ObservableObject {
    static let staleAfter: TimeInterval = 2
    @Published private(set) var isOpen = false
    @Published private(set) var error: String?
    @Published private(set) var lastBeat: ProDJBeat?
    @Published private(set) var lastBeatTime: Date?
    @Published private(set) var seenDecks: [Int: String] = [:]
    @Published private(set) var state = "searching"

    var onBeat: (@Sendable (ProDJBeat) -> Void)?
    /// 0 follows the console's current master automatically.
    var deck = 0
    var isLive: Bool { lastBeatTime.map { Date().timeIntervalSince($0) < Self.staleAfter } ?? false }

    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var diagnostics: Pipe?
    private var timer: Timer?
    private var generation = UUID()
    private var wanted = false
    private var retryCount = 0
    private var lastMessage: Date?

    func start() {
        wanted = true
        guard process == nil else { return }
        launch()
    }

    private func launch() {
        let resources = Bundle.main.resourceURL?.appendingPathComponent("BeatLinkHelper")
        // Sources/RaysApp/Services/XDJBeatListener.swift -> project root (development runs only).
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let helper = [resources, project.appendingPathComponent("Vendor/BeatLinkHelper")]
            .compactMap { $0 }.first {
                FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/Beat Link Trigger").path)
            }
        guard let helper else {
            error = "Componente Beat Link mancante: ricrea l’app con build-app.sh."
            return
        }
        guard FileManager.default.fileExists(atPath: helper.appendingPathComponent("Contents/app/classes/LightSystemBeatLink.class").path)
        else {
            error = "Componente Beat Link da compilare: esegui build-app.sh."
            return
        }
        let proc = Process()
        proc.executableURL = helper.appendingPathComponent("Contents/MacOS/Beat Link Trigger")
        proc.arguments = []
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = stderr
        let token = UUID()
        generation = token
        let reader = BeatLinkLineReader()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            for event in reader.append(data) {
                DispatchQueue.main.async { self?.receive(event, generation: token) }
            }
        }
        // Drain logs separately. Only the bounded JSON protocol is accepted as data.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.terminated(generation: token, exitCode: proc.terminationStatus) }
        }
        process = proc; input = stdin; output = stdout; diagnostics = stderr
        state = "starting"; error = nil; lastMessage = Date()
        do {
            try proc.run()
            isOpen = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.objectWillChange.send()  // expires visible beat status even without events
                    if let last = self.lastMessage, Date().timeIntervalSince(last) > 30 {
                        self.error = "Beat Link non risponde: riavvio della connessione."
                        self.process?.terminate()
                    }
                }
            }
        } catch {
            releasePipes()
            process = nil; isOpen = false
            self.error = "Avvio Beat Link non riuscito: \(error.localizedDescription)"
            retry(generation: token)
        }
    }

    private func receive(_ event: BeatLinkEvent, generation token: UUID) {
        guard token == generation, wanted else { return }
        lastMessage = Date()
        switch event.type {
        case "ready": retryCount = 0; error = nil; state = event.state ?? "searching"
        case "status":
            state = event.state ?? "searching"
            if state == "online" { error = nil }
            if state == "network" { error = "Console rilevata: verifica che Mac e console siano sulla stessa rete Ethernet." }
        case "device":
            guard let number = event.deck else { return }
            if event.present == true {
                seenDecks[number] = event.name ?? "Pro DJ Link"
            } else {
                seenDecks.removeValue(forKey: number)
                if lastBeat?.deck == number { lastBeat = nil; lastBeatTime = nil }
            }
        case "beat":
            guard let beat = event.acceptedBeat(deck: deck) else { return }
            lastBeat = beat; lastBeatTime = Date(); error = nil
            onBeat?(beat)
        case "error":
            error = "Beat Link: \(event.message ?? "connessione non disponibile"). Chiudi eventuali altre app che usano Pro DJ Link."
        default: break
        }
    }

    private func terminated(generation token: UUID, exitCode: Int32) {
        guard token == generation else { return }
        releasePipes(); process = nil; isOpen = false
        lastBeat = nil; lastBeatTime = nil
        guard wanted else { return }
        error = "Beat Link si è fermato (\(exitCode)); nuovo tentativo automatico."
        retry(generation: token)
    }

    private func retry(generation token: UUID) {
        retryCount += 1
        let delay = min(30.0, Double(retryCount * 5))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wanted, self.generation == token, self.process == nil else { return }
            self.launch()
        }
    }

    func stop() {
        wanted = false; generation = UUID(); timer?.invalidate(); timer = nil
        let old = process
        // EOF asks the adapter to stop all sockets and exit; termination is a fallback.
        try? input?.fileHandleForWriting.close()
        releasePipes(); process = nil
        if let old {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if old.isRunning { old.terminate() }
            }
        }
        isOpen = false; error = nil; lastBeat = nil; lastBeatTime = nil; seenDecks = [:]
        state = "searching"
    }

    /// Beat selection is native; the helper and its network sockets stay open.
    func restart() { lastBeat = nil; lastBeatTime = nil }

    private func releasePipes() {
        output?.fileHandleForReading.readabilityHandler = nil
        diagnostics?.fileHandleForReading.readabilityHandler = nil
        input = nil; output = nil; diagnostics = nil
    }
}

/// FileHandle serializes callbacks on its queue; a lock also makes shutdown harmless.
private final class BeatLinkLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ data: Data) -> [BeatLinkEvent] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        guard buffer.count <= 131_072 else { buffer.removeAll(keepingCapacity: true); return [] }
        var result: [BeatLinkEvent] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
            buffer.removeSubrange(...newline)
            if let event = BeatLinkEvent.parse(line) { result.append(event) }
        }
        return result
    }
}
