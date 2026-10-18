import SwiftData
import SwiftUI

/// A CSV arriving: say which source it is (or set up a new one), merge in what's
/// new, and report what happened.
struct ImportFlow: View {
    let file: IncomingFile
    let finished: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Source.name) private var sources: [Source]
    @State private var summary: ImportSummary?
    @State private var problem: String?
    @State private var settingUp = false

    private var table: CSVTable? {
        guard let data = file.contents else { return nil }
        let table = CSVTable(text: String(decoding: data, as: UTF8.self))
        return table.header.isEmpty ? nil : table
    }

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    result(summary)
                } else if let table, sources.isEmpty {
                    // The first import has only one answer to "which account?".
                    MappingScreen(table: table) { source in run(into: source) }
                } else if let table {
                    choose(table)
                } else {
                    ContentUnavailableView("Can't read this file", systemImage: "doc.questionmark",
                                           description: Text("\(file.name) doesn't look like a CSV with a header row."))
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if summary == nil {
                        Button("Cancel") { Telemetry.shared.log("import-cancelled"); dismiss() }
                    }
                }
            }
            .navigationDestination(isPresented: $settingUp) {
                if let table {
                    MappingScreen(table: table) { source in
                        settingUp = false
                        run(into: source)
                    }
                }
            }
            .alert("Couldn't import", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
            .screen("import")
        }
        .onAppear {
            Telemetry.shared.log("import-opened", ["columns": "\(table?.header.count ?? 0)", "rows": "\(table?.rows.count ?? 0)",
                                                   "header": table?.header.joined(separator: " | ") ?? "",
                                                   "sources": "\(sources.count)"])
        }
    }

    private func choose(_ table: CSVTable) -> some View {
        let matching = sources.filter { $0.header == table.header }
        let others = sources.filter { $0.header != table.header }
        return List {
            Section {
                Text("Which account is this from?")
                    .foregroundStyle(.secondary)
            }
            if !matching.isEmpty {
                Section("Matches this file") {
                    ForEach(matching) { source in
                        Button {
                            Telemetry.shared.log("source-chosen", ["name": source.name])
                            run(into: source)
                        } label: {
                            LabeledContent(source.name, value: "\(source.files.count) earlier file\(source.files.count == 1 ? "" : "s")")
                        }
                    }
                }
            }
            Section {
                Button("New source…") {
                    Telemetry.shared.log("button", ["name": "new-source"])
                    settingUp = true
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { source in
                        Text(source.name).foregroundStyle(.secondary)
                    }
                } header: { Text("Different columns") } footer: {
                    Text("These sources expect other columns. If your bank changed its export, set up a new source for it.")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilePeek(table: table) { CSVGrid(table: table, rows: 12) }
        }
    }

    private func result(_ s: ImportSummary) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text(s.new == 0 ? "Nothing new" : "\(s.new) new to review").font(.title2.weight(.semibold))
            VStack(spacing: 4) {
                if s.alreadyHere > 0 { Text("\(s.alreadyHere) already here, skipped") }
                if s.unreadable > 0 { Text("\(s.unreadable) rows couldn't be read") }
            }
            .foregroundStyle(.secondary)
            Button(s.new == 0 ? "Done" : "Start reviewing") {
                Telemetry.shared.log("button", ["name": "import-done"])
                finished()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    private func run(into source: Source) {
        guard let data = file.contents else { return }
        do {
            summary = try context.importFile(named: file.name, contents: data, into: source)
            Telemetry.shared.log("imported", ["source": source.name, "new": "\(summary!.new)",
                                              "already": "\(summary!.alreadyHere)", "unreadable": "\(summary!.unreadable)"])
        } catch {
            problem = error.localizedDescription
            Telemetry.shared.log("import-failed", ["why": error.localizedDescription])
        }
    }
}

/// Telling Risu how a new source's columns read, with the first rows shown
/// as they'd come out, so a wrong guess is visible before anything is stored.
struct MappingScreen: View {
    let table: CSVTable
    let created: (Source) -> Void
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var mapping: ColumnMapping
    @State private var problem: String?

    init(table: CSVTable, created: @escaping (Source) -> Void) {
        self.table = table
        self.created = created
        _mapping = State(initialValue: MappingGuess.guess(table)
            ?? ColumnMapping(date: 0, description: min(1, table.header.count - 1),
                             amount: .single(column: min(2, table.header.count - 1), moneyInIsPositive: true),
                             dateLayout: .monthDayYear))
    }

    private var split: Bool {
        if case .split = mapping.amount { return true }
        return false
    }

    /// What each column is used for, for the grid's labels.
    private var roles: [Int: String] {
        var roles: [Int: String] = [mapping.date: "Date", mapping.description: "Description"]
        switch mapping.amount {
        case .single(let c, _): roles[c] = "Amount"
        case .split(let o, let i): roles[o] = "Money out"; roles[i] = "Money in"
        }
        return roles
    }

    private var roleChoices: [String] {
        split ? ["Date", "Description", "Money out", "Money in"] : ["Date", "Description", "Amount"]
    }

    private func assign(_ column: Int, _ role: String) {
        switch role {
        case "Date":
            mapping.date = column
            let values = table.rows.prefix(50).map { column < $0.count ? $0[column] : "" }
            if let layout = DateLayout.fitting(values).first { mapping.dateLayout = layout }
        case "Description": mapping.description = column
        case "Amount":
            if case .single(_, let inPositive) = mapping.amount { mapping.amount = .single(column: column, moneyInIsPositive: inPositive) }
        case "Money out":
            if case .split(_, let i) = mapping.amount { mapping.amount = .split(moneyOut: column, moneyIn: i) }
        case "Money in":
            if case .split(let o, _) = mapping.amount { mapping.amount = .split(moneyOut: o, moneyIn: column) }
        default: break
        }
        Telemetry.shared.log("mapping-assign", ["role": role, "column": table.header[column], "via": "grid"])
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Chase Sapphire", text: $name)
            }
            Section("Columns") {
                column("Date", $mapping.date)
                Picker("Date order", selection: $mapping.dateLayout) {
                    ForEach(DateLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                column("Description", $mapping.description)
                Toggle("Money in and out are separate columns", isOn: Binding(
                    get: { split },
                    set: { on in
                        mapping.amount = on ? .split(moneyOut: amountColumns.0, moneyIn: amountColumns.1)
                                            : .single(column: amountColumns.0, moneyInIsPositive: true)
                        Telemetry.shared.log("mapping-split", ["on": "\(on)"])
                    }))
                if case .single(let c, let inPositive) = mapping.amount {
                    column("Amount", Binding(get: { c }, set: { mapping.amount = .single(column: $0, moneyInIsPositive: inPositive) }))
                    Picker("A purchase shows as", selection: Binding(
                        get: { inPositive },
                        set: { mapping.amount = .single(column: c, moneyInIsPositive: $0) })) {
                        Text("Negative").tag(true)
                        Text("Positive").tag(false)
                    }
                }
                if case .split(let out, let into) = mapping.amount {
                    column("Money out", Binding(get: { out }, set: { mapping.amount = .split(moneyOut: $0, moneyIn: into) }))
                    column("Money in", Binding(get: { into }, set: { mapping.amount = .split(moneyOut: out, moneyIn: $0) }))
                }
            }
            Section("First rows, as they'll import") {
                ForEach(Array(table.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                    switch mapping.read(row) {
                    case .success(let parsed):
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading) {
                                Text(parsed.text).lineLimit(1)
                                Text(parsed.day.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((parsed.amountCents < 0 ? "−" : "+") + Money.text(parsed.amountCents))
                                .monospacedDigit()
                                .foregroundStyle(parsed.amountCents < 0 ? Color.primary : Color.green)
                        }
                    case .failure(let why):
                        Label(describe(why), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilePeek(table: table, hint: "Tap a column's name to use it for the date, description or amount.") {
                CSVGrid(table: table, roles: roles, choices: roleChoices, assign: assign)
            }
        }
        .navigationTitle("New source")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .alert("Couldn't save", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .screen("mapping")
        .onChange(of: mapping) { _, _ in
            Telemetry.shared.log("mapping-changed", roles.sorted { $0.key < $1.key }
                .reduce(into: [:]) { $0[$1.value] = table.header[$1.key] })
        }
    }

    private var amountColumns: (Int, Int) {
        switch mapping.amount {
        case .single(let c, _): (c, min(c + 1, table.header.count - 1))
        case .split(let o, let i): (o, i)
        }
    }

    private func column(_ title: String, _ selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(table.header.indices, id: \.self) { i in
                Text(table.header[i].isEmpty ? "Column \(i + 1)" : table.header[i]).tag(i)
            }
        }
    }

    private func describe(_ problem: RowProblem) -> String {
        switch problem {
        case .date(let v): "“\(v)” isn't a date in this order"
        case .amount(let v): "“\(v)” isn't an amount"
        }
    }

    private func save() {
        do {
            let source = try context.addSource(name: name, header: table.header, mapping: mapping)
            Telemetry.shared.log("source-created", ["name": source.name])
            created(source)
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The file, pinned above a screen's controls, edge to edge.
struct FilePeek<Grid: View>: View {
    let table: CSVTable
    var hint: String?
    @ViewBuilder let grid: Grid

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your file · \(table.rows.count) rows")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            grid.frame(height: 200)
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .background(.bar)
    }
}
