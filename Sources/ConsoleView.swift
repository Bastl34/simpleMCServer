import AppKit
import SwiftUI

struct ConsoleView: View {
    @ObservedObject var server: Server
    @ObservedObject var settings: Settings
    @Local private var input = ""
    @Local private var chatMode = false
    @Local private var chatOnly = false
    @Local private var history: [String] = []
    @Local private var historyIndex: Int?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                LogView(lines: server.log, chatOnly: chatOnly)
                Divider()
                inputBar
            }
            .frame(minWidth: 520)
            Sidebar(server: server)
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 380)
        }
        .frame(minWidth: 800, minHeight: 420)
        .onAppear { server.reloadLists() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(nsColor: server.statusColor)).frame(width: 10, height: 10)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: server.statusText).font(.headline)
                    if let record = settings.lastUpdate {
                        Text("Last update: \(record.from) → \(record.to), \(record.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Picker("Show", selection: $chatOnly) {
                Text("Full Log").tag(false)
                Text("Chat Only").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if server.hasProcess {
                Button("Restart", systemImage: "arrow.clockwise") { Task { try? await server.restart() } }
                    .disabled(server.state != .running || server.isBusy)
                Button("Stop", systemImage: "stop.fill") { Task { await server.stop() } }
                    .disabled(server.state == .stopping || server.activity != nil)
            } else {
                Button("Start", systemImage: "play.fill") {
                    do { try server.start() } catch {
                        showAlert(String(localized: "The server couldn't be started"), error.localizedDescription)
                    }
                }
                .disabled(server.state == .external || server.isBusy)
            }
        }
        .padding(10)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $chatMode) {
                Text("Command").tag(false)
                Text("Chat").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField(server.acceptsCommands ? (chatMode ? LocalizedStringKey("Message to everyone") : "Command, e.g. time set day")
                                             : "The server isn't running", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(submit)
                .onKeyPress(.upArrow) { browse(-1) }
                .onKeyPress(.downArrow) { browse(1) }
            Button("Send", action: submit)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .disabled(!server.acceptsCommands)
        .padding(10)
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, server.acceptsCommands else { return }
        if chatMode {
            server.say(text)
        } else {
            server.send(text.hasPrefix("/") ? String(text.dropFirst()) : text) // the console doesn't want the slash
        }
        if history.last != text { history.append(text) }
        historyIndex = nil
        input = ""
    }

    /// ↑/↓ go through the commands sent before.
    private func browse(_ step: Int) -> KeyPress.Result {
        guard !history.isEmpty else { return .ignored }
        let index = (historyIndex ?? history.count) + step
        if index >= history.count {
            historyIndex = nil
            input = ""
        } else {
            historyIndex = max(index, 0)
            input = history[historyIndex!]
        }
        return .handled
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var server: Server
    @Local private var newName = ""

    private var canEdit: Bool { server.state != .external && server.activity == nil }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Online (\(server.players.count))") {
                    ForEach(server.players) { player in
                        HStack {
                            let op = server.isOp(player.name)
                            Image(systemName: op ? "crown.fill" : "person.fill")
                                .foregroundStyle(op ? Color.yellow : Color.secondary)
                                .help(op ? Text("Operator") : Text("Player"))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: player.name)
                                Text("since \(player.since.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if server.acceptsCommands {
                                Menu { playerActions(player.name) } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                            }
                        }
                        .contextMenu { if server.acceptsCommands { playerActions(player.name) } }
                    }
                    if server.players.isEmpty {
                        Text("Nobody online").foregroundStyle(.secondary)
                    }
                }

                if !server.rejections.isEmpty {
                    Section("Refused") {
                        ForEach(server.rejections) { rejection in
                            HStack {
                                Image(systemName: "person.fill.xmark").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: rejection.name)
                                    Text("Not on the whitelist · \(rejection.date.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Add") { add(rejection.name) }
                                    .controlSize(.small)
                                    .disabled(!canEdit)
                                    .help("Add to the whitelist")
                                Button { server.dismiss(rejection) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .help("Dismiss")
                            }
                        }
                    }
                }

                Section {
                    ForEach(server.whitelist) { entry in
                        HStack {
                            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                            Text(verbatim: entry.name)
                            if server.isOp(entry.name) {
                                Image(systemName: "crown.fill").foregroundStyle(.yellow).help("Operator")
                            }
                            Spacer()
                            Button { remove(entry.name) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .disabled(!canEdit)
                                .help("Remove from the whitelist")
                        }
                    }
                    if server.whitelist.isEmpty {
                        Text("Nobody on the whitelist").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Whitelist")
                        Spacer()
                        Toggle("Whitelist active", isOn: Binding(get: { server.whitelistEnabled }, set: setWhitelist))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .disabled(!canEdit)
                            .help(server.whitelistEnabled ? Text("Only players on the whitelist can join.")
                                                          : Text("The whitelist is off – everyone can join."))
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                TextField("Add player to whitelist", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNew)
                Button(action: addNew) { Image(systemName: "plus") }
                    .disabled(!Server.isValidName(newName))
            }
            .disabled(!canEdit)
            .padding(8)
        }
    }

    @ViewBuilder
    private func playerActions(_ name: String) -> some View {
        Button("Send Message…") {
            if let text = prompt(String(localized: "Message to \(name)"), String(localized: "Only \(name) sees it (whispered)."),
                                 button: String(localized: "Send")) {
                server.tell(name, text)
            }
        }
        if server.isOp(name) {
            Button("Remove Operator") { server.setOp(name, false) }
        } else {
            Button("Make Operator") { server.setOp(name, true) }
        }
        Divider()
        Button("Kick") { server.kick(name) }
        if !server.whitelist.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            Button("Add to Whitelist") { add(name) }
        }
    }

    private func addNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard Server.isValidName(name) else { return }
        add(name)
        newName = ""
    }

    private func add(_ name: String) {
        Task {
            do { try await server.addToWhitelist(name) } catch {
                showAlert(String(localized: "\(name) couldn't be added to the whitelist"), error.localizedDescription)
            }
        }
    }

    private func remove(_ name: String) {
        do { try server.removeFromWhitelist(name) } catch {
            showAlert(String(localized: "\(name) couldn't be removed from the whitelist"), error.localizedDescription)
        }
    }

    private func setWhitelist(_ on: Bool) {
        do { try server.setWhitelistEnabled(on) } catch {
            showAlert(String(localized: "The whitelist couldn't be changed"), error.localizedDescription)
        }
    }
}

// MARK: - Log

/// The log as a text view: selectable, searchable with ⌘F, colored by kind, and it only appends new lines.
private struct LogView: NSViewRepresentable {
    let lines: [LogLine]
    let chatOnly: Bool

    final class Coordinator {
        var firstID: Int?
        var lastID: Int?
        var chatOnly: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        let atBottom = scrollView.contentView.bounds.maxY >= textView.frame.height - 40
        let rebuild = coordinator.chatOnly != chatOnly || coordinator.firstID != lines.first?.id

        let new = rebuild ? lines : lines.filter { $0.id > coordinator.lastID ?? Int.min }
        let text = NSMutableAttributedString()
        for line in new where !chatOnly || Self.isChat(line) {
            text.append(NSAttributedString(string: line.text + "\n", attributes: [.font: Self.font, .foregroundColor: Self.color(line.kind)]))
        }
        if rebuild {
            storage.setAttributedString(text)
        } else if text.length > 0 {
            storage.append(text)
        }
        coordinator.firstID = lines.first?.id
        coordinator.lastID = lines.last?.id
        coordinator.chatOnly = chatOnly
        if rebuild || (atBottom && text.length > 0) { textView.scrollToEndOfDocument(nil) }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private static func isChat(_ line: LogLine) -> Bool {
        line.kind == .chat || line.kind == .event || (line.kind == .input && line.text.hasPrefix("> say "))
    }

    private static func color(_ kind: LogLine.Kind) -> NSColor {
        switch kind {
        case .info: .labelColor
        case .warning: .systemOrange
        case .error: .systemRed
        case .chat: .systemGreen
        case .event: .systemTeal
        case .input: .systemBlue
        case .app: .secondaryLabelColor
        }
    }
}
