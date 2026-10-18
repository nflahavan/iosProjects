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
    func reviewQueue() -> [LedgerEntry] {
        let all = (try? fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.kindRaw == nil }))) ?? []
        return all.sorted {
            let a = $0.file?.importedAt ?? .distantPast, b = $1.file?.importedAt ?? .distantPast
            return a == b ? $0.row < $1.row : a < b
        }
    }

    /// Rows already decided, the most recently decided first: what the
    /// review's Back button steps through.
    func recentlyDecided(limit: Int = 200) -> [LedgerEntry] {
        var descriptor = FetchDescriptor<LedgerEntry>(
            predicate: #Predicate { $0.reviewedAt != nil },
            sortBy: [SortDescriptor(\.reviewedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? fetch(descriptor)) ?? []
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
        if entry.reviewedAt == nil { entry.reviewedAt = .now }
        try save()
    }

    // MARK: Categories

    /// The chips: categories of one kind, the ones you use most first.
    func categories(_ kind: CategoryKind) -> [Category] {
        let raw = kind.rawValue
        let all = (try? fetch(FetchDescriptor<Category>(predicate: #Predicate { $0.kindRaw == raw }))) ?? []
        return all.sorted {
            $0.entries.count != $1.entries.count
                ? $0.entries.count > $1.entries.count
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
        guard category.entries.isEmpty else { throw LedgerError.categoryInUse(category.name) }
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

    var errorDescription: String? {
        switch self {
        case .emptyName: "Give it a name."
        case .sourceExists(let n): "There's already a source called \(n)."
        case .categoryExists(let n): "There's already a category called \(n)."
        case .shapeMismatch(let n): "This file's columns aren't \(n)'s. The bank may have changed its export; set up the columns again."
        case .needsCategory: "Pick a category."
        case .wrongCategoryKind: "That category is on the other side of the ledger."
        case .categoryInUse(let n): "\(n) is used by transactions, so it can't be deleted."
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
