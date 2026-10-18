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
    /// How many decided rows back from the queue you've stepped. 0 is the
    /// next new row.
    @State private var backSteps = 0

    private var recent: [LedgerEntry] { context.recentlyDecided() }

    private var current: LedgerEntry? {
        if backSteps > 0 {
            let recent = recent
            return backSteps <= recent.count ? recent[backSteps - 1] : nil
        }
        return context.reviewQueue().first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let entry = current {
                    ReviewCard(entry: entry, remaining: waiting.count,
                               revisiting: backSteps > 0,
                               canGoBack: backSteps < recent.count,
                               back: {
                                   backSteps += 1
                                   Telemetry.shared.log("back", ["steps": "\(backSteps)"])
                               },
                               returnToNew: {
                                   Telemetry.shared.log("back-to-new", ["from": "\(backSteps)"])
                                   backSteps = 0
                               },
                               saved: { if backSteps > 0 { backSteps -= 1 } })
                        .id(entry.persistentModelID)
                } else {
                    ContentUnavailableView {
                        Label("Nothing to review", systemImage: "checkmark.circle")
                    } description: {
                        Text("Import a CSV from your bank. Its new rows show up here one at a time.")
                    } actions: {
                        Button("Import CSV") { open() }
                            .buttonStyle(.borderedProminent)
                        if !recent.isEmpty {
                            Button("Go back over reviewed rows") {
                                backSteps = 1
                                Telemetry.shared.log("back", ["steps": "1", "from": "empty"])
                            }
                        }
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
    var revisiting = false
    var canGoBack = false
    var back: () -> Void = {}
    var returnToNew: () -> Void = {}
    var saved: () -> Void = {}
    @Environment(\.modelContext) private var context
    @State private var kind: Kind
    @State private var sign: Int
    @State private var category: Category?
    @State private var split: [SplitDraft]
    @State private var problem: String?
    @State private var shown = Date.now

    init(entry: LedgerEntry, remaining: Int, revisiting: Bool = false, canGoBack: Bool = false,
         back: @escaping () -> Void = {}, returnToNew: @escaping () -> Void = {},
         saved: @escaping () -> Void = {}) {
        self.entry = entry
        self.remaining = remaining
        self.revisiting = revisiting
        self.canGoBack = canGoBack
        self.back = back
        self.returnToNew = returnToNew
        self.saved = saved
        _kind = State(initialValue: entry.kind ?? (entry.amountCents < 0 ? .expense : .income))
        _sign = State(initialValue: entry.kind == nil ? 1 : entry.sign)
        _category = State(initialValue: entry.category)
        _split = State(initialValue: .from(entry))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if revisiting { revisitBanner }
                    summary
                    DecisionControls(kind: $kind, sign: $sign, category: $category, split: $split,
                                     total: abs(entry.amountCents))
                }
                .padding(20)
            }
            nextButton
        }
        .alert("Can't save that", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .onAppear {
            shown = .now
            Telemetry.shared.log("card", ["remaining": "\(remaining)",
                                          (revisiting ? "decided" : "suggested"): kind.rawValue,
                                          "category": revisiting ? (category?.name ?? "") : "",
                                          "revisit": "\(revisiting)",
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

    private var revisitBanner: some View {
        HStack {
            Label("Already reviewed", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Back to new rows", action: returnToNew)
                .font(.subheadline)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var nextButton: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                Label("Back", systemImage: "chevron.left")
                    .font(.headline)
                    .frame(minHeight: 34)
            }
            .buttonStyle(.bordered)
            .disabled(!canGoBack)
            Button(action: save) {
                Text(revisiting ? "Save and forward" : (remaining > 1 ? "Save and next" : "Save"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!decisionIsComplete(kind: kind, category: category, split: split, total: abs(entry.amountCents)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func save() {
        do {
            try context.record(entry, kind: kind, sign: sign, category: category, split: split)
            Telemetry.shared.log("decided", [
                "kind": kind.rawValue, "sign": sign > 0 ? "adds" : "subtracts",
                "category": split.isEmpty ? (category?.name ?? "") : split.compactMap { $0.category?.name }.joined(separator: " + "),
                "parts": "\(max(split.count, 1))",
                "seconds": String(format: "%.1f", Date.now.timeIntervalSince(shown)),
                "remaining": "\(revisiting ? remaining : remaining - 1)",
                "revisit": "\(revisiting)",
            ])
            saved()
        } catch {
            problem = error.localizedDescription
            Telemetry.shared.log("decide-failed", ["why": error.localizedDescription])
        }
    }
}

/// One piece of a split, while it's being typed.
struct SplitDraft: Identifiable, Equatable {
    let id = UUID()
    var text = ""
    var category: Category?

    static func == (a: SplitDraft, b: SplitDraft) -> Bool {
        a.id == b.id && a.text == b.text && a.category === b.category
    }
}

extension Array where Element == SplitDraft {
    /// Every piece's cents: the ones typed, and the last takes what's left.
    func cents(total: Int) -> [Int] {
        guard !isEmpty else { return [] }
        let typed = dropLast().map { Money.cents(from: $0.text).map(abs) ?? 0 }
        return typed + [total - typed.reduce(0, +)]
    }

    /// The pieces ready to save, or nil while one is missing or empty.
    func resolved(total: Int) -> [(cents: Int, category: Category)]? {
        guard count >= 2 else { return nil }
        let amounts = cents(total: total)
        var out: [(cents: Int, category: Category)] = []
        for (draft, cents) in zip(self, amounts) {
            guard cents > 0, let category = draft.category else { return nil }
            out.append((cents, category))
        }
        return out
    }

    static func from(_ entry: LedgerEntry) -> [SplitDraft] {
        entry.parts.sorted { $0.order < $1.order }.map {
            SplitDraft(text: String(format: "%d.%02d", $0.cents / 100, $0.cents % 100), category: $0.category)
        }
    }
}

/// What a decision needs before it can be saved.
func decisionIsComplete(kind: Kind, category: Category?, split: [SplitDraft], total: Int) -> Bool {
    if kind == .transfer { return true }
    return split.isEmpty ? category != nil : split.resolved(total: total) != nil
}

extension ModelContext {
    /// Saves whichever the controls hold: a split or a single answer.
    func record(_ entry: LedgerEntry, kind: Kind, sign: Int, category: Category?, split: [SplitDraft]) throws {
        if kind != .transfer, !split.isEmpty {
            guard let parts = split.resolved(total: abs(entry.amountCents)) else { throw LedgerError.splitNeedsParts }
            try decideSplit(entry, kind: kind, sign: sign, parts: parts)
        } else {
            try decide(entry, kind: kind, sign: sign, category: category)
        }
    }
}

/// Kind, sign and category, or a split into categories: the same controls in
/// the review and when fixing a transaction later.
struct DecisionControls: View {
    @Binding var kind: Kind
    @Binding var sign: Int
    @Binding var category: Category?
    @Binding var split: [SplitDraft]
    /// The bank amount, positive, which a split's pieces must add up to.
    let total: Int
    @Environment(\.modelContext) private var context
    @State private var active = 0
    @State private var adding = false
    @State private var renaming: Category?
    @State private var newName = ""
    @State private var problem: String?
    @FocusState private var focused: UUID?

    private var splitting: Bool { !split.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What is it?").font(.headline)
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .onChange(of: kind) { old, new in
                    // Chips picked belong to the other list.
                    if category?.kind != new.categoryKind { category = nil }
                    for i in split.indices where split[i].category?.kind != new.categoryKind { split[i].category = nil }
                    if new == .transfer { split = [] }
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

                if splitting { splitEditor }

                if let side = kind.categoryKind {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(splitting ? "Category for part \(active + 1)" : "Category").font(.headline)
                            Spacer()
                            if !splitting {
                                Button("Split", systemImage: "square.split.2x1") { startSplit() }
                                    .font(.subheadline)
                            }
                        }
                        ChipFlow(spacing: 8) {
                            ForEach(context.categories(side)) { chip in
                                Chip(title: chip.name, selected: selected(chip)) { pick(chip) }
                                    // A typo in + New is fixed where it was made.
                                    .contextMenu {
                                        Button("Rename", systemImage: "pencil") {
                                            newName = chip.name
                                            renaming = chip
                                            Telemetry.shared.log("chip-menu", ["action": "rename"])
                                        }
                                        if chip.uses == 0 {
                                            Button("Delete", systemImage: "trash", role: .destructive) { remove(chip) }
                                        }
                                    }
                            }
                            Chip(title: "+ New", selected: false, dashed: true) {
                                Telemetry.shared.log("button", ["name": "new-category"])
                                newName = ""
                                adding = true
                            }
                        }
                    }
                }
            } else {
                Text("Money moving between your own accounts. It counts as neither income nor spending, and needs no category.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .alert("New \(kind.categoryKind?.title.lowercased() ?? "") category", isPresented: $adding) {
            TextField("Name", text: $newName)
            Button("Add") { addCategory() }
            Button("Cancel", role: .cancel) { Telemetry.shared.log("new-category-cancelled") }
        }
        .alert("Rename category", isPresented: .constant(renaming != nil)) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let renaming {
                    do { try context.rename(renaming, to: newName); Telemetry.shared.log("category-renamed", ["from": "chip"]) }
                    catch { problem = error.localizedDescription }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Can't do that", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    // MARK: Splitting

    private var splitEditor: some View {
        let amounts = split.cents(total: total)
        let left = amounts.last ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Split \(Money.text(total))").font(.headline)
                Spacer()
                Button("Don't split") {
                    category = split.first?.category
                    split = []
                    Telemetry.shared.log("split-cancelled")
                }
                .font(.subheadline)
            }
            ForEach(Array(split.enumerated()), id: \.element.id) { index, draft in
                HStack(spacing: 10) {
                    Button { active = index } label: {
                        HStack {
                            Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            Text(draft.category?.name ?? "Pick a category")
                                .foregroundStyle(draft.category == nil ? Color.secondary : Color.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(index == active ? Color.accentColor.opacity(0.16) : Color(.secondarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            if index == active { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 1.5) }
                        }
                    }
                    .buttonStyle(.plain)

                    if index == split.count - 1 {
                        Text(Money.text(left))
                            .monospacedDigit()
                            .foregroundStyle(left > 0 ? Color.secondary : Color.red)
                            .frame(width: 96, alignment: .trailing)
                    } else {
                        TextField("0.00", text: $split[index].text)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .focused($focused, equals: draft.id)
                            .frame(width: 96)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 8)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if split.count > 2 {
                        Button("Remove part", systemImage: "minus.circle") { removePart(index) }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Add part", systemImage: "plus") { addPart() }
                    .font(.subheadline)
                Spacer()
                if left <= 0 {
                    Text("Parts add up to more than \(Money.text(total))")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    Text("The last part gets what's left").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
            }
        }
    }

    private func startSplit() {
        split = [SplitDraft(category: category), SplitDraft()]
        active = category == nil ? 0 : 1
        focused = split[0].id
        Telemetry.shared.log("split-started")
    }

    private func addPart() {
        // The new part goes before the last, which keeps taking the rest.
        split.insert(SplitDraft(), at: split.count - 1)
        active = split.count - 2
        focused = split[active].id
        Telemetry.shared.log("split-part-added", ["parts": "\(split.count)"])
    }

    private func removePart(_ index: Int) {
        split.remove(at: index)
        active = min(active, split.count - 1)
        Telemetry.shared.log("split-part-removed", ["parts": "\(split.count)"])
    }

    // MARK: Chips

    private func selected(_ chip: Category) -> Bool {
        splitting ? (split.indices.contains(active) && split[active].category === chip) : chip === category
    }

    private func pick(_ chip: Category) {
        if splitting {
            guard split.indices.contains(active) else { return }
            split[active].category = chip
            // On to the next part still waiting for one.
            if let next = split.indices.first(where: { split[$0].category == nil }) { active = next }
        } else {
            category = chip
        }
        Telemetry.shared.log("chip", ["name": chip.name, "split": "\(splitting)"])
    }

    private func addCategory() {
        guard let side = kind.categoryKind else { return }
        do {
            let made = try context.category(named: newName, kind: side)
            pick(made)
            Telemetry.shared.log("new-category", ["name": made.name, "kind": side.rawValue])
        } catch {
            problem = error.localizedDescription
        }
    }

    private func remove(_ chip: Category) {
        if category === chip { category = nil }
        for i in split.indices where split[i].category === chip { split[i].category = nil }
        do { try context.remove(chip); Telemetry.shared.log("chip-menu", ["action": "delete"]) }
        catch { problem = error.localizedDescription }
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
