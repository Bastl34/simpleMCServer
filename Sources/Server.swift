import AppKit
import Network

struct LogLine: Identifiable {
    enum Kind { case info, warning, error, chat, event, input, app }
    let id: Int
    let text: String
    let kind: Kind
}

struct Player: Identifiable, Equatable {
    let name: String
    let since: Date
    var id: String { name }
}

/// Someone who tried to join but isn't on the whitelist.
struct Rejection: Identifiable, Equatable {
    let name: String
    var uuid: String?
    var date: Date
    var id: String { name }
}

/// An entry of whitelist.json / ops.json (ops.json has a few more fields; we only ever write whitelist.json).
struct ListedPlayer: Codable, Identifiable, Equatable {
    var uuid: String
    var name: String
    var id: String { uuid }
}

enum ServerError: LocalizedError {
    case noJar(String), noJava(String), eula(String), external, unknownPlayer(String), invalidName(String)

    var errorDescription: String? {
        switch self {
        case .noJar(let path): String(localized: "There is no server.jar at “\(path)”.")
        case .noJava(let path): String(localized: "There is no Java at “\(path)”. Install a JDK or change the path in Settings.")
        case .eula(let path): String(localized: "The Minecraft EULA hasn't been accepted yet. Set “eula=true” in “\(path)”.")
        case .external: String(localized: "The server was started outside of simpleMCServer and can't be controlled from here.")
        case .unknownPlayer(let name): String(localized: "There is no Minecraft account called “\(name)”.")
        case .invalidName(let name): String(localized: "“\(name)” is not a valid player name.")
        }
    }
}

/// The Minecraft server as a child process: commands go to its stdin, its output is parsed for status,
/// players and whitelist rejections. A server started elsewhere (e.g. in Terminal) is detected via its
/// port and shown read-only, with players and log taken from logs/latest.log.
@MainActor
final class Server: ObservableObject {
    enum State { case stopped, starting, running, stopping, crashed, external }
    enum Event { case started, crashed(restarting: Bool), joined(String), left(String), rejected(String) }

    @Published private(set) var state = State.stopped
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var players: [Player] = []
    @Published private(set) var rejections: [Rejection] = []
    @Published private(set) var whitelist: [ListedPlayer] = []
    @Published private(set) var ops: [ListedPlayer] = []
    @Published private(set) var whitelistEnabled = false
    @Published private(set) var version: String?
    @Published private(set) var startedAt: Date?
    /// What the app is doing with the server right now (backup, update …), shown in the menu and the console.
    @Published var activity: String?
    /// Set during an update, so a failed start of the new version doesn't trigger the crash restart.
    var suppressRestart = false
    var onEvent: ((Event) -> Void)?

    /// Our own process exists (also while starting or stopping).
    var hasProcess: Bool { process != nil }
    /// Our own process is running and accepts commands.
    var acceptsCommands: Bool { process != nil && (state == .running || state == .starting) }
    var isBusy: Bool { state == .starting || state == .stopping || activity != nil }

    private let settings: Settings
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextLineID = 0
    private var continuationKind = LogLine.Kind.info // for stack traces etc. without a "[time] [thread/LEVEL]: " prefix
    private var uuids: [String: String] = [:]
    private var crashes: [Date] = []
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var lineWaiters: [UUID: (match: (String) -> Bool, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var stopTimeout: Task<Void, Never>?
    private var tailOffset: UInt64 = 0
    private var ticks = 0

    private var logFile: URL { settings.folder.appendingPathComponent("logs/latest.log") }

    init(settings: Settings) {
        self.settings = settings
        reloadLists()
        loadHistory()
        players = []
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - Start / stop

    func start() throws {
        guard process == nil else { return }
        guard state != .external else { throw ServerError.external }
        let fm = FileManager.default
        guard fm.fileExists(atPath: settings.jar.path) else { throw ServerError.noJar(settings.jar.path) }
        guard fm.isExecutableFile(atPath: settings.java) else { throw ServerError.noJava(settings.java) }
        let eula = settings.folder.appendingPathComponent("eula.txt")
        guard let text = try? String(contentsOf: eula, encoding: .utf8), text.contains("eula=true") else {
            throw ServerError.eula(eula.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.java)
        process.currentDirectoryURL = settings.folder
        process.arguments = ["-Xmx\(settings.memoryGB)G", "-Xms\(settings.memoryGB)G"]
            + settings.jvmArguments.split(separator: " ").map(String.init)
            + ["-jar", "server.jar", "nogui"]
        let inputPipe = Pipe(), output = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.received(data, live: true) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { self?.exited(status: status) }
        }
        buffer.removeAll()
        note(String(localized: "Starting server…"))
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
        state = .starting
        players = []
        version = nil
    }

    /// Sends "stop" and waits until the process has exited (after 90 s it gets terminated, after 2 min killed).
    func stop() async {
        guard process != nil else { return }
        if state != .stopping {
            state = .stopping
            write("stop")
            stopTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { return }
                self?.note(String(localized: "The server doesn't respond – terminating it."))
                self?.process?.terminate()
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let pid = self?.process?.processIdentifier else { return }
                kill(pid, SIGKILL)
            }
        }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    func restart() async throws {
        await stop()
        try start()
    }

    /// true as soon as the server reports "Done", false if it exits before.
    func waitUntilRunning() async -> Bool {
        if state == .running { return true }
        guard process != nil, state == .starting else { return false }
        return await withCheckedContinuation { startWaiters.append($0) }
    }

    private func exited(status: Int32) {
        let expected = state == .stopping
        stopTimeout?.cancel()
        if !buffer.isEmpty { received(Data([0x0A]), live: true) } // flush the last unterminated line
        process = nil
        input = nil
        players = []
        startedAt = nil
        tailOffset = fileSize(logFile)
        note(expected ? String(localized: "Server stopped.")
                           : String(localized: "The server exited unexpectedly (code \(Int(status)))."))
        startWaiters.forEach { $0.resume(returning: false) }
        startWaiters.removeAll()
        lineWaiters.values.forEach { $0.continuation.resume(returning: false) }
        lineWaiters.removeAll()

        if expected {
            state = .stopped
        } else {
            state = .crashed
            crashes = crashes.filter { $0 > .now.addingTimeInterval(-600) } + [.now]
            let restart = settings.restartAfterCrash && !suppressRestart && crashes.count <= 3
            onEvent?(.crashed(restarting: restart))
            if restart {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, self.state == .crashed else { return }
                    try? self.start()
                }
            }
        }
        exitWaiters.forEach { $0.resume() }
        exitWaiters.removeAll()
    }

    // MARK: - Commands

    func send(_ command: String) {
        guard acceptsCommands else { return }
        let command = command.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        append([LogLine(id: nextID(), text: "> \(command)", kind: .input)])
        write(command)
    }

    func say(_ message: String) { send("say \(message)") }
    func tell(_ player: String, _ message: String) { send("tell \(player) \(message)") }
    func kick(_ player: String) { send("kick \(player)") }
    func setOp(_ player: String, _ on: Bool) { send("\(on ? "op" : "deop") \(player)") }
    func isOp(_ name: String) -> Bool { ops.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    /// Sends a command and waits for an output line that matches (false on timeout or when the server exits).
    func sendAndWait(_ command: String, seconds: Double, until match: @escaping (String) -> Bool) async -> Bool {
        guard acceptsCommands else { return false }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lineWaiters[id] = (match, continuation)
            send(command)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.lineWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
            }
        }
    }

    private func write(_ command: String) {
        try? input?.write(contentsOf: Data("\(command)\n".utf8))
    }

    // MARK: - Whitelist

    static func isValidName(_ name: String) -> Bool { name.wholeMatch(of: #/[A-Za-z0-9_]{1,16}/#) != nil }

    /// While the server runs via "whitelist add" (it looks up the account itself), otherwise directly in whitelist.json.
    func addToWhitelist(_ name: String) async throws {
        guard Self.isValidName(name) else { throw ServerError.invalidName(name) }
        if acceptsCommands { return send("whitelist add \(name)") }
        guard state != .external else { throw ServerError.external }
        reloadLists()
        guard !whitelist.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        let entry = if let uuid = uuids[name] { ListedPlayer(uuid: uuid, name: name) } else { try await Self.lookup(name) }
        try saveWhitelist(whitelist + [entry])
    }

    func removeFromWhitelist(_ name: String) throws {
        if acceptsCommands { return send("whitelist remove \(name)") }
        guard state != .external else { throw ServerError.external }
        reloadLists()
        try saveWhitelist(whitelist.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame })
    }

    func setWhitelistEnabled(_ on: Bool) throws {
        if acceptsCommands { return send("whitelist \(on ? "on" : "off")") }
        guard state != .external else { throw ServerError.external }
        let url = settings.folder.appendingPathComponent("server.properties")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix("white-list=") }) {
            lines[index] = "white-list=\(on)"
        } else {
            lines.insert("white-list=\(on)", at: max(lines.count - 1, 0))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        reloadLists()
    }

    func dismiss(_ rejection: Rejection) {
        rejections.removeAll { $0.name == rejection.name }
    }

    func reloadLists() {
        func read(_ file: String) -> [ListedPlayer] {
            let url = settings.folder.appendingPathComponent(file)
            return (try? JSONDecoder().decode([ListedPlayer].self, from: Data(contentsOf: url))) ?? []
        }
        whitelist = read("whitelist.json").sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        ops = read("ops.json")
        whitelistEnabled = settings.properties()["white-list"] == "true"
        let names = Set(whitelist.map { $0.name.lowercased() })
        rejections.removeAll { names.contains($0.name.lowercased()) }
    }

    private func saveWhitelist(_ list: [ListedPlayer]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(list).write(to: settings.folder.appendingPathComponent("whitelist.json"), options: .atomic)
        reloadLists()
    }

    /// UUID of a Minecraft account from Mojang (needed for whitelist.json while the server is stopped).
    private static func lookup(_ name: String) async throws -> ListedPlayer {
        struct Profile: Decodable { let id: String; let name: String }
        let url = URL(string: "https://api.mojang.com/users/profiles/minecraft/\(name)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let profile = try? JSONDecoder().decode(Profile.self, from: data), profile.id.count == 32 else {
            throw ServerError.unknownPlayer(name)
        }
        var uuid = profile.id
        for index in [20, 16, 12, 8] { uuid.insert("-", at: uuid.index(uuid.startIndex, offsetBy: index)) }
        return ListedPlayer(uuid: uuid, name: profile.name)
    }

    // MARK: - Output parsing

    private func received(_ data: Data, live: Bool) {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            lines.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        handle(lines, live: live)
    }

    private func handle(_ lines: [String], live: Bool) {
        var parsed: [LogLine] = []
        for text in lines where !text.isEmpty {
            parsed.append(LogLine(id: nextID(), text: text, kind: parse(text, live: live)))
        }
        append(parsed)
    }

    /// Evaluates one line like "[22:18:27] [Server thread/INFO]: Done (0.483s)! For help, type "help"".
    private func parse(_ text: String, live: Bool) -> LogLine.Kind {
        guard text.hasPrefix("["), let separator = text.range(of: "]: ") else { return continuationKind }
        let header = text[..<separator.lowerBound]
        var message = text[separator.upperBound...]
        if message.hasPrefix("System chat: ") { message = message.dropFirst("System chat: ".count) }
        var kind = LogLine.Kind.info
        if header.hasSuffix("/WARN") { kind = .warning }
        if header.hasSuffix("/ERROR") || header.hasSuffix("/FATAL") { kind = .error }
        continuationKind = kind
        let date = timestamp(text)

        if message.hasPrefix("<") || message.hasPrefix("[Not Secure] ") || message.hasPrefix("[Server]") {
            kind = .chat
        } else if let match = message.wholeMatch(of: #/([A-Za-z0-9_]{1,16}) joined the game/#) {
            let name = String(match.1)
            players.removeAll { $0.name == name }
            players.append(Player(name: name, since: date))
            rejections.removeAll { $0.name == name }
            if live { onEvent?(.joined(name)) }
            kind = .event
        } else if let match = message.wholeMatch(of: #/([A-Za-z0-9_]{1,16}) left the game/#) {
            let name = String(match.1)
            players.removeAll { $0.name == name }
            if live { onEvent?(.left(name)) }
            kind = .event
        } else if message.contains(" has made the advancement ") || message.contains(" has completed the challenge ")
                    || message.contains(" has reached the goal ") {
            kind = .event
        } else if let match = message.wholeMatch(of: #/UUID of player ([A-Za-z0-9_]{1,16}) is ([0-9a-f-]{36})/#) {
            uuids[String(match.1)] = String(match.2)
        } else if let match = message.prefixMatch(of: #/Disconnecting ([A-Za-z0-9_]{1,16}) \(.*\): You are not white-listed/#) {
            let name = String(match.1)
            if !whitelist.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                rejections.removeAll { $0.name == name }
                rejections.insert(Rejection(name: name, uuid: uuids[name], date: date), at: 0)
                if live { onEvent?(.rejected(name)) }
            }
            kind = .event
        } else if message.hasPrefix("Starting minecraft server version ") {
            version = String(message.dropFirst("Starting minecraft server version ".count))
        } else if message.hasPrefix("Done (") {
            if process != nil, state == .starting {
                state = .running
                startedAt = .now
                startWaiters.forEach { $0.resume(returning: true) }
                startWaiters.removeAll()
                onEvent?(.started)
            }
        } else if message == "Stopping server" {
            if process != nil { state = .stopping } // also when someone typed "stop" in the console or in game
        } else if message.localizedCaseInsensitiveContains("whitelist") || message.contains("server operator") {
            // the server writes whitelist.json / ops.json / server.properties right around this line
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.reloadLists()
            }
        }

        if live {
            for (id, waiter) in lineWaiters where waiter.match(String(message)) {
                lineWaiters.removeValue(forKey: id)
                waiter.continuation.resume(returning: true)
            }
        }
        return kind
    }

    /// The "[HH:mm:ss]" of a log line as today's date (yesterday if that would be in the future).
    private func timestamp(_ text: String) -> Date {
        guard let match = text.prefixMatch(of: #/\[(\d\d):(\d\d):(\d\d)\]/#),
              let date = Calendar.current.date(bySettingHour: Int(match.1)!, minute: Int(match.2)!, second: Int(match.3)!, of: .now)
        else { return .now }
        return date > .now.addingTimeInterval(60) ? date.addingTimeInterval(-86400) : date
    }

    /// A line from the app itself in the console log.
    func note(_ text: String) {
        let time = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        append([LogLine(id: nextID(), text: "[\(time)] \(text)", kind: .app)])
    }

    private func append(_ lines: [LogLine]) {
        guard !lines.isEmpty else { return }
        log.append(contentsOf: lines)
        if log.count > 6000 { log.removeFirst(log.count - 5000) } // in chunks, so the console rarely has to redraw everything
    }

    private func nextID() -> Int {
        nextLineID += 1
        return nextLineID
    }

    // MARK: - Server running elsewhere

    /// Shows the current logs/latest.log (also gives the players of a server that runs elsewhere).
    private func loadHistory() {
        guard let data = try? Data(contentsOf: logFile) else { return }
        tailOffset = UInt64(data.count)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(3000).map(String.init)
        handle(lines, live: false)
    }

    private func tick() {
        ticks += 1
        guard process == nil else { return }
        if state == .external { tail() }
        if ticks % 5 == 0 { Task { await probe() } }
    }

    /// Checks whether something is listening on the server port although we didn't start it.
    func probe() async {
        guard process == nil else { return }
        let properties = settings.properties()
        let ip = properties["server-ip"] ?? ""
        let port = UInt16(properties["server-port"] ?? "") ?? 25565
        let open = await Self.isListening(host: ip.isEmpty ? "127.0.0.1" : ip, port: port)
        guard process == nil else { return }
        if open, state != .external {
            state = .external
            log.removeAll()
            loadHistory()
            note(String(localized: "A server started outside of simpleMCServer is running – log and players are read-only."))
        } else if !open, state == .external {
            state = .stopped
            players = []
        }
    }

    /// New lines of latest.log while the server runs elsewhere.
    private func tail() {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < tailOffset { tailOffset = 0 } // new log file after a restart
        guard size > tailOffset else { return }
        try? handle.seek(toOffset: tailOffset)
        guard let data = try? handle.read(upToCount: Int(size - tailOffset)) else { return }
        tailOffset = size
        received(data, live: true)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    nonisolated private static func isListening(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { open in
                guard once.claim() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .waiting, .failed: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(false) }
        }
    }
}

/// Lets exactly one of several callbacks through.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

extension Server {
    /// One line for the menu and the console, e.g. "Running – 26.3 – for 2 hr, 14 min".
    var statusText: String {
        if let activity { return activity }
        switch state {
        case .stopped: return String(localized: "Server stopped")
        case .starting: return String(localized: "Server is starting…")
        case .stopping: return String(localized: "Server is stopping…")
        case .crashed: return String(localized: "Server crashed")
        case .external: return String(localized: "Running outside of simpleMCServer")
        case .running:
            let version = version ?? "?"
            guard let startedAt else { return String(localized: "Running – \(version)") }
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute]
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 2
            let uptime = formatter.string(from: max(startedAt.distance(to: .now), 60)) ?? ""
            return String(localized: "Running – \(version) – for \(uptime)")
        }
    }

    var statusColor: NSColor {
        if activity != nil { return .systemOrange }
        return switch state {
        case .running, .external: .systemGreen
        case .starting, .stopping: .systemOrange
        case .crashed: .systemRed
        case .stopped: .tertiaryLabelColor
        }
    }
}
