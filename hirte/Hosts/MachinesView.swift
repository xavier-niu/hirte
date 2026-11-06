import HerdrKit
import SwiftUI

/// The saved machines: add, edit, delete, keys. The sidebar's root while there are none (with the
/// first-run empty state), and the "Manage Machines" sheet otherwise.
struct MachinesView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    let sessions: SessionStore
    @Binding var selection: Host.ID?
    /// Shown as a sheet: picking a machine closes it, and there's a Done button.
    var inSheet = false
    @State private var editing: Host?
    @State private var showingKeys = false
    @State private var showingSettings = false

    var body: some View {
        List {
            if hosts.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No machines", systemImage: "server.rack")
                } description: {
                    Text(keys.keys.isEmpty
                        ? "Create an SSH key first, add it to your machine, then add the machine here."
                        : "Add a machine that runs herdr-core.")
                } actions: {
                    if keys.keys.isEmpty {
                        Button("Create Key") { showingKeys = true }
                    } else {
                        Button("Add Machine") { editing = newHost() }
                    }
                    Button("Try the Demo") { addDemo() }
                        .buttonStyle(.borderless)
                }
            }
            ForEach(hosts.hosts) { host in
                Button {
                    selection = host.id
                    if inSheet { dismiss() }
                } label: {
                    HStack {
                        MachineRow(host: host, session: sessions.existing(host.id))
                        if host.id == selection {
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .contextMenu {
                    if !host.isDemo {
                        Button("Edit", systemImage: "pencil") { editing = host }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        if let index = hosts.hosts.firstIndex(of: host) { hosts.delete(at: [index]) }
                    }
                }
                .swipeActions(edge: .leading) {
                    if !host.isDemo {
                        Button("Edit", systemImage: "pencil") { editing = host }.tint(.blue)
                    }
                }
            }
            .onDelete { hosts.delete(at: $0) }
        }
        .navigationTitle("Machines")
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Keys", systemImage: "key") { showingKeys = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add Machine", systemImage: "server.rack") { editing = newHost() }
                    if !hosts.hasDemo {
                        Button("Add Demo Machine", systemImage: "play.rectangle") { addDemo() }
                    }
                } label: {
                    Label("Add Machine", systemImage: "plus")
                } primaryAction: {
                    editing = newHost()
                }
            }
        }
        .sheet(item: $editing) { host in
            HostEditor(host: host)
        }
        .sheet(isPresented: $showingKeys) {
            KeysSheet { showingKeys = false }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(addDemo: { showingSettings = false; addDemo() }) { showingSettings = false }
        }
    }

    private func addDemo() {
        selection = hosts.addDemo().id
        if inSheet { dismiss() }
    }

    private func newHost() -> Host {
        Host.new(key: keys.keys.last?.id)
    }
}

extension Host {
    /// An empty machine for the editor, with the newest key preselected.
    static func new(key: UUID?) -> Host {
        Host(name: "", target: SSHTarget(host: "", username: ""), keyID: key)
    }
}

struct KeysSheet: View {
    let done: () -> Void

    var body: some View {
        NavigationStack {
            KeysView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: done)
                    }
                }
        }
    }
}

struct SettingsSheet: View {
    let addDemo: () -> Void
    let done: () -> Void

    var body: some View {
        NavigationStack {
            SettingsView(addDemo: addDemo)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: done)
                    }
                }
        }
    }
}

struct MachineRow: View {
    let host: Host
    let session: HostSession?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                Text(host.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let session {
                if session.needsYouCount > 0 {
                    NeedsYouBadge(count: session.needsYouCount)
                }
                ConnectionIndicator(state: session.state)
            }
        }
    }
}

struct ConnectionIndicator: View {
    let state: HostSession.State

    var body: some View {
        switch state {
        case .idle: EmptyView()
        case .connecting: ProgressView().controlSize(.small)
        case .connected:
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
                .accessibilityLabel("Connected")
        case .failed(_, let retrying):
            Image(systemName: retrying ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(retrying ? Color.secondary : Color.orange)
                .accessibilityLabel(retrying ? "Reconnecting" : "Not connected")
        }
    }
}

struct HostEditor: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    @State var host: Host
    @State private var port = ""
    @State private var session = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $host.name, prompt: Text(host.target.host.isEmpty ? "My server" : host.target.host))
                }
                Section("SSH") {
                    TextField("Host", text: $host.target.host, prompt: Text("server.example.com"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                    TextField("User", text: $host.target.username, prompt: Text("me"))
                        .textContentType(.username)
                    TextField("Port", text: $port, prompt: Text("22"))
                        .keyboardType(.numberPad)
                    Picker("Key", selection: $host.keyID) {
                        Text("None").tag(UUID?.none)
                        ForEach(keys.keys) { key in
                            Text(key.label).tag(Optional(key.id))
                        }
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section {
                    TextField("Session", text: $session, prompt: Text("default"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("herdr-core")
                } footer: {
                    Text("Leave empty for the default session. herdr-core must be on PATH or in ~/.local/bin on the machine. If it isn't, Hirte offers to install it.")
                }
            }
            .navigationTitle(hosts.hosts.contains { $0.id == host.id } ? "Edit Machine" : "Add Machine")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                port = host.target.port == 22 ? "" : String(host.target.port)
                session = host.session ?? ""
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        host.target.host = host.target.host.trimmingCharacters(in: .whitespaces)
                        host.target.username = host.target.username.trimmingCharacters(in: .whitespaces)
                        host.target.port = Int(port) ?? 22
                        host.session = session.isEmpty ? nil : session
                        if host.name.trimmingCharacters(in: .whitespaces).isEmpty { host.name = host.target.host }
                        hosts.save(host)
                        dismiss()
                    }
                    .disabled(host.target.host.isEmpty || host.target.username.isEmpty || host.keyID == nil)
                }
            }
        }
    }
}
