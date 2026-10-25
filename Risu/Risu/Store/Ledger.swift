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
        let held = source.files.sorted { $0.importedAt < $1.importedAt }.flatMap { $0.entries.sorted { $0.row < $1.row } }
        let fresh = SourceMerge.newRows(parsed, existing: held.map(\.mergeKey))
        let gone = SourceMerge.goneRows(held.map { ($0.mergeKey, $0.day) }, incoming: parsed.map(\.parsed)).map { held[$0] }

        let file = ImportedFile(name: name, contents: contents, source: source)
        insert(file)
        for item in fresh {
            insert(LedgerEntry(parsed: item.parsed, row: item.row, file: file))
        }
        try save()
        return ImportSummary(new: fresh.count, alreadyHere: parsed.count - fresh.count, unreadable: unreadable,
                             gone: gone.map(\.persistentModelID), goneReviewed: gone.filter(\.isReviewed).count)
    }

    /// Deletes rows the bank no longer has, with their split parts and
    /// receipts. Ones already deleted are skipped. Returns how many went.
    @discardableResult
    func removeGone(_ ids: [PersistentIdentifier]) throws -> Int {
        let entries = try ids.compactMap(entry)
        entries.forEach(delete)
        try save()
        return entries.count
    }

    // MARK: Reviewing

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
    /// Rows held from earlier files that this one shows the bank no longer
    /// has. Not removed until you say so.
    var gone: [PersistentIdentifier] = []
    /// How many of those you'd already reviewed.
    var goneReviewed = 0
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
        self.income = income.values.reduce(0, +)
        self.expenses = expense.values.reduce(0, +)
        self.incomeLines = Self.lines(income)
        self.expenseLines = Self.lines(expense)
    }

    /// Several months as one: a year, or any stretch of them.
    init(adding parts: [MonthTotals]) {
        var income: [String: Int] = [:], expense: [String: Int] = [:]
        for part in parts {
            for line in part.incomeLines { income[line.name, default: 0] += line.cents }
            for line in part.expenseLines { expense[line.name, default: 0] += line.cents }
            unreviewed += part.unreviewed
        }
        self.income = income.values.reduce(0, +)
        self.expenses = expense.values.reduce(0, +)
        self.incomeLines = Self.lines(income)
        self.expenseLines = Self.lines(expense)
    }

    /// Largest first; equal amounts by name.
    private static func lines(_ d: [String: Int]) -> [Line] {
        d.map { Line(name: $0.key, cents: $0.value) }
            .sorted { $0.cents != $1.cents ? $0.cents > $1.cents : $0.name < $1.name }
    }
}

/// A stretch of time the overview adds up.
nonisolated enum Period: Hashable, Sendable {
    /// `2026-10`.
    case month(String)
    case year(Int)

    var isYear: Bool { if case .year = self { true } else { false } }

    /// The one before: September for October, 2025 for 2026.
    var previous: Period { step(-1) }
    var next: Period { step(1) }

    /// The first day of it.
    var firstDay: Day {
        switch self {
        case .year(let y): Day(year: y, month: 1, day: 1)
        case .month(let key): Day(key: key + "-01") ?? Day(year: 1970, month: 1, day: 1)
        }
    }

    func step(_ by: Int) -> Period {
        switch self {
        case .year(let year): return .year(year + by)
        case .month(let key):
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return self }
            let index = parts[0] * 12 + (parts[1] - 1) + by
            return .month(String(format: "%04d-%02d", index / 12, index % 12 + 1))
        }
    }
}

/// Every month's totals, worked out together.
nonisolated struct Overview: Equatable, Sendable {
    /// Newest first.
    var months: [String] = []
    var totals: [String: MonthTotals] = [:]
    /// Each day's reviewed income less its spending, by day key. Days
    /// with neither aren't here.
    var dailyNet: [String: Int] = [:]

    /// Net over the `window` days ending on each day from `first` to
    /// `last`, every `step` days: "over the past 30 days, +$1,240".
    func rollingNet(window: Int, from first: Day, to last: Day, step: Int = 1) -> [(day: Day, cents: Int)] {
        guard window > 0, first <= last else { return [] }
        var sum = 0
        var day = first.adding(days: -(window - 1))
        // The window's opening days, before the first point.
        while day < first { sum += dailyNet[day.key] ?? 0; day = day.adding(days: 1) }
        var points: [(day: Day, cents: Int)] = []
        var count = 0
        while day <= last {
            sum += dailyNet[day.key] ?? 0
            if count % step == 0 || day == last { points.append((day, sum)) }
            sum -= dailyNet[day.adding(days: -(window - 1)).key] ?? 0
            day = day.adding(days: 1)
            count += 1
        }
        return points
    }

    /// Years with transactions, newest first.
    var years: [Int] { Array(Set(months.compactMap { Int($0.prefix(4)) })).sorted(by: >) }

    /// A month's totals, or a year's months added together. Empty when
    /// nothing happened in it.
    func totals(for period: Period) -> MonthTotals {
        switch period {
        case .month(let key): return totals[key] ?? MonthTotals()
        case .year(let year):
            return MonthTotals(adding: months.filter { $0.hasPrefix(String(format: "%04d-", year)) }.compactMap { totals[$0] })
        }
    }

    /// Whether anything happened in it.
    func has(_ period: Period) -> Bool {
        switch period {
        case .month(let key): totals[key] != nil
        case .year(let year): years.contains(year)
        }
    }

    /// The periods a trend shows, oldest first, ending at `period`: the
    /// twelve months to it, or every year to it. Gaps are kept, as zero,
    /// so the time axis stays even.
    func trend(endingAt period: Period) -> [Period] {
        switch period {
        case .month: return (0..<12).reversed().map { period.step(-$0) }
        case .year(let last):
            guard let first = years.last, first <= last else { return [period] }
            return (first...last).map(Period.year)
        }
    }
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
        var daily: [String: Int] = [:]
        for entry in entries {
            switch entry.kind {
            case .income?: daily[entry.dayKey, default: 0] += entry.contribution
            case .expense?: daily[entry.dayKey, default: 0] -= entry.contribution
            case .transfer?, nil: break
            }
        }
        return Overview(months: byMonth.keys.sorted(by: >),
                        totals: byMonth.mapValues { MonthTotals(month: $0[0].monthKey, items: $0) },
                        dailyNet: daily)
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
