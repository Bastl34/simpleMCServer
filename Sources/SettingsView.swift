import ServiceManagement
import SwiftUI

/// `@State` is a macro in the current SDK, and its plugin only ships with Xcode. The alias uses the plain
/// property wrapper instead, so the app also builds with just the Command Line Tools.
typealias Local = SwiftUI.State

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var updates: UpdateManager
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Local private var javaVersion: Int?

    var body: some View {
        Form {
            Section {
                LabeledContent("Server folder") {
                    HStack {
                        Text(verbatim: (settings.serverFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(settings.serverFolder)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                LabeledContent("Java") {
                    HStack {
                        TextField("Java", text: $settings.java, prompt: Text(verbatim: "/usr/bin/java"))
                            .labelsHidden()
                        if let javaVersion {
                            Text(verbatim: "Java \(javaVersion)").foregroundStyle(.secondary)
                        }
                        let found = FileManager.default.isExecutableFile(atPath: settings.java)
                        Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(found ? .green : .red)
                            .help(found ? Text("Java found") : Text("Java not found"))
                    }
                }
                Stepper(value: $settings.memoryGB, in: 1...64) {
                    LabeledContent("Memory", value: "\(settings.memoryGB) GB")
                }
                TextField("Extra JVM arguments", text: $settings.jvmArguments, prompt: Text(verbatim: "-XX:+UseG1GC"))
                Toggle("Start the server when simpleMCServer launches", isOn: $settings.startServerAtLaunch)
                Toggle("Restart automatically after a crash", isOn: $settings.restartAfterCrash)
                Toggle("Launch simpleMCServer at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            } header: {
                Text("Server")
            } footer: {
                Text("Folder, Java and memory take effect at the next server start.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Install updates automatically", isOn: $settings.autoUpdate)
                Picker("Check every night from", selection: $settings.updateHour) {
                    ForEach(0..<24, id: \.self) { hour in Text(verbatim: String(format: "%02d:00", hour)).tag(hour) }
                }
                .disabled(!settings.autoUpdate)
                LabeledContent("Installed version", value: updates.installedVersion ?? "–")
                LabeledContent("Last check") {
                    if let date = settings.lastUpdateCheck {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never")
                    }
                }
                if let record = settings.lastUpdate {
                    LabeledContent("Last update") {
                        Text(verbatim: "\(record.from) → \(record.to), \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Asks Mojang for a new release every night. It's installed as soon as nobody is online: the server stops, the world is backed up, the new version starts. You'll get a notification, and the menu shows it for a week.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep", selection: $settings.backupsToKeep) {
                    ForEach([3, 5, 10, 20, 50], id: \.self) { count in Text("\(count) backups").tag(count) }
                    Text("All").tag(0)
                }
                LabeledContent("Folder") {
                    HStack {
                        Text(verbatim: (settings.backups.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: settings.backups, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(settings.backups)
                        }
                    }
                }
            } header: {
                Text("World Backups")
            } footer: {
                Text("Before every update, the world is zipped together with server.jar and server.properties, e.g. “\(settings.levelName)_26.3_2026-10-24_04-00.zip”. Only these backups are deleted automatically.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the number of players in the menu bar", isOn: $settings.showPlayerCount)
                Toggle("Notify when players join or leave", isOn: $settings.notifyJoins)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Refused players, crashes and updates are always notified.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 640)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled // may have been changed in System Settings
            checkJava()
        }
        .onChange(of: settings.java) { checkJava() }
    }

    private func checkJava() {
        let java = settings.java
        Task { javaVersion = FileManager.default.isExecutableFile(atPath: java) ? await Updater.javaVersion(java) : nil }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Which folder contains server.jar?")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = settings.folder
        if panel.runModal() == .OK, let url = panel.url { settings.serverFolder = url.path }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
