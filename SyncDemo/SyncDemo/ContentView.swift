import SwiftUI

struct ContentView: View {
    /// App state, owned by SyncDemoApp — this view only borrows it.
    @Environment(SyncStore.self) private var store
    /// View state: the half-typed string belongs to this screen alone.
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            List {
                theString
                records
                status
                syncLog
            }
            .navigationTitle("Sync Demo")
            .toolbar {
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        store.refresh(reason: "refresh button")
                        Task { await store.checkAccount() }
                    }
                }
            }
        }
    }

    // MARK: The string

    private var theString: some View {
        Section {
            Text(store.current?.text.isEmpty == false ? store.current!.text : "— nothing yet —")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let current = store.current {
                Text("last set by \(current.author) · \(current.updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Type something", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save).buttonStyle(.borderedProminent)
                    .disabled(draft.isEmpty)
            }
            Button("Add a second record (make a duplicate on purpose)") {
                store.addRecord(draft.isEmpty ? "extra from \(store.device)" : draft)
            }
            .font(.callout)
        } header: {
            Text("The string")
        }
    }

    private func save() {
        guard !draft.isEmpty else { return }
        store.save(draft)
        draft = ""
    }

    // MARK: Records

    private var records: some View {
        Section {
            if store.rows.isEmpty {
                Text("No records on this device").foregroundStyle(.secondary)
            }
            ForEach(store.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.text).font(.body.weight(.medium))
                        Spacer()
                        Text(store.short(row.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text("\(row.author) · \(row.updatedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { store.delete(row) }
                }
                .contextMenu {
                    Button("Delete", role: .destructive) { store.delete(row) }
                }
            }
        } header: {
            HStack {
                Text("Records on this device: \(store.rows.count)")
                if store.rows.count > 1 {
                    Text("· more than one").foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Status

    private var status: some View {
        Section("iCloud") {
            LabeledContent("Device", value: store.device)
            LabeledContent("Account", value: store.accountStatus)
            LabeledContent("Container", value: SyncStore.containerID)
            LabeledContent("Environment", value: store.environment)
            LabeledContent("In flight") {
                Text(store.inFlight.isEmpty ? "idle" : store.inFlight.keys.sorted().joined(separator: ", "))
                    .foregroundStyle(store.inFlight.isEmpty ? Color.secondary : Color.orange)
            }
            if let url = store.storeURL {
                LabeledContent("Store", value: url.lastPathComponent)
            }
        }
    }

    // MARK: Log

    private var syncLog: some View {
        Section {
            ForEach(store.log) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.time.formatted(.dateTime.hour().minute().second()))
                        .foregroundStyle(.secondary)
                    Text(line.message).foregroundStyle(color(line.kind))
                }
                .font(.caption.monospaced())
            }
        } header: {
            HStack {
                Text("Sync log (newest first)")
                Spacer()
                Button("Clear") { store.clearLog() }.font(.caption)
            }
        } footer: {
            Text("Green: this device. Blue: CloudKit events. Purple: remote change and history (who wrote what). Red: failures.")
        }
    }

    private func color(_ kind: SyncStore.LogLine.Kind) -> Color {
        switch kind {
        case .local: .green
        case .event: .blue
        case .eventFailed, .error: .red
        case .remote, .history: .purple
        case .info: .primary
        }
    }
}
