import Foundation
import SwiftData

/// Everything that changes the store, in one place.
extension ModelContext {

    // MARK: Sources and importing

    func sources() -> [Source] {
        (try? fetch(FetchDescriptor<Source>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    func addSource(name: String, header: [String], mapping: ColumnMapping) throws -> Source {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw LedgerError.emptyName }
        guard !sources().contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw LedgerError.sourceExists(trimmed)
        }
        let source = Source(name: trimmed, header: header, mapping: mapping)
        insert(source)
        try save()
        return source
    }

    /// Reads a file as `source`'s and stores the rows it hasn't seen, waiting
    /// for review. Nothing is stored if the file's columns aren't the source's.
    @discardableResult
    func importFile(named name: String, contents: Data, into source: Source) throws -> ImportSummary {
        let text = String(decoding: contents, as: UTF8.self)
        let table = CSVTable(text: text)
        guard table.header == source.header else { throw LedgerError.shapeMismatch(source.name) }

        var parsed: [(row: Int, parsed: ParsedRow)] = []
        var unreadable = 0
        for (index, cells) in table.rows.enumerated() {
            switch source.mapping.read(cells) {
            case .success(let row): parsed.append((index, row))
            case .failure: unreadable += 1
            }
        }
        let held = source.files.flatMap(\.entries).map(\.mergeKey)
        let fresh = SourceMerge.newRows(parsed, existing: held)

        let file = ImportedFile(name: name, contents: contents, source: source)
        insert(file)
        for item in fresh {
            insert(LedgerEntry(parsed: item.parsed, row: item.row, file: file))
        }
        try save()
        return ImportSummary(new: fresh.count, alreadyHere: parsed.count - fresh.count, unreadable: unreadable)
    }

    // MARK: Reviewing

    /// Rows still to decide, oldest file first, in file order.
    /// Rows waiting, a file at a time in import order; one account's, or all.
    /// One transaction by its identifier, from a `ReviewSnapshot`; nil if
    /// it's gone. Fetched rather than taken with `model(for:)`, which hands
    /// back a model for an identifier with nothing behind it.
    func entry(_ id: PersistentIdentifier) throws -> LedgerEntry? {
        var descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    /// Rows waiting, newest date first: what you just imported, and the
    /// spending you remember best, comes up before years of backlog. Within
    /// a day, the latest file first, then its own order.
    /// Nonisolated so `LedgerReader` can run it on its own context.
    nonisolated func reviewQueue() throws -> [LedgerEntry] {
        try fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.kindRaw == nil })).sorted {
            if $0.dayKey != $1.dayKey { return $0.dayKey > $1.dayKey }
            let a = $0.file?.importedAt ?? .distantPast, b = $1.file?.importedAt ?? .distantPast
            return a == b ? $0.row < $1.row : a > b
        }
    }

    /// Rows already decided, the most recently decided first: what the
    /// review's Back button steps through.
    /// Newest decision first. A re-decision keeps its place.
    nonisolated func recentlyDecided() throws -> [LedgerEntry] {
        try fetch(FetchDescriptor<LedgerEntry>(
            predicate: #Predicate { $0.reviewedAt != nil },
            sortBy: [SortDescriptor(\.reviewedAt, order: .reverse)]))
    }

    /// Records a decision. Changing one later keeps when it was first
    /// decided, so going back through the review keeps its order.
    func decide(_ entry: LedgerEntry, kind: Kind, sign: Int, category: Category?) throws {
        // A transfer has no category, so whatever chip was picked is dropped.
        if kind != .transfer {
            guard let category else { throw LedgerError.needsCategory }
            guard category.kind == kind.categoryKind else { throw LedgerError.wrongCategoryKind }
        }
        entry.kind = kind
        entry.sign = sign >= 0 ? 1 : -1
        entry.category = kind == .transfer ? nil : category
        clearParts(of: entry)
        if entry.reviewedAt == nil { entry.reviewedAt = .now }
        try save()
    }

    /// Records a split: the pieces must be from the kind's list and add up to
    /// the bank amount exactly.
    func decideSplit(_ entry: LedgerEntry, kind: Kind, sign: Int, parts: [(cents: Int, category: Category, label: String)]) throws {
        guard kind != .transfer else { throw LedgerError.transferSplit }
        guard parts.count >= 2, parts.allSatisfy({ $0.cents > 0 }) else { throw LedgerError.splitNeedsParts }
        guard parts.allSatisfy({ $0.category.kind == kind.categoryKind }) else { throw LedgerError.wrongCategoryKind }
        let total = parts.reduce(0) { $0 + $1.cents }
        guard total == abs(entry.amountCents) else {
            throw LedgerError.splitDoesNotAddUp(total: total, expected: abs(entry.amountCents))
        }
        entry.kind = kind
        entry.sign = sign >= 0 ? 1 : -1
        entry.category = nil
        clearParts(of: entry)
        for (index, part) in parts.enumerated() {
            let made = SplitPart(cents: part.cents, order: index, category: part.category, label: part.label)
            insert(made)
            made.entry = entry
        }
        if entry.reviewedAt == nil { entry.reviewedAt = .now }
        try save()
    }

    /// Keeps a receipt with its transaction, replacing any earlier one.
    func attach(_ file: ReceiptFile?, to entry: LedgerEntry) {
        guard let file, entry.receipt?.file != file else { return }
        if let old = entry.receipt { delete(old) }
        let receipt = Receipt(file)
        insert(receipt)
        entry.receipt = receipt
    }

    private func clearParts(of entry: LedgerEntry) {
        for part in entry.parts { delete(part) }
        entry.parts = []
    }

    // MARK: Categories

    /// The chips: categories of one kind, the ones you use most first.
    func categories(_ kind: CategoryKind) -> [Category] {
        let raw = kind.rawValue
        let all = (try? fetch(FetchDescriptor<Category>(predicate: #Predicate { $0.kindRaw == raw }))) ?? []
        return all.sorted {
            $0.uses != $1.uses
                ? $0.uses > $1.uses
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Makes a category, or hands back the one that already has that name.
    func category(named name: String, kind: CategoryKind) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw LedgerError.emptyName }
        if let existing = categories(kind).first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let made = Category(name: trimmed, kind: kind)
        insert(made)
        try save()
        return made
    }

    func rename(_ category: Category, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw LedgerError.emptyName }
        guard !categories(category.kind).contains(where: {
            $0 !== category && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { throw LedgerError.categoryExists(trimmed) }
        category.name = trimmed
        try save()
    }

    /// Only an unused category can go, so nothing reviewed loses its answer.
    func remove(_ category: Category) throws {
        guard category.uses == 0 else { throw LedgerError.categoryInUse(category.name) }
        delete(category)
        try save()
    }
}

nonisolated struct ImportSummary: Equatable, Sendable {
    var new: Int
    var alreadyHere: Int
    var unreadable: Int
}

nonisolated enum LedgerError: LocalizedError, Equatable {
    case emptyName
    case sourceExists(String)
    case categoryExists(String)
    case shapeMismatch(String)
    case needsCategory
    case wrongCategoryKind
    case categoryInUse(String)
    case transferSplit
    case splitNeedsParts
    case splitDoesNotAddUp(total: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case .emptyName: "Give it a name."
        case .sourceExists(let n): "There's already a source called \(n)."
        case .categoryExists(let n): "There's already a category called \(n)."
        case .shapeMismatch(let n): "This file's columns aren't \(n)'s. The bank may have changed its export; set up the columns again."
        case .needsCategory: "Pick a category."
        case .wrongCategoryKind: "That category is on the other side of the ledger."
        case .categoryInUse(let n): "\(n) is used by transactions, so it can't be deleted."
        case .transferSplit: "A transfer can't be split."
        case .splitNeedsParts: "A split needs at least two parts, each more than zero."
        case .splitDoesNotAddUp(let total, let expected):
            "The parts add up to \(Money.text(total)), not \(Money.text(expected))."
        }
    }
}

/// The overview's numbers for a month, from reviewed transactions only.
nonisolated struct MonthTotals: Equatable, Sendable {
    struct Line: Equatable, Identifiable, Sendable {
        var name: String
        var cents: Int
        var id: String { name }
    }
    var income = 0
    var expenses = 0
    var net: Int { income - expenses }
    var incomeLines: [Line] = []
    var expenseLines: [Line] = []
    var unreviewed = 0

    struct Item: Sendable {
        var monthKey: String
        var kind: Kind?
        var contribution: Int
        var category: String?
    }

    init() {}

    init(month: String, items: [Item]) {
        var income: [String: Int] = [:], expense: [String: Int] = [:]
        for item in items where item.monthKey == month {
            switch item.kind {
            case nil: unreviewed += 1
            case .transfer: break
            case .income: income[item.category ?? "Other", default: 0] += item.contribution
            case .expense: expense[item.category ?? "Other", default: 0] += item.contribution
            }
        }
        func lines(_ d: [String: Int]) -> [Line] {
            d.map { Line(name: $0.key, cents: $0.value) }
                .sorted { $0.cents != $1.cents ? $0.cents > $1.cents : $0.name < $1.name }
        }
        self.income = income.values.reduce(0, +)
        self.expenses = expense.values.reduce(0, +)
        self.incomeLines = lines(income)
        self.expenseLines = lines(expense)
    }
}

/// Every month's totals, worked out together.
nonisolated struct Overview: Equatable, Sendable {
    /// Newest first.
    var months: [String] = []
    var totals: [String: MonthTotals] = [:]
}

/// Reads the ledger off the main thread, with its own context on the same
/// store, so adding up a year of transactions never holds up the screen.
/// It hands back plain values; the models stay on its side.
///
/// It sees what's been saved, and every change in `Ledger` saves before it
/// returns. Make a new reader for each read: a context kept around keeps
/// the objects it already loaded, and could answer with old ones.
@ModelActor
actor LedgerReader {
    /// What the review goes through: rows waiting, in order, and rows
    /// decided, newest first, as identifiers the screen can look up.
    func review() throws -> ReviewSnapshot {
        func rows(_ entries: [LedgerEntry]) -> [ReviewSnapshot.Row] {
            entries.map { .init(id: $0.persistentModelID, source: $0.file?.source?.name ?? "") }
        }
        return ReviewSnapshot(waiting: rows(try modelContext.reviewQueue()), decided: rows(try modelContext.recentlyDecided()))
    }

    /// Throws rather than answering with nothing: an empty overview would
    /// say there are no transactions when they couldn't be read.
    func overview() throws -> Overview {
        let entries = try modelContext.fetch(FetchDescriptor<LedgerEntry>())
        let byMonth = Dictionary(grouping: entries.flatMap(\.totalsItems), by: \.monthKey)
        return Overview(months: byMonth.keys.sorted(by: >),
                        totals: byMonth.mapValues { MonthTotals(month: $0[0].monthKey, items: $0) })
    }
}

extension LedgerEntry {
    /// What it adds to its month: one item, or one per split part.
    var totalsItems: [MonthTotals.Item] {
        let month = day.monthKey, kind = kind
        return shares.map { MonthTotals.Item(monthKey: month, kind: kind, contribution: $0.contribution, category: $0.category?.name) }
    }
}

/// The review's rows as plain values, from a `LedgerReader`. Accounts are by
/// name, which is unique; "" means all of them.
nonisolated struct ReviewSnapshot: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var id: PersistentIdentifier
        var source: String
    }
    /// In the order they'll be reviewed: newest date first.
    var waiting: [Row]
    /// Newest decision first.
    var decided: [Row]

    func waiting(in source: String) -> [Row] { source.isEmpty ? waiting : waiting.filter { $0.source == source } }
    func decided(in source: String) -> [Row] { source.isEmpty ? decided : decided.filter { $0.source == source } }

    /// A row just decided and saved, moved where the next read will put it,
    /// so the next card needn't wait for that read. A re-decision keeps
    /// its place.
    mutating func decide(_ id: PersistentIdentifier) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        decided.insert(waiting.remove(at: index), at: 0)
    }
}
