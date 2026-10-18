import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// One new row at a time: what it was, which way it counts, which category.
struct ReviewScreen: View {
    @Binding var importFile: IncomingFile?
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<LedgerEntry> { $0.kindRaw == nil }) private var waiting: [LedgerEntry]
    @State private var picking = false
    @State private var showingSettings = false

    private var current: LedgerEntry? { context.reviewQueue().first }

    var body: some View {
        NavigationStack {
            Group {
                if let entry = current {
                    ReviewCard(entry: entry, remaining: waiting.count)
                        .id(entry.persistentModelID)
                } else {
                    ContentUnavailableView {
                        Label("Nothing to review", systemImage: "checkmark.circle")
                    } description: {
                        Text("Import a CSV from your bank. Its new rows show up here one at a time.")
                    } actions: {
                        Button("Import CSV") { open() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(waiting.isEmpty ? "Review" : "Review · \(waiting.count) left")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import CSV", systemImage: "square.and.arrow.down") { open() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") {
                        Telemetry.shared.log("button", ["name": "settings"])
                        showingSettings = true
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                switch result {
                case .success(let url):
                    Telemetry.shared.log("file-picked")
                    importFile = IncomingFile(url: url)
                case .failure:
                    Telemetry.shared.log("file-pick-cancelled")
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsScreen() }
            .screen("review")
        }
    }

    private func open() {
        Telemetry.shared.log("button", ["name": "import-csv"])
        picking = true
    }
}

/// The decision for one row. Kind and sign start from the bank's sign; the
/// category is a chip, most-used first, or a new one.
struct ReviewCard: View {
    let entry: LedgerEntry
    let remaining: Int
    @Environment(\.modelContext) private var context
    @State private var kind: Kind
    @State private var sign: Int
    @State private var category: Category?
    @State private var addingCategory = false
    @State private var newName = ""
    @State private var problem: String?
    @State private var shown = Date.now

    init(entry: LedgerEntry, remaining: Int) {
        self.entry = entry
        self.remaining = remaining
        _kind = State(initialValue: entry.kind ?? (entry.amountCents < 0 ? .expense : .income))
        _sign = State(initialValue: entry.kind == nil ? 1 : entry.sign)
        _category = State(initialValue: entry.category)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary
                    DecisionControls(kind: $kind, sign: $sign, category: $category,
                                     addingCategory: $addingCategory)
                }
                .padding(20)
            }
            nextButton
        }
        .alert("New \(kind.categoryKind?.title.lowercased() ?? "") category", isPresented: $addingCategory) {
            TextField("Name", text: $newName)
            Button("Add") { addCategory() }
            Button("Cancel", role: .cancel) { newName = ""; Telemetry.shared.log("new-category-cancelled") }
        }
        .alert("Can't save that", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .onAppear {
            shown = .now
            Telemetry.shared.log("card", ["remaining": "\(remaining)", "suggested": kind.rawValue,
                                          "source": entry.file?.source?.name ?? "?", "row": "\(entry.row)"])
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.file?.source?.name ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text(entry.text.isEmpty ? "No description" : entry.text)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(entry.day.title).foregroundStyle(.secondary)
                Spacer()
                Text((entry.amountCents < 0 ? "−" : "+") + Money.text(entry.amountCents))
                    .font(.title.weight(.bold).monospacedDigit())
                    .foregroundStyle(entry.amountCents < 0 ? Color.primary : Color.green)
            }
            Text(entry.amountCents < 0 ? "Money out" : "Money in")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var nextButton: some View {
        Button(action: save) {
            Text(remaining > 1 ? "Save and next" : "Save")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .disabled(kind != .transfer && category == nil)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func addCategory() {
        guard let side = kind.categoryKind else { return }
        do {
            category = try context.category(named: newName, kind: side)
            Telemetry.shared.log("new-category", ["name": category?.name ?? "", "kind": side.rawValue])
        } catch {
            problem = error.localizedDescription
        }
        newName = ""
    }

    private func save() {
        do {
            try context.decide(entry, kind: kind, sign: sign, category: category)
            Telemetry.shared.log("decided", [
                "kind": kind.rawValue, "sign": sign > 0 ? "adds" : "subtracts",
                "category": category?.name ?? "",
                "seconds": String(format: "%.1f", Date.now.timeIntervalSince(shown)),
                "remaining": "\(remaining - 1)",
            ])
        } catch {
            problem = error.localizedDescription
            Telemetry.shared.log("decide-failed", ["why": error.localizedDescription])
        }
    }
}

/// Kind, sign and category: the same controls in the review and when fixing a
/// transaction later.
struct DecisionControls: View {
    @Binding var kind: Kind
    @Binding var sign: Int
    @Binding var category: Category?
    @Binding var addingCategory: Bool
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Label("What is it?", systemImage: "questionmark.circle").font(.headline).labelStyle(.titleOnly)
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .onChange(of: kind) { old, new in
                    // The chip picked belongs to the other list.
                    if category?.kind != new.categoryKind { category = nil }
                    Telemetry.shared.log("kind", ["from": old.rawValue, "to": new.rawValue])
                }
            }

            if kind != .transfer {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Counts as").font(.headline)
                    Picker("Counts as", selection: $sign) {
                        Text(kind == .income ? "Income" : "Spending").tag(1)
                        Text(kind == .income ? "Taking back income" : "Refund").tag(-1)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sign) { _, new in Telemetry.shared.log("sign", ["to": new > 0 ? "adds" : "subtracts"]) }
                }

                if let side = kind.categoryKind {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Category").font(.headline)
                        ChipFlow(spacing: 8) {
                            ForEach(context.categories(side)) { chip in
                                Chip(title: chip.name, selected: chip === category) {
                                    category = chip
                                    Telemetry.shared.log("chip", ["name": chip.name])
                                }
                            }
                            Chip(title: "+ New", selected: false, dashed: true) {
                                Telemetry.shared.log("button", ["name": "new-category"])
                                addingCategory = true
                            }
                        }
                    }
                }
            } else {
                Text("Money moving between your own accounts. It counts as neither income nor spending, and needs no category.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    var dashed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background {
                    Capsule().fill(selected ? Color.accentColor : Color(.secondarySystemFill))
                }
                .overlay {
                    if dashed { Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])).foregroundStyle(.secondary) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays chips out in rows, wrapping when the next one won't fit.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var items: [Int] = [], x: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !items.isEmpty && x + spacing + size.width > width {
                rows.append((items, x, height)); items = []; x = 0; height = 0
            }
            x += (items.isEmpty ? 0 : spacing) + size.width
            height = max(height, size.height)
            items.append(index)
        }
        if !items.isEmpty { rows.append((items, x, height)) }
        return rows
    }
}
