import Foundation

/// The last automatic or manual server update, shown in the menu so you notice it happened.
struct UpdateRecord: Codable, Equatable {
    var from: String
    var to: String
    var date: Date
    var backup: String // file name of the world backup made right before
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var serverFolder: String { didSet { defaults.set(serverFolder, forKey: "serverFolder") } }
    @Published var java: String { didSet { defaults.set(java, forKey: "java") } }
    @Published var memoryGB: Int { didSet { defaults.set(memoryGB, forKey: "memoryGB") } }
    @Published var jvmArguments: String { didSet { defaults.set(jvmArguments, forKey: "jvmArguments") } }
    @Published var startServerAtLaunch: Bool { didSet { defaults.set(startServerAtLaunch, forKey: "startServerAtLaunch") } }
    @Published var restartAfterCrash: Bool { didSet { defaults.set(restartAfterCrash, forKey: "restartAfterCrash") } }
    @Published var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: "autoUpdate") } }
    @Published var updateHour: Int { didSet { defaults.set(updateHour, forKey: "updateHour") } }
    @Published var backupsToKeep: Int { didSet { defaults.set(backupsToKeep, forKey: "backupsToKeep") } } // 0 = keep all
    @Published var showPlayerCount: Bool { didSet { defaults.set(showPlayerCount, forKey: "showPlayerCount") } }
    @Published var notifyJoins: Bool { didSet { defaults.set(notifyJoins, forKey: "notifyJoins") } }
    @Published var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }
    @Published var lastUpdate: UpdateRecord? {
        didSet { defaults.set(try? JSONEncoder().encode(lastUpdate), forKey: "lastUpdate") }
    }
    /// Set by an update, cleared when the menu is opened – until then the menu bar icon has a blue dot.
    @Published var unseenUpdate: Bool { didSet { defaults.set(unseenUpdate, forKey: "unseenUpdate") } }

    var folder: URL { URL(fileURLWithPath: serverFolder) }
    var jar: URL { folder.appendingPathComponent("server.jar") }
    var backups: URL { folder.appendingPathComponent("Backups") }

    private init() {
        defaults.register(defaults: [
            "serverFolder": "/Volumes/Files/Minecraft",
            "java": "/usr/bin/java",
            "memoryGB": 4,
            "jvmArguments": "",
            "startServerAtLaunch": true,
            "restartAfterCrash": true,
            "autoUpdate": true,
            "updateHour": 4,
            "backupsToKeep": 10,
            "showPlayerCount": true,
            "notifyJoins": true,
            "unseenUpdate": false,
        ])
        serverFolder = defaults.string(forKey: "serverFolder")!
        java = defaults.string(forKey: "java")!
        memoryGB = defaults.integer(forKey: "memoryGB")
        jvmArguments = defaults.string(forKey: "jvmArguments")!
        startServerAtLaunch = defaults.bool(forKey: "startServerAtLaunch")
        restartAfterCrash = defaults.bool(forKey: "restartAfterCrash")
        autoUpdate = defaults.bool(forKey: "autoUpdate")
        updateHour = defaults.integer(forKey: "updateHour")
        backupsToKeep = defaults.integer(forKey: "backupsToKeep")
        showPlayerCount = defaults.bool(forKey: "showPlayerCount")
        notifyJoins = defaults.bool(forKey: "notifyJoins")
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        lastUpdate = defaults.data(forKey: "lastUpdate").flatMap { try? JSONDecoder().decode(UpdateRecord.self, from: $0) }
        unseenUpdate = defaults.bool(forKey: "unseenUpdate")
    }

    /// server.properties as a dictionary (values unescaped, e.g. `minecraft\:normal` → `minecraft:normal`).
    func properties() -> [String: String] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("server.properties"), encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            result[key] = line[line.index(after: equals)...].replacingOccurrences(of: "\\", with: "")
        }
        return result
    }

    /// The world folder name ("level-name"), "world" by default.
    var levelName: String {
        let name = properties()["level-name"] ?? ""
        return name.isEmpty ? "world" : name
    }
}
