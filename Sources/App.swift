import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    static func main() {
        signal(SIGPIPE, SIG_IGN) // in case the server dies while we write a command to it
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let settings = Settings.shared
    private lazy var server = Server(settings: settings)
    private lazy var updates = UpdateManager(server: server, settings: settings)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private var consoleWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var observers: Set<AnyCancellable> = []
    private var poweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editMenu()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let whitelist = UNNotificationAction(identifier: "whitelist", title: String(localized: "Add to Whitelist"))
        center.setNotificationCategories([UNNotificationCategory(identifier: "rejected", actions: [whitelist], intentIdentifiers: [])])

        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.button?.setAccessibilityLabel("simpleMCServer")
        headerItem.isEnabled = false
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        server.onEvent = { [weak self] in self?.handle($0) }
        updates.onNotify = { [weak self] in self?.notify($0, $1) }
        Publishers.Merge3(server.objectWillChange, updates.objectWillChange, settings.objectWillChange)
            .receive(on: DispatchQueue.main) // after the change, and also while the menu is open
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
        Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(refresh), userInfo: nil, repeats: true) // uptime

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updates.tick() }
        }
        workspace.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poweringOff = true }
        }

        // into the login items once on the first launch from /Applications – after that the toggle in Settings decides
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            try? SMAppService.mainApp.register()
        }

        refresh()
        Task {
            await server.probe() // maybe it's already running in Terminal
            if settings.startServerAtLaunch, server.state == .stopped { startServer() }
            updates.tick()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updates.installing && !poweringOff {
            showAlert(String(localized: "An update is being installed"), String(localized: "Please wait until it's finished."))
            return .terminateCancel
        }
        guard server.hasProcess else { return .terminateNow }
        if !poweringOff {
            let alert = NSAlert()
            alert.messageText = String(localized: "The Minecraft server is running")
            alert.informativeText = String(localized: "Quitting stops the server – the world is saved first.")
            alert.addButton(withTitle: String(localized: "Stop Server and Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard run(alert) == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task {
            await server.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        settings.unseenUpdate = false
        menu.removeAllItems()
        menu.addItem(headerItem)

        if let record = settings.lastUpdate, record.date > .now.addingTimeInterval(-7 * 86400) {
            let item = menuItem(String(localized: "Updated to \(record.to)"), symbol: "arrow.up.circle", action: #selector(openBackups))
            let date = record.date.formatted(date: .abbreviated, time: .shortened)
            item.subtitle = String(localized: "\(date), before: \(record.from)\nWorld backup: \(record.backup)")
            menu.addItem(item)
        }
        if let release = updates.available {
            let item = menuItem(String(localized: "Install Update to \(release.version)…"), symbol: "arrow.down.circle", action: #selector(installUpdate))
            item.image = symbol("arrow.down.circle", color: .systemOrange)
            item.isEnabled = !updates.installing
            menu.addItem(item)
        }
        for rejection in server.rejections.prefix(5) {
            let item = menuItem(String(localized: "Add \(rejection.name) to Whitelist"), symbol: "person.badge.plus", action: #selector(addRejected(_:)))
            item.representedObject = rejection.name
            let time = rejection.date.formatted(date: .omitted, time: .shortened)
            item.subtitle = String(localized: "Was refused at \(time) – not on the whitelist")
            item.image = symbol("person.badge.plus", color: .systemOrange)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let running = server.state == .running || server.state == .external
        let playersItem = menuItem(String(localized: "Players (\(server.players.count))"), symbol: "person.2", action: nil)
        playersItem.isEnabled = running
        let playersMenu = NSMenu()
        playersMenu.autoenablesItems = false
        for player in server.players {
            let item = menuItem(player.name, symbol: server.isOp(player.name) ? "crown" : "person", action: nil)
            item.subtitle = String(localized: "Online since \(player.since.formatted(date: .omitted, time: .shortened))")
            if server.acceptsCommands {
                let actions = NSMenu()
                actions.autoenablesItems = false
                actions.addItem(playerItem(String(localized: "Send Message…"), "bubble.left", #selector(tellPlayer(_:)), player.name))
                actions.addItem(server.isOp(player.name)
                    ? playerItem(String(localized: "Remove Operator"), "crown", #selector(toggleOp(_:)), player.name)
                    : playerItem(String(localized: "Make Operator"), "crown", #selector(toggleOp(_:)), player.name))
                actions.addItem(playerItem(String(localized: "Kick"), "figure.walk.departure", #selector(kickPlayer(_:)), player.name))
                item.submenu = actions
            }
            playersMenu.addItem(item)
        }
        if server.players.isEmpty {
            let item = NSMenuItem(title: String(localized: "Nobody online"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            playersMenu.addItem(item)
        }
        playersItem.submenu = playersMenu
        menu.addItem(playersItem)
        menu.addItem(.separator())

        let busy = server.isBusy || updates.installing
        if server.hasProcess {
            let stop = menuItem(String(localized: "Stop Server"), symbol: "stop.circle", action: #selector(stopServer))
            stop.isEnabled = server.state != .stopping && !updates.installing
            let restart = menuItem(String(localized: "Restart Server"), symbol: "arrow.clockwise.circle", action: #selector(restartServer))
            restart.isEnabled = server.state == .running && !busy
            menu.addItem(stop)
            menu.addItem(restart)
        } else {
            let start = menuItem(String(localized: "Start Server"), symbol: "play.circle", action: #selector(startServer))
            start.isEnabled = server.state != .external && !busy
            if server.state == .external { start.toolTip = ServerError.external.localizedDescription }
            menu.addItem(start)
        }
        let message = menuItem(String(localized: "Message to Everyone…"), symbol: "megaphone", action: #selector(messageEveryone))
        message.isEnabled = server.acceptsCommands && server.state == .running
        menu.addItem(message)
        let backup = menuItem(String(localized: "Back Up World Now"), symbol: "archivebox", action: #selector(backupNow))
        backup.isEnabled = !busy && server.state != .external
        menu.addItem(backup)
        menu.addItem(menuItem(String(localized: "Console…"), symbol: "terminal", action: #selector(openConsole), key: "k"))
        menu.addItem(.separator())

        let check = menuItem(updates.checking ? String(localized: "Checking for Updates…") : String(localized: "Check for Updates…"),
                             symbol: "arrow.triangle.2.circlepath", action: #selector(checkForUpdates))
        check.isEnabled = !updates.checking && !updates.installing
        if let version = updates.installedVersion { check.subtitle = String(localized: "Installed: \(version)") }
        menu.addItem(check)
        menu.addItem(menuItem(String(localized: "Open Server Folder"), symbol: "folder", action: #selector(openServerFolder)))
        menu.addItem(menuItem(String(localized: "Open Backups"), symbol: "clock.arrow.circlepath", action: #selector(openBackups)))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Settings…"), symbol: "gearshape", action: #selector(openSettings), key: ","))
        menu.addItem(menuItem(String(localized: "About simpleMCServer"), symbol: "info.circle", action: #selector(showAbout)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = symbol("power")
        menu.addItem(quit)
        refresh()
    }

    /// Menu bar icon and the status line at the top of the menu (also while the menu is open).
    @objc private func refresh() {
        let text = server.statusText
        headerItem.title = text
        headerItem.image = symbol("circle.fill", size: 9, color: server.statusColor)
        guard let button = statusItem.button else { return }
        let badge: StatusIcon.Badge = switch server.state {
        case _ where server.activity != nil || updates.installing: .busy
        case .starting, .stopping: .busy
        case .running, .external: .running
        case .crashed: .failed
        case .stopped: .none
        }
        button.image = StatusIcon.image(badge, dot: settings.unseenUpdate)
        let count = server.players.count
        button.title = settings.showPlayerCount && count > 0 ? " \(count)" : ""
        button.toolTip = "simpleMCServer – \(text)"
    }

    // MARK: - Server

    @objc private func startServer() {
        do {
            try server.start()
        } catch {
            showAlert(String(localized: "The server couldn't be started"), error.localizedDescription)
        }
    }

    @objc private func stopServer() {
        Task { await server.stop() }
    }

    @objc private func restartServer() {
        Task {
            do { try await server.restart() } catch {
                showAlert(String(localized: "The server couldn't be started"), error.localizedDescription)
            }
        }
    }

    @objc private func messageEveryone() {
        guard let text = prompt(String(localized: "Message to Everyone"), String(localized: "Appears in the chat of all players as [Server]."),
                                button: String(localized: "Send")) else { return }
        server.say(text)
    }

    @objc private func tellPlayer(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let text = prompt(String(localized: "Message to \(name)"), String(localized: "Only \(name) sees it (whispered)."),
                                button: String(localized: "Send")) else { return }
        server.tell(name, text)
    }

    @objc private func toggleOp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        server.setOp(name, !server.isOp(name))
    }

    @objc private func kickPlayer(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        server.kick(name)
    }

    @objc private func addRejected(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        addToWhitelist(name)
    }

    private func addToWhitelist(_ name: String) {
        Task {
            do { try await server.addToWhitelist(name) } catch {
                showAlert(String(localized: "\(name) couldn't be added to the whitelist"), error.localizedDescription)
            }
        }
    }

    @objc private func backupNow() {
        Task {
            server.activity = String(localized: "Backing up world…")
            defer { server.activity = nil }
            do {
                let backup: URL
                if server.state == .running {
                    backup = try await WorldBackup.live(server, settings: settings)
                } else {
                    let version = await Updater.installedVersion(in: settings.folder) ?? "unknown"
                    backup = try await WorldBackup.create(settings: settings, version: version)
                }
                server.note(String(localized: "World backed up: \(backup.lastPathComponent)"))
                notify(String(localized: "World backed up"), backup.lastPathComponent)
            } catch {
                showAlert(String(localized: "The world couldn't be backed up"), error.localizedDescription)
            }
        }
    }

    // MARK: - Updates

    @objc private func checkForUpdates() {
        Task {
            do {
                if let release = try await updates.check() {
                    confirmUpdate(release)
                } else {
                    showAlert(String(localized: "The server is up to date"),
                              String(localized: "Version \(updates.installedVersion ?? "?") is the newest release."))
                }
            } catch {
                showAlert(String(localized: "Checking for updates failed"), error.localizedDescription)
            }
        }
    }

    @objc private func installUpdate() {
        if let release = updates.available { confirmUpdate(release) }
    }

    private func confirmUpdate(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Version \(release.version) is available")
        var text = String(localized: "Installed: \(updates.installedVersion ?? "?"). Before the update, the world is backed up together with the old server.jar.")
        if !server.players.isEmpty {
            text += "\n\n" + String(localized: "\(server.players.count) player(s) online will be warned in the chat and disconnected after 30 seconds.")
        }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Update Now"))
        alert.addButton(withTitle: settings.autoUpdate ? String(localized: "Tonight") : String(localized: "Later"))
        guard run(alert) == .alertFirstButtonReturn else { return }
        Task { await updates.install(release) }
    }

    // MARK: - Events & notifications

    private func handle(_ event: Server.Event) {
        switch event {
        case .started:
            break
        case .crashed(let restarting):
            notify(String(localized: "The Minecraft server crashed"),
                   restarting ? String(localized: "It restarts in 5 seconds.") : String(localized: "It stays stopped – details in the console."))
        case .joined(let name):
            guard settings.notifyJoins else { return }
            notify(String(localized: "\(name) joined the server"), onlineText())
        case .left(let name):
            guard settings.notifyJoins else { return }
            notify(String(localized: "\(name) left the server"), onlineText())
        case .rejected(let name):
            notify(String(localized: "\(name) isn't on the whitelist"),
                   String(localized: "The connection was refused. Add \(name) with the button or from the menu."),
                   category: "rejected", userInfo: ["name": name])
        }
    }

    private func onlineText() -> String {
        server.players.isEmpty ? String(localized: "Nobody online")
                               : String(localized: "Online: \(server.players.map(\.name).formatted(.list(type: .and)))")
    }

    private func notify(_ title: String, _ body: String, category: String? = nil, userInfo: [String: String] = [:]) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = userInfo
            if let category { content.categoryIdentifier = category }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound] // show it even while one of our windows is active
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let name = response.notification.request.content.userInfo["name"] as? String
        await MainActor.run {
            if action == "whitelist", let name {
                addToWhitelist(name)
            } else if action == UNNotificationDefaultActionIdentifier {
                openConsole()
            }
        }
    }

    // MARK: - Windows

    @objc private func openConsole() {
        if consoleWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ConsoleView(server: server, settings: settings)))
            window.title = String(localized: "simpleMCServer Console")
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 980, height: 620))
            window.center()
            window.setFrameAutosaveName("Console")
            consoleWindow = window
        }
        NSApp.activate()
        consoleWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, updates: updates)))
            window.title = String(localized: "simpleMCServer Settings")
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openServerFolder() {
        NSWorkspace.shared.open(settings.folder)
    }

    @objc private func openBackups() {
        try? FileManager.default.createDirectory(at: settings.backups, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.backups)
    }

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(string: String(localized: "Your Minecraft server in the menu bar."), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: - Helpers

    /// Menu item with an SF Symbol in front, so all items look the same on every macOS version.
    private func menuItem(_ title: String, symbol name: String, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = symbol(name)
        return item
    }

    private func playerItem(_ title: String, _ symbol: String, _ action: Selector, _ name: String) -> NSMenuItem {
        let item = menuItem(title, symbol: symbol, action: action)
        item.representedObject = name
        return item
    }

    /// SF Symbol; colored ones are not template images, so they keep their color.
    private func symbol(_ name: String, size: CGFloat? = nil, color: NSColor? = nil) -> NSImage? {
        var config = size.map { NSImage.SymbolConfiguration(pointSize: $0, weight: .regular) } ?? NSImage.SymbolConfiguration()
        if let color { config = config.applying(.init(paletteColors: [color])) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// Without a main menu, ⌘C/⌘V/⌘W don't work in our windows. It's never visible, so no localization needed.
    private func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let find = edit.addItem(withTitle: "Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }
}

// MARK: - Dialogs (also used by the console)

@MainActor
func prompt(_ title: String, _ text: String, button: String) -> String? {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.accessoryView = field
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.layout()
    alert.window.initialFirstResponder = field
    guard run(alert) == .alertFirstButtonReturn else { return nil }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

@MainActor
func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
    NSApp.activate()
    return alert.runModal()
}

@MainActor
func showAlert(_ title: String, _ text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    _ = run(alert)
}
