import Charts
import SwiftData
import SwiftUI

/// Everything imported, newest first, to look over or fix.
struct TransactionsScreen: View {
    @Query(sort: [SortDescriptor(\LedgerEntry.dayKey, order: .reverse), SortDescriptor(\LedgerEntry.row)])
    private var entries: [LedgerEntry]
    @State private var editing: LedgerEntry?
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all, unlabelledTransfers
        var id: String { rawValue }
        var title: String { self == .all ? "All transactions" : "Transfers without a label" }
    }

    private var shown: [LedgerEntry] {
        switch filter {
        case .all: entries
        case .unlabelledTransfers: entries.filter { $0.kind == .transfer && $0.category == nil }
        }
    }

    private var months: [(key: String, entries: [LedgerEntry])] {
        Dictionary(grouping: shown, by: { $0.day.monthKey })
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(months, id: \.key) { month in
                    Section(monthTitle(month.key)) {
                        ForEach(month.entries) { entry in
                            Button { editing = entry; Telemetry.shared.log("open-transaction", ["reviewed": "\(entry.isReviewed)"]) } label: {
                                EntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No transactions", systemImage: "list.bullet",
                                           description: Text("Import a CSV from the Review tab."))
                } else if shown.isEmpty {
                    ContentUnavailableView("Every transfer has a label", systemImage: "checkmark.circle",
                                           description: Text("Transfers you mark without one will be listed here."))
                }
            }
            .navigationTitle(filter == .all ? "Transactions" : "Unlabelled transfers")
            .navigationBarTitleDisplayMode(filter == .all ? .automatic : .inline)
            .toolbar {
                Menu("Show", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .onChange(of: filter) { _, new in Telemetry.shared.log("transactions-filter", ["to": new.rawValue]) }
            .sheet(item: $editing) { EditEntrySheet(entry: $0) }
            .screen("transactions")
        }
    }
}

struct EntryRow: View {
    let entry: LedgerEntry
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(entry.isReviewed ? Color.secondary : Color.orange)
            }
            Spacer()
            Text((entry.amountCents < 0 ? "−" : "+") + Money.text(entry.amountCents))
                .monospacedDigit()
                .foregroundStyle(entry.amountCents < 0 ? Color.primary : Color.green)
        }
        .contentShape(Rectangle())
    }

    private var caption: String {
        let day = entry.day.title
        guard let kind = entry.kind else { return "\(day) · To review" }
        if kind == .transfer { return "\(day) · Transfer" + (entry.category.map { ": \($0.name)" } ?? "") }
        let refund = entry.sign < 0 ? " (refund)" : ""
        if entry.isSplit {
            // A receipt's eight items might be three categories; name each once.
            var names: [String] = []
            for name in entry.parts.sorted(by: { $0.order < $1.order }).compactMap({ $0.category?.name }) where !names.contains(name) {
                names.append(name)
            }
            return "\(day) · Split: \(names.joined(separator: ", "))\(refund)"
        }
        return "\(day) · \(entry.category?.name ?? kind.title)\(refund)"
    }
}

struct EditEntrySheet: View {
    let entry: LedgerEntry
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind
    @State private var sign: Int
    @State private var category: Category?
    @State private var split: [SplitDraft]
    @State private var receipt: ReceiptFile?
    @State private var problem: String?

    init(entry: LedgerEntry) {
        self.entry = entry
        _kind = State(initialValue: entry.kind ?? (entry.amountCents < 0 ? .expense : .income))
        _sign = State(initialValue: entry.sign)
        _category = State(initialValue: entry.category)
        _split = State(initialValue: .from(entry))
        _receipt = State(initialValue: entry.receipt?.file)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).font(.title3.weight(.semibold))
                        Text("\(entry.day.title) · \(entry.amountCents < 0 ? "−" : "+")\(Money.text(entry.amountCents))")
                            .foregroundStyle(.secondary)
                    }
                    DecisionControls(kind: $kind, sign: $sign, category: $category, split: $split,
                                     receipt: $receipt, total: abs(entry.amountCents))
                }
                .padding(20)
            }
            .navigationTitle(entry.isReviewed ? "Edit" : "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try context.record(entry, kind: kind, sign: sign, category: category, split: split, receipt: receipt)
                            Telemetry.shared.log("edited", ["kind": kind.rawValue, "parts": "\(max(split.count, 1))",
                                                            "receipt": "\(receipt != nil)"])
                            dismiss()
                        } catch { problem = error.localizedDescription }
                    }
                    .disabled(!decisionIsComplete(kind: kind, category: category, split: split, total: abs(entry.amountCents)))
                }
            }
            .alert("Can't save that", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
            .screen("edit-transaction")
        }
    }
}

/// Both lists, how much each is used, and renaming or removing.
struct CategoriesScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.name) private var all: [Category]
    @State private var renaming: Category?
    @State private var newName = ""
    @State private var adding: CategoryKind?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(CategoryKind.allCases) { side in
                    Section {
                        ForEach(context.categories(side)) { category in
                            NavigationLink(value: category) {
                                LabeledContent(category.name, value: "\(category.uses)")
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    do { try context.remove(category); Telemetry.shared.log("category-deleted") }
                                    catch { problem = error.localizedDescription }
                                }
                                Button("Rename") { rename(category) }
                            }
                        }
                        Button("Add \(side.title.lowercased()) category") { newName = ""; adding = side }
                    } header: { Text(side.title) }
                }
            }
            .navigationTitle("Categories")
            .navigationDestination(for: Category.self) { category in
                CategoryTransactions(category: category) { rename(category) }
            }
            .alert("Rename", isPresented: .constant(renaming != nil)) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let renaming {
                        do { try context.rename(renaming, to: newName); Telemetry.shared.log("category-renamed") }
                        catch { problem = error.localizedDescription }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("New category", isPresented: .constant(adding != nil)) {
                TextField("Name", text: $newName)
                Button("Add") {
                    if let adding {
                        do { _ = try context.category(named: newName, kind: adding); Telemetry.shared.log("category-added", ["kind": adding.rawValue]) }
                        catch { problem = error.localizedDescription }
                    }
                    adding = nil
                }
                Button("Cancel", role: .cancel) { adding = nil }
            }
            .alert("Can't do that", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
            .screen("categories")
        }
    }

    private func rename(_ category: Category) {
        newName = category.name
        renaming = category
    }
}

/// The transactions, and pieces of split ones, filed under one category.
struct CategoryTransactions: View {
    let category: Category
    let rename: () -> Void
    @State private var editing: LedgerEntry?

    var body: some View {
        let lines = category.lines
        let months = Dictionary(grouping: lines, by: { $0.entry.day.monthKey }).sorted { $0.key > $1.key }
        List {
            ForEach(months, id: \.key) { month in
                Section {
                    ForEach(month.value) { line in
                        Button {
                            editing = line.entry
                            Telemetry.shared.log("open-transaction", ["from": "category"])
                        } label: { row(line) }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(monthTitle(month.key))
                        Spacer()
                        Text(amount(month.value.reduce(0) { $0 + $1.cents })).monospacedDigit()
                    }
                }
            }
        }
        .overlay {
            if lines.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "tray",
                                       description: Text("Transactions you file under \(category.name) will be listed here."))
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Rename", action: rename) }
        .sheet(item: $editing) { EditEntrySheet(entry: $0) }
        .screen("category-transactions")
    }

    private func row(_ line: Category.Line) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.entry.text).lineLimit(1)
                Text(caption(line)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(amount(line.cents)).monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    private func caption(_ line: Category.Line) -> String {
        var text = line.entry.day.title
        if let part = line.part {
            text += part.label.isEmpty ? " · Part of \(Money.text(line.entry.amountCents))"
                                       : " · \(part.label), part of \(Money.text(line.entry.amountCents))"
        }
        if category.kind != .transfer, line.entry.sign < 0 { text += " · Refund" }
        return text
    }

    /// A transfer shows which way it went; anything else is plain unless it takes away.
    private func amount(_ cents: Int) -> String {
        let sign = cents < 0 ? "−" : category.kind == .transfer && cents > 0 ? "+" : ""
        return sign + Money.text(cents)
    }
}

/// Telemetry, and where it goes.
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preparing = false
    @State private var exported: ExportedLog?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    // A plain button, not a ShareLink: it shows the press at once,
                    // where a ShareLink sat still until the share sheet was ready.
                    Button {
                        Telemetry.shared.log("export-log")
                        preparing = true
                        Task {
                            exported = ExportedLog(url: await Telemetry.exportAll())
                            preparing = false
                        }
                    } label: {
                        HStack {
                            Label(preparing ? "Preparing…" : "Export the usage log", systemImage: "square.and.arrow.up")
                            if preparing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(preparing)
                } header: { Text("Usage log") } footer: {
                    Text("Records screens, taps and choices, never a transaction's description or amount. It stays on this phone unless you export it.")
                }
                Section {
                    LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $exported) { ShareSheet(items: [$0.url]).presentationDetents([.medium, .large]) }
            .screen("settings")
        }
    }
}

struct ExportedLog: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet, opened when we choose rather than when a
/// ShareLink is tapped.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

func monthTitle(_ key: String) -> String {
    guard let day = Day(key: key + "-01") else { return key }
    var c = DateComponents(); c.year = day.year; c.month = day.month; c.day = 1
    let date = Calendar(identifier: .gregorian).date(from: c) ?? .now
    return date.formatted(.dateTime.month(.wide).year())
}
