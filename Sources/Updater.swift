import CryptoKit
import Foundation

struct Release: Equatable {
    let version: String
    let url: URL
    let sha1: String
    let java: Int // required Java major version
}

enum UpdateError: LocalizedError {
    case network(String), unknownVersion, checksum, java(needed: Int, installed: Int), external, startFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .network(let text): String(localized: "Mojang's server couldn't be reached: \(text)")
        case .unknownVersion: String(localized: "The version of the installed server.jar couldn't be determined.")
        case .checksum: String(localized: "The downloaded server.jar is damaged (checksum mismatch).")
        case .java(let needed, let installed):
            String(localized: "The new version needs Java \(needed), but Java \(installed) is installed.")
        case .external: String(localized: "The server was started outside of simpleMCServer and can't be updated from here.")
        case .startFailed(let version, let backup):
            String(localized: "Version \(version) didn't start. The old server.jar is back in place, the server stays stopped. The world from before the update is in “\(backup)”.")
        }
    }
}

/// Talks to Mojang's version manifest – the same source the download page on minecraft.net uses.
enum Updater {
    private struct Manifest: Decodable {
        struct Latest: Decodable { let release: String }
        struct Version: Decodable { let id: String; let url: URL }
        let latest: Latest
        let versions: [Version] // newest first
    }

    private struct Package: Decodable {
        struct File: Decodable { let sha1: String; let url: URL }
        struct Downloads: Decodable { let server: File? }
        struct Java: Decodable { let majorVersion: Int }
        let downloads: Downloads
        let javaVersion: Java?
    }

    /// "id" from the version.json inside server.jar, e.g. "26.3".
    static func installedVersion(in folder: URL) async -> String? {
        struct Info: Decodable { let id: String }
        let jar = folder.appendingPathComponent("server.jar").path
        guard let (status, output) = try? await WorldBackup.run("/usr/bin/unzip", ["-p", jar, "version.json"]), status == 0 else { return nil }
        return (try? JSONDecoder().decode(Info.self, from: Data(output.utf8)))?.id
    }

    /// The latest release if it's newer than `installed`, nil if `installed` is up to date (or a newer snapshot).
    static func newestRelease(after installed: String?) async throws -> Release? {
        let manifest = try JSONDecoder().decode(Manifest.self, from: try await fetch(URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!))
        let latest = manifest.latest.release
        guard latest != installed else { return nil }
        guard let installed, let installedIndex = manifest.versions.firstIndex(where: { $0.id == installed }) else {
            throw UpdateError.unknownVersion
        }
        guard let latestIndex = manifest.versions.firstIndex(where: { $0.id == latest }), latestIndex < installedIndex else { return nil }
        let package = try JSONDecoder().decode(Package.self, from: try await fetch(manifest.versions[latestIndex].url))
        guard let server = package.downloads.server else { throw UpdateError.network("no server download for \(latest)") }
        return Release(version: latest, url: server.url, sha1: server.sha1, java: package.javaVersion?.majorVersion ?? 0)
    }

    /// Downloads the jar to `target` and checks it against the SHA1 from the manifest.
    static func download(_ release: Release, to target: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(from: release.url)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network("HTTP \(status(response))") }
        let hash = Insecure.SHA1.hash(data: try Data(contentsOf: temp, options: .mappedIfSafe))
        guard hash.map({ String(format: "%02x", $0) }).joined() == release.sha1.lowercased() else { throw UpdateError.checksum }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
    }

    /// Major version of `java -version` ("1.8.0" → 8, "25.0.4.1" → 25).
    static func javaVersion(_ java: String) async -> Int? {
        guard let (_, output) = try? await WorldBackup.run(java, ["-version"]),
              let match = output.firstMatch(of: #/version "(\d+)(?:\.(\d+))?/#), let major = Int(match.1) else { return nil }
        return major == 1 ? match.2.flatMap { Int($0) } : major
    }

    private static func fetch(_ url: URL) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network("HTTP \(status(response))") }
            return data
        } catch let error as URLError {
            throw UpdateError.network(error.localizedDescription)
        }
    }

    private static func status(_ response: URLResponse) -> Int { (response as? HTTPURLResponse)?.statusCode ?? 0 }
}

/// Checks every night from `updateHour` on and installs a new version as soon as nobody is online:
/// download → stop → back up the world → swap server.jar → start again.
@MainActor
final class UpdateManager: ObservableObject {
    @Published private(set) var available: Release?
    @Published private(set) var installedVersion: String?
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    var onNotify: ((String, String) -> Void)?

    private let server: Server
    private let settings: Settings
    private var installWhenEmpty = false // found by the nightly check → installed without asking
    private var lastAttempt = Date.distantPast

    init(server: Server, settings: Settings) {
        self.server = server
        self.settings = settings
        Task { installedVersion = await Updater.installedVersion(in: settings.folder) }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Called every minute and after waking up.
    func tick() {
        guard settings.autoUpdate, !checking, !installing else { return }
        let slot = Calendar.current.date(bySettingHour: settings.updateHour, minute: 0, second: 0, of: .now)!
        if Date.now >= slot, (settings.lastUpdateCheck ?? .distantPast) < slot, lastAttempt < .now.addingTimeInterval(-1800) {
            lastAttempt = .now
            Task {
                if (try? await check()) != nil { installWhenEmpty = true }
                tick()
            }
            return
        }
        guard installWhenEmpty, let available, server.players.isEmpty, server.activity == nil,
              server.state != .external, server.state != .starting, server.state != .stopping else { return }
        Task { await install(available) }
    }

    /// Asks Mojang; returns (and remembers) a newer release, nil if up to date.
    @discardableResult
    func check() async throws -> Release? {
        checking = true
        defer { checking = false }
        installedVersion = await Updater.installedVersion(in: settings.folder)
        do {
            available = try await Updater.newestRelease(after: installedVersion)
            settings.lastUpdateCheck = .now
        } catch UpdateError.unknownVersion {
            settings.lastUpdateCheck = .now // asking again won't help
            throw UpdateError.unknownVersion
        }
        return available
    }

    func install(_ release: Release) async {
        guard !installing else { return }
        installing = true
        defer {
            installing = false
            server.activity = nil
            server.suppressRestart = false
        }
        let fm = FileManager.default
        let jar = settings.jar
        let download = settings.folder.appendingPathComponent("server.jar.download")
        let previous = settings.folder.appendingPathComponent("server.jar.previous")
        let old = await Updater.installedVersion(in: settings.folder) ?? server.version ?? "unknown"
        let wasRunning = server.acceptsCommands
        var startOldOnFailure = false
        installWhenEmpty = false // after a failure, the next night tries again instead of every minute

        do {
            guard server.state != .external else { throw UpdateError.external }
            if let java = await Updater.javaVersion(settings.java), java < release.java {
                throw UpdateError.java(needed: release.java, installed: java)
            }
            server.activity = String(localized: "Downloading \(release.version)…")
            try await Updater.download(release, to: download)

            if wasRunning {
                if !server.players.isEmpty {
                    server.say(String(localized: "The server restarts in 30 seconds for the update to \(release.version)."))
                    try? await Task.sleep(for: .seconds(30))
                }
                server.activity = String(localized: "Stopping server…")
                server.suppressRestart = true
                await server.stop()
                startOldOnFailure = true
            }

            server.activity = String(localized: "Backing up world…")
            let backup = try await WorldBackup.create(settings: settings, version: old)
            server.note(String(localized: "World backed up: \(backup.lastPathComponent)"))

            server.activity = String(localized: "Installing \(release.version)…")
            try? fm.removeItem(at: previous)
            try fm.moveItem(at: jar, to: previous)
            try fm.moveItem(at: download, to: jar)
            installedVersion = release.version
            startOldOnFailure = false

            if wasRunning {
                server.activity = String(localized: "Starting \(release.version)…")
                try server.start()
                guard await server.waitUntilRunning() else {
                    // back to the old jar, but not started: the world may already be half converted – the backup has the original
                    try? fm.removeItem(at: jar)
                    try? fm.moveItem(at: previous, to: jar)
                    installedVersion = old
                    throw UpdateError.startFailed(release.version, backup.lastPathComponent)
                }
            }
            try? fm.removeItem(at: previous)
            available = nil
            settings.lastUpdate = UpdateRecord(from: old, to: release.version, date: .now, backup: backup.lastPathComponent)
            settings.unseenUpdate = true
            server.note(String(localized: "Updated from \(old) to \(release.version)."))
            onNotify?(String(localized: "Minecraft server updated to \(release.version)"),
                      String(localized: "Previously \(old). The world was backed up to “\(backup.lastPathComponent)”."))
        } catch {
            try? fm.removeItem(at: download)
            if !fm.fileExists(atPath: jar.path), fm.fileExists(atPath: previous.path) { try? fm.moveItem(at: previous, to: jar) }
            if startOldOnFailure, server.state == .stopped { try? server.start() }
            installedVersion = await Updater.installedVersion(in: settings.folder)
            server.note(String(localized: "Update to \(release.version) failed: \(error.localizedDescription)"))
            onNotify?(String(localized: "Server update to \(release.version) failed"), error.localizedDescription)
        }
    }
}
