import Foundation
import SwiftData

/// What a transaction is, decided by you in the review.
nonisolated enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
    case income, expense, transfer
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// The category list it draws from. A transfer's is labels for where
    /// the money went ("To savings"), and picking one is optional.
    var categoryKind: CategoryKind {
        switch self {
        case .income: .income
        case .expense: .expense
        case .transfer: .transfer
        }
    }
}

/// Every category belongs to one side of the ledger, or labels a transfer.
nonisolated enum CategoryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case income, expense, transfer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .income: "Income"
        case .expense: "Expenses"
        case .transfer: "Transfers"
        }
    }
}

/// One kind of CSV: "Chase Sapphire", "BofA Checking". It's also the account.
@Model
final class Source {
    @Attribute(.unique) var name: String
    /// The header its files must have. A file whose header differs isn't this
    /// source's, or the bank changed its export and the mapping needs redoing.
    var header: [String]
    /// `ColumnMapping`, as JSON: its amount columns are an enum with
    /// associated values, which SwiftData can't store as a composite.
    var mappingData: Data
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ImportedFile.source)
    var files: [ImportedFile] = []

    var mapping: ColumnMapping {
        get { (try? JSONDecoder().decode(ColumnMapping.self, from: mappingData))
              ?? ColumnMapping(date: 0, description: 0, amount: .single(column: 0, moneyInIsPositive: true),
                               dateLayout: .monthDayYear) }
        set { mappingData = (try? JSONEncoder().encode(newValue)) ?? mappingData }
    }

    init(name: String, header: [String], mapping: ColumnMapping) {
        self.name = name
        self.header = header
        self.mappingData = (try? JSONEncoder().encode(mapping)) ?? Data()
        self.createdAt = .now
    }
}

/// A CSV as it arrived, kept whole so it can be read again if a mapping was
/// wrong, without hunting for the download.
@Model
final class ImportedFile {
    var name: String
    var importedAt: Date
    @Attribute(.externalStorage) var contents: Data
    var source: Source?

    @Relationship(deleteRule: .cascade, inverse: \LedgerEntry.file)
    var entries: [LedgerEntry] = []

    init(name: String, contents: Data, source: Source) {
        self.name = name
        self.importedAt = .now
        self.contents = contents
        self.source = source
    }
}

/// One transaction. Named `LedgerEntry` because SwiftUI already has a
/// `Transaction`, and the collision is miserable.
@Model
final class LedgerEntry {
    /// `2026-10-03`. A day, not an instant; see `Day`.
    var dayKey: String
    var text: String
    /// As the bank had it, normalised: positive is money in.
    var amountCents: Int
    /// Nil until you've reviewed it.
    var kindRaw: String?
    /// +1 adds to its kind's total, -1 takes away (a refund is an expense
    /// that subtracts).
    var sign: Int
    var category: Category?
    /// When one bank row was several things (a Target run that was groceries
    /// and household), its pieces. Empty means not split, and `category`
    /// holds the answer. The row itself stays one transaction, so the merge
    /// still counts it once.
    @Relationship(deleteRule: .cascade, inverse: \SplitPart.entry)
    var parts: [SplitPart] = []
    var file: ImportedFile?
    /// The receipt behind it, when you added one to split it by item.
    @Relationship(deleteRule: .cascade, inverse: \Receipt.entry)
    var receipt: Receipt?
    /// Its row in the file, counted from the first row under the header.
    var row: Int
    var mergeKey: String
    var reviewedAt: Date?

    var kind: Kind? {
        get { kindRaw.flatMap(Kind.init(rawValue:)) }
        set { kindRaw = newValue?.rawValue }
    }
    var day: Day { Day(key: dayKey) ?? Day(year: 1970, month: 1, day: 1) }
    var isReviewed: Bool { kindRaw != nil }
    /// What it adds to its kind's total.
    var contribution: Int { sign * abs(amountCents) }
    var isSplit: Bool { !parts.isEmpty }
    /// Each category's share, split or not: what the overview adds up.
    var shares: [(category: Category?, contribution: Int)] {
        isSplit ? parts.sorted { $0.order < $1.order }.map { ($0.category, sign * $0.cents) }
                : [(category, contribution)]
    }

    init(parsed: ParsedRow, row: Int, file: ImportedFile) {
        self.dayKey = parsed.day.key
        self.text = parsed.text
        self.amountCents = parsed.amountCents
        self.kindRaw = nil
        self.sign = 1
        self.row = row
        self.mergeKey = parsed.mergeKey
        self.file = file
    }
}

/// One piece of a split transaction. Its amount is positive; the
/// transaction's sign says which way it counts.
@Model
final class SplitPart {
    var cents: Int
    var order: Int
    /// What it was, when it came from a receipt line: "Cloud Island".
    var label: String = ""
    var category: Category?
    var entry: LedgerEntry?

    init(cents: Int, order: Int, category: Category, label: String = "") {
        self.cents = cents
        self.order = order
        self.category = category
        self.label = label
    }
}

/// A receipt, kept with the transaction it explains, on the phone only.
@Model
final class Receipt {
    @Attribute(.externalStorage) var data: Data
    var isPDF: Bool
    var addedAt: Date
    var entry: LedgerEntry?

    var file: ReceiptFile { ReceiptFile(data: data, isPDF: isPDF) }

    init(_ file: ReceiptFile) {
        self.data = file.data
        self.isPDF = file.isPDF
        self.addedAt = .now
    }
}

@Model
final class Category {
    var name: String
    var kindRaw: String
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.category)
    var entries: [LedgerEntry] = []
    @Relationship(deleteRule: .nullify, inverse: \SplitPart.category)
    var parts: [SplitPart] = []

    /// Whole transactions plus split pieces: how often it's been chosen.
    var uses: Int { entries.count + parts.count }

    var kind: CategoryKind { CategoryKind(rawValue: kindRaw) ?? .expense }

    /// The transactions that make it up, newest first, each once, with the
    /// part of it that's this category's: all of it, or for a split row its
    /// pieces here added together.
    var lines: [CategoryLine] {
        var order: [PersistentIdentifier] = []
        var byEntry: [PersistentIdentifier: CategoryLine] = [:]
        func add(_ entry: LedgerEntry, _ cents: Int) {
            let id = entry.persistentModelID
            if byEntry[id] == nil { order.append(id); byEntry[id] = CategoryLine(entry: entry, cents: 0) }
            byEntry[id]?.cents += cents
        }
        for entry in entries { add(entry, abs(entry.amountCents)) }
        for part in parts { if let entry = part.entry { add(entry, part.cents) } }
        return order.compactMap { byEntry[$0] }.sorted {
            $0.entry.dayKey != $1.entry.dayKey ? $0.entry.dayKey > $1.entry.dayKey : $0.entry.row < $1.entry.row
        }
    }

    init(name: String, kind: CategoryKind) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.createdAt = .now
    }
}

/// One transaction as a category sees it.
struct CategoryLine: Identifiable {
    let entry: LedgerEntry
    /// This category's share of the bank amount, always positive.
    var cents: Int
    var id: PersistentIdentifier { entry.persistentModelID }
    /// What it adds to the category's total: a refund takes away.
    var counted: Int { entry.sign * cents }
    /// The share, signed the way the bank had it: positive is money in.
    var bankCents: Int { entry.amountCents < 0 ? -cents : cents }
    /// Only part of the bank row is this category's.
    var isPartial: Bool { cents != abs(entry.amountCents) }
}

nonisolated enum RisuStore {
    static let models: [any PersistentModel.Type] = [Source.self, ImportedFile.self, LedgerEntry.self, SplitPart.self, Receipt.self, Category.self]

    /// Its own file. The app this one replaced left a `default.store` in the
    /// phone's container with a different schema; opening that would fail.
    static func configuration(inMemory: Bool) -> ModelConfiguration {
        if inMemory {
            return ModelConfiguration(schema: Schema(models), isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        let url = URL.applicationSupportDirectory.appending(path: "risu.store")
        return ModelConfiguration(schema: Schema(models), url: url, cloudKitDatabase: .none)
    }

    static func container(inMemory: Bool) throws -> ModelContainer {
        try ModelContainer(for: Schema(models), configurations: configuration(inMemory: inMemory))
    }
}
