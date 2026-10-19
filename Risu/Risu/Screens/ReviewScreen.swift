import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// One new row at a time: what it was, which way it counts, which category.
struct ReviewScreen: View {
    @Binding var importFile: IncomingFile?
    let review: ReviewState
    @Environment(\.modelContext) private var context
    @Query(sort: \Source.name) private var sources: [Source]
    /// The account being reviewed, by name; empty is all of them.
    @AppStorage("reviewSource") private var sourceName = ""
    @State private var picking = false
    @State private var showingSettings = false
    /// How many decided rows back from the queue you've stepped. 0 is the
    /// next new row.
    @State private var backSteps = 0

    /// The picked account, while it still exists.
    private var account: String { sources.contains { $0.name == sourceName } ? sourceName : "" }
    private var waiting: [ReviewSnapshot.Row] { review.snapshot?.waiting(in: account) ?? [] }
    private var decided: [ReviewSnapshot.Row] { review.snapshot?.decided(in: account) ?? [] }

    private enum Card {
        case entry(LedgerEntry)
        case none
        case failed(String)
    }

    /// The one row on screen, looked up by its identifier. Waiting rows
    /// are checked against the store, since one decided elsewhere since the
    /// last read must not come up again.
    private var current: Card {
        if backSteps > 0 {
            return backSteps <= decided.count ? lookup(decided[backSteps - 1].id) : .none
        }
        for row in waiting {
            switch lookup(row.id) {
            case .entry(let entry) where entry.kindRaw == nil: return .entry(entry)
            case .entry, .none: continue
            case .failed(let why): return .failed(why)
            }
        }
        return .none
    }

    private func lookup(_ id: PersistentIdentifier) -> Card {
        do { return try context.entry(id).map(Card.entry) ?? .none }
        catch { return .failed(error.localizedDescription) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if sources.count > 1 { accountPicker }
                status
                content
            }
            .navigationTitle(review.snapshot == nil || waiting.isEmpty ? "Review" : "Review · \(waiting.count) left")
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
            // Coming back from another tab: something there may have changed.
            .onAppear { review.refresh(after: .elsewhere) }
        }
    }

    /// Said whenever the counts may not be current.
    @ViewBuilder
    private var status: some View {
        if review.snapshot != nil, review.updating || review.problem != nil {
            HStack(spacing: 8) {
                if review.updating {
                    ProgressView().controlSize(.small)
                    Text("Updating the rows to review…")
                } else {
                    Label("Couldn't update the rows to review", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Try again") { review.refresh(after: .elsewhere) }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var content: some View {
        if review.snapshot == nil {
            if let problem = review.problem {
                failed(problem)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding the rows to review…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            card
        }
    }

    private func failed(_ why: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't read the rows to review", systemImage: "exclamationmark.triangle")
        } description: { Text(why) } actions: {
            Button("Try again") { review.refresh(after: .elsewhere) }.buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    /// Which account's rows to go through. All of them is a file at a
    /// time in import order; one account's is just its own.
    private var accountPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                accountChip("All", count: review.snapshot?.waiting.count, name: "")
                ForEach(sources) { source in
                    accountChip(source.name, count: review.snapshot?.waiting(in: source.name).count, name: source.name)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The count is left out until the first read is back.
    private func accountChip(_ title: String, count: Int?, name: String) -> some View {
        Chip(title: count.map { "\(title)  \($0)" } ?? title, selected: account == name) {
            guard account != name else { return }
            sourceName = name
            backSteps = 0
            Telemetry.shared.log("review-account", ["name": name.isEmpty ? "all" : name, "left": count.map(String.init) ?? "?"])
        }
    }

    @ViewBuilder
    private var card: some View {
        switch current {
        case .failed(let why):
            failed(why)
        case .entry(let entry):
            ReviewCard(entry: entry, remaining: waiting.count,
                       revisiting: backSteps > 0,
                       canGoBack: backSteps < decided.count,
                       back: {
                           backSteps += 1
                           Telemetry.shared.log("back", ["steps": "\(backSteps)"])
                       },
                       returnToNew: {
                           Telemetry.shared.log("back-to-new", ["from": "\(backSteps)"])
                           backSteps = 0
                       },
                       saved: {
                           if backSteps > 0 {
                               backSteps -= 1
                               review.refresh(after: .decision)
                           } else {
                               review.decided(entry.persistentModelID)
                           }
                       })
                .id(entry.persistentModelID)
        case .none:
            ContentUnavailableView {
                Label(account.isEmpty ? "Nothing to review" : "\(account) is done", systemImage: "checkmark.circle")
            } description: {
                Text(account.isEmpty ? "Import a CSV from your bank. Its new rows show up here one at a time."
                                     : "Every row from this account is reviewed. Pick another above, or import its next CSV.")
            } actions: {
                Button("Import CSV") { open() }
                    .buttonStyle(.borderedProminent)
                if !decided.isEmpty {
                    Button("Go back over reviewed rows") {
                        backSteps = 1
                        Telemetry.shared.log("back", ["steps": "1", "from": "empty"])
                    }
                }
            }
            .frame(maxHeight: .infinity)
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
    @State private var receipt: ReceiptFile?
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
        _receipt = State(initialValue: entry.receipt?.file)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if revisiting { revisitBanner }
                    summary
                    DecisionControls(kind: $kind, sign: $sign, category: $category, split: $split,
                                     receipt: $receipt, total: abs(entry.amountCents))
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
            try context.record(entry, kind: kind, sign: sign, category: category, split: split, receipt: receipt)
            Telemetry.shared.log("decided", [
                "kind": kind.rawValue, "sign": sign > 0 ? "adds" : "subtracts",
                "category": split.isEmpty ? (category?.name ?? "") : split.compactMap { $0.category?.name }.joined(separator: " + "),
                "parts": "\(max(split.count, 1))",
                "receipt": "\(receipt != nil)",
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
    /// The receipt line it came from, if any.
    var label = ""

    init(text: String = "", category: Category? = nil, label: String = "") {
        self.text = text
        self.category = category
        self.label = label
    }

    init(cents: Int, category: Category? = nil, label: String = "") {
        self.init(text: String(format: "%d.%02d", cents / 100, cents % 100), category: category, label: label)
    }

    static func == (a: SplitDraft, b: SplitDraft) -> Bool {
        a.id == b.id && a.text == b.text && a.category === b.category && a.label == b.label
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
    func resolved(total: Int) -> [(cents: Int, category: Category, label: String)]? {
        guard count >= 2 else { return nil }
        let amounts = cents(total: total)
        var out: [(cents: Int, category: Category, label: String)] = []
        for (draft, cents) in zip(self, amounts) {
            guard cents > 0, let category = draft.category else { return nil }
            out.append((cents, category, draft.label))
        }
        return out
    }

    static func from(_ entry: LedgerEntry) -> [SplitDraft] {
        entry.parts.sorted { $0.order < $1.order }.map {
            SplitDraft(cents: $0.cents, category: $0.category, label: $0.label)
        }
    }
}

/// What a decision needs before it can be saved.
func decisionIsComplete(kind: Kind, category: Category?, split: [SplitDraft], total: Int) -> Bool {
    if kind == .transfer { return true }
    return split.isEmpty ? category != nil : split.resolved(total: total) != nil
}

extension ModelContext {
    /// Saves whichever the controls hold: a split or a single answer, and
    /// the receipt if one was added.
    func record(_ entry: LedgerEntry, kind: Kind, sign: Int, category: Category?, split: [SplitDraft],
                receipt: ReceiptFile? = nil) throws {
        attach(receipt, to: entry)
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
    @Binding var receipt: ReceiptFile?
    /// The bank amount, positive, which a split's pieces must add up to.
    let total: Int
    @Environment(\.modelContext) private var context
    @State private var active = 0
    @State private var adding = false
    @State private var renaming: Category?
    @State private var newName = ""
    @State private var problem: String?
    @State private var pickingPhoto = false
    @State private var pickingFile = false
    @State private var photo: PhotosPickerItem?
    @State private var reading = false
    @State private var showingReceipt = false
    @FocusState private var focused: UUID?

    private var splitting: Bool { !split.isEmpty }

    var body: some View {
        ScrollViewReader { scroller in
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

                    if splitting {
                        splitEditor
                    } else if let side = kind.categoryKind {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Category").font(.headline)
                                Spacer()
                                Button("Split", systemImage: "square.split.2x1") { startSplit() }
                                    .font(.subheadline)
                            }
                            chips(side)
                        }
                    }
                } else {
                    Text("Money moving between your own accounts. It counts as neither income nor spending, and needs no category.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .onChange(of: active) { _, new in
                // The chips sit under the active part; keep it in view.
                guard split.indices.contains(new) else { return }
                withAnimation { scroller.scrollTo(split[new].id, anchor: .top) }
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
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            reading = true
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await read(ReceiptFile(data: data, isPDF: false), from: "photos")
                } else {
                    reading = false
                    problem = ReceiptProblem.unreadable.localizedDescription
                }
            }
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.image, .pdf]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                problem = ReceiptProblem.unreadable.localizedDescription
                return
            }
            let isPDF = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
            reading = true
            Task { await read(ReceiptFile(data: data, isPDF: isPDF), from: "files") }
        }
        .sheet(isPresented: $showingReceipt) {
            if let receipt { ReceiptViewer(file: receipt) }
        }
    }

    private func chips(_ side: CategoryKind) -> some View {
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
            receiptBar
            ForEach(Array(split.enumerated()), id: \.element.id) { index, draft in
                VStack(alignment: .leading, spacing: 10) {
                    partRow(index, draft, left: left)
                    if index == active, let side = kind.categoryKind {
                        chips(side).padding(.leading, 4).padding(.bottom, 6)
                    }
                }
                .id(draft.id)
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

    /// Splitting by a receipt's items instead of by hand.
    private var receiptBar: some View {
        HStack {
            if reading {
                ProgressView()
                Text("Reading the receipt…").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Menu {
                    Button("Photos", systemImage: "photo") {
                        Telemetry.shared.log("button", ["name": "receipt-photos"])
                        pickingPhoto = true
                    }
                    Button("Files", systemImage: "folder") {
                        Telemetry.shared.log("button", ["name": "receipt-files"])
                        pickingFile = true
                    }
                } label: {
                    Label(receipt == nil ? "Split by receipt" : "Another receipt", systemImage: "receipt")
                        .font(.subheadline.weight(.semibold))
                }
            }
            Spacer()
            if receipt != nil, !reading {
                Button("View receipt") {
                    Telemetry.shared.log("button", ["name": "view-receipt"])
                    showingReceipt = true
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemFill).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func partRow(_ index: Int, _ draft: SplitDraft, left: Int) -> some View {
        HStack(spacing: 10) {
            Button { active = index } label: {
                HStack {
                    Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        if !draft.label.isEmpty {
                            Text(draft.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                        Text(draft.category?.name ?? "Pick a category")
                            .font(draft.label.isEmpty ? .body : .subheadline)
                            .foregroundStyle(draft.category == nil ? Color.secondary : (draft.label.isEmpty ? Color.primary : Color.accentColor))
                            .lineLimit(1)
                    }
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

    private func startSplit() {
        split = [SplitDraft(category: category), SplitDraft()]
        active = category == nil ? 0 : 1
        focused = split[0].id
        Telemetry.shared.log("split-started")
    }

    /// Reads the receipt and, when it adds up to the transaction, makes one
    /// part per item with its share of the tax. When it doesn't, the receipt
    /// is still kept and shown, and the split is left to do by hand.
    private func read(_ file: ReceiptFile, from origin: String) async {
        focused = nil
        defer { reading = false }
        receipt = file
        do {
            let started = Date.now
            let read = try await ReceiptReader.parts(for: file, matching: total)
            var fields = ["from": origin, "pdf": "\(file.isPDF)", "via": read.method.rawValue, "items": "\(read.items)",
                          "seconds": String(format: "%.1f", Date.now.timeIntervalSince(started))]
            if !ReceiptModel.isAvailable { fields["model"] = ReceiptModel.unavailableReason }
            switch read.result {
            case .success(let parts):
                kind = .expense
                sign = 1
                split = parts.map { SplitDraft(cents: $0.cents, label: $0.name) }
                active = 0
                fields["ok"] = "true"
            case .failure(let why):
                problem = why.localizedDescription + " The receipt is kept; View receipt shows it while you split by hand."
                fields["ok"] = "false"
                fields["why"] = why.code
            }
            Telemetry.shared.log("receipt-read", fields)
        } catch {
            problem = ReceiptProblem.unreadable.localizedDescription
            Telemetry.shared.log("receipt-read", ["from": origin, "ok": "false", "why": "vision"])
        }
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
