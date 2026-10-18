import Foundation

/// How one source's CSV columns become transactions.
nonisolated struct ColumnMapping: Codable, Equatable, Sendable {
    var date: Int
    var description: Int
    var amount: AmountColumns
    var dateLayout: DateLayout

    /// Banks disagree on which way round money goes, and some split it into
    /// two columns. Either way it's normalised to: positive is money in.
    enum AmountColumns: Codable, Equatable, Sendable {
        /// One column. `moneyInIsPositive` is false for card statements that
        /// show a purchase as a positive charge.
        case single(column: Int, moneyInIsPositive: Bool)
        /// Money out in one column, money in in another.
        case split(moneyOut: Int, moneyIn: Int)
    }

    /// One row read through this mapping, or why it couldn't be.
    func read(_ row: [String]) -> Result<ParsedRow, RowProblem> {
        func cell(_ i: Int) -> String { i < row.count ? row[i] : "" }
        guard let day = Day(cell(date), format: dateLayout) else { return .failure(.date(cell(date))) }
        let cents: Int
        switch amount {
        case .single(let column, let inIsPositive):
            guard let value = Money.cents(from: cell(column)) else { return .failure(.amount(cell(column))) }
            cents = inIsPositive ? value : -value
        case .split(let outColumn, let inColumn):
            let out = cell(outColumn).isEmpty ? 0 : Money.cents(from: cell(outColumn))
            let into = cell(inColumn).isEmpty ? 0 : Money.cents(from: cell(inColumn))
            guard let out, let into, !(cell(outColumn).isEmpty && cell(inColumn).isEmpty) else {
                return .failure(.amount("\(cell(outColumn)) / \(cell(inColumn))"))
            }
            cents = abs(into) - abs(out)
        }
        let text = cell(description).trimmingCharacters(in: .whitespaces)
        return .success(ParsedRow(day: day, text: text, amountCents: cents))
    }

    /// Every column this mapping reads from, for checking a file has them.
    var columns: [Int] {
        switch amount {
        case .single(let c, _): [date, description, c]
        case .split(let o, let i): [date, description, o, i]
        }
    }
}

/// A CSV row as a transaction-to-be. Amount: positive is money in.
nonisolated struct ParsedRow: Equatable, Hashable, Sendable {
    var day: Day
    var text: String
    var amountCents: Int

    /// What makes two rows the same bank row: day, amount, and description
    /// with case and spacing ignored.
    var mergeKey: String {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(day.key)|\(amountCents)|\(words)"
    }
}

nonisolated enum RowProblem: Error, Equatable, Sendable {
    case date(String)
    case amount(String)
}

/// A first guess at a new source's mapping, from its header and rows. The
/// person checks it on the mapping screen; this only saves them the typing.
nonisolated enum MappingGuess {

    static func guess(_ table: CSVTable) -> ColumnMapping? {
        let columns = table.header.indices
        func values(_ i: Int) -> [String] { table.rows.prefix(50).map { i < $0.count ? $0[i] : "" } }
        func named(_ i: Int, _ words: [String]) -> Bool {
            let h = table.header[i].lowercased()
            return words.contains { h.contains($0) }
        }
        func isMoney(_ i: Int) -> Bool {
            let v = values(i).filter { !$0.isEmpty }
            return !v.isEmpty && v.allSatisfy { Money.cents(from: $0) != nil }
        }

        let dateColumns = columns.filter { !DateLayout.fitting(values($0)).isEmpty }
        guard let date = dateColumns.first(where: { named($0, ["date"]) && !named($0, ["post"]) })
                ?? dateColumns.first(where: { named($0, ["date"]) }) ?? dateColumns.first,
              let layout = DateLayout.fitting(values(date)).first else { return nil }

        let money = columns.filter { $0 != date && isMoney($0) && !named($0, ["balance", "bal."]) }
        let amount: ColumnMapping.AmountColumns
        if let out = money.first(where: { named($0, ["debit", "withdrawal", "money out"]) }),
           let into = money.first(where: { named($0, ["credit", "deposit", "money in"]) }) {
            amount = .split(moneyOut: out, moneyIn: into)
        } else if let single = money.first(where: { named($0, ["amount"]) }) ?? money.first {
            amount = .single(column: single, moneyInIsPositive: true)
        } else {
            return nil
        }

        let used = Set([date] + money)
        let text = columns.filter { !used.contains($0) }
        let description = text.first(where: { named($0, ["description", "payee", "merchant", "name", "memo"]) })
            ?? text.max { averageLength(values($0)) < averageLength(values($1)) }
            ?? date
        return ColumnMapping(date: date, description: description, amount: amount, dateLayout: layout)
    }

    private static func averageLength(_ values: [String]) -> Double {
        values.isEmpty ? 0 : Double(values.map(\.count).reduce(0, +)) / Double(values.count)
    }
}
