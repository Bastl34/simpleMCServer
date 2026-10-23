import Foundation

/// Zips the world together with the server.jar it was played with, e.g. "world_26.3_2026-10-24_04-00.zip":
/// unpack it and the world can be started (and updated) again with exactly that version.
@MainActor
enum WorldBackup {
    struct Failed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The server has to be stopped – or have saving switched off (see `live(_:settings:)`).
    static func create(settings: Settings, version: String) async throws -> URL {
        let fm = FileManager.default
        let folder = settings.folder
        let level = settings.levelName
        guard fm.fileExists(atPath: folder.appendingPathComponent(level).path) else {
            throw Failed(message: String(localized: "There is no world folder “\(level)” in “\(folder.path)”."))
        }
        try fm.createDirectory(at: settings.backups, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let base = "\(level)_\(version)_\(formatter.string(from: .now))".replacingOccurrences(of: "/", with: "-")
        var target = settings.backups.appendingPathComponent("\(base).zip")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = settings.backups.appendingPathComponent("\(base)-\(n).zip")
            n += 1
        }
        // written as .part first, so an aborted backup never looks like a finished one
        let temp = target.appendingPathExtension("part")
        try? fm.removeItem(at: temp)

        var items = [level, "server.jar", "server.properties"].filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        items += ["-x", "\(level)/session.lock"]
        let (status, output) = try await run("/usr/bin/zip", ["-r", "-q", "-X", temp.path] + items, in: folder)
        guard status == 0 else {
            try? fm.removeItem(at: temp)
            throw Failed(message: String(localized: "zip exited with code \(Int(status)).") + (output.isEmpty ? "" : "\n\n\(output)"))
        }
        try fm.moveItem(at: temp, to: target)
        prune(settings: settings)
        return target
    }

    /// Backup while the server keeps running: saving off, flush everything to disk, zip, saving back on.
    static func live(_ server: Server, settings: Settings) async throws -> URL {
        _ = await server.sendAndWait("save-off", seconds: 10) { $0.localizedCaseInsensitiveContains("saving") }
        defer { server.send("save-on") }
        guard await server.sendAndWait("save-all flush", seconds: 120, until: { $0.contains("Saved the game") }) else {
            throw Failed(message: String(localized: "The server didn't confirm saving the world."))
        }
        return try await create(settings: settings, version: server.version ?? "unknown")
    }

    /// Deletes the oldest of our own backups beyond the limit (other files in the folder are left alone).
    static func prune(settings: Settings) {
        let keep = settings.backupsToKeep
        guard keep > 0 else { return }
        let prefix = settings.levelName + "_"
        let files = (try? FileManager.default.contentsOfDirectory(at: settings.backups, includingPropertiesForKeys: nil)) ?? []
        // sorted by the date in the name ("2026-10-24_04-00", "-2" for a second one that minute), newest first
        let ours: [(url: URL, date: String)] = files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix),
                  let match = name.dropFirst(prefix.count).wholeMatch(of: #/.+_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2})(?:-(\d+))?\.zip/#)
            else { return nil }
            return (url, match.1 + String(format: "-%04d", Int(match.2 ?? "1") ?? 1))
        }
        for backup in ours.sorted(by: { $0.date > $1.date }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }

    /// Runs a tool in the background and returns its exit code and output.
    nonisolated static func run(_ tool: String, _ arguments: [String], in folder: URL? = nil) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
