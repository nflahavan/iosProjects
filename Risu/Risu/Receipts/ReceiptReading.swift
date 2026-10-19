import Foundation

/// What a receipt says, read from its lines of text: the items, the tax and
/// the total. Pure, so it's tested on invented receipts without a camera.
nonisolated struct ReceiptReading: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var name: String
        var cents: Int
        /// Nil when the receipt doesn't mark which lines are taxed.
        var taxed: Bool?
    }

    var items: [Item] = []
    var subtotal: Int?
    var tax = 0
    var total: Int?

    init(items: [Item], subtotal: Int?, tax: Int, total: Int?) {
        self.items = items
        self.subtotal = subtotal
        self.tax = tax
        self.total = total
    }

    /// Reads receipt lines top to bottom. Lines with a price before the
    /// subtotal are items; department headings, savings notes and anything
    /// after the total are left out.
    init(lines: [String]) {
        for line in lines {
            let upper = line.uppercased()
            guard let price = Self.lastPrice(in: line) else { continue }
            if Self.isNote(upper) { continue }
            if upper.contains("SUBTOTAL") || upper.contains("SUB TOTAL") || upper.contains("SUB-TOTAL") {
                subtotal = price.cents
            } else if upper.contains("TAX") {
                tax += price.cents
            } else if upper.contains("TOTAL") || upper.contains("BALANCE DUE") || upper.contains("AMOUNT DUE") {
                total = price.cents
                break
            } else if subtotal == nil, price.cents < 0, !items.isEmpty {
                // A coupon or price cut under an item comes off that item.
                items[items.count - 1].cents += price.cents
            } else if subtotal == nil, let name = Self.name(before: price.range, in: line) {
                items.append(Item(name: name, cents: price.cents, taxed: Self.taxFlag(after: price.range, in: line)))
            }
        }
    }

    /// The parts a split would get: each item with its share of whatever
    /// lies between the items and the total. Fails, rather than guessing,
    /// when the items don't account for the receipt, or the receipt isn't
    /// the bank's amount.
    ///
    /// The card charge is the anchor. With a subtotal the items must match
    /// it, and the gap to the total (tax, shipping, a coupon, so it can be
    /// negative) is spread over them; a printed tax line a cent off (stores
    /// that round tax per item) doesn't matter. Without a subtotal the
    /// printed tax is the only check on the items, so the gap must be that
    /// tax, within the cent.
    func parts(matching bankTotal: Int) -> Result<[(name: String, cents: Int)], ReceiptProblem> {
        guard !items.isEmpty, items.allSatisfy({ $0.cents > 0 }) else { return .failure(.noItems) }
        guard let total else { return .failure(.noTotal) }
        let itemSum = items.reduce(0) { $0 + $1.cents }
        if let subtotal, subtotal != itemSum { return .failure(.itemsDontAddUp(items: itemSum, subtotal: subtotal)) }
        let gap = total - itemSum
        guard total > 0, subtotal != nil || abs(gap - tax) <= 1 else { return .failure(.taxDoesntAddUp) }
        guard total == bankTotal else { return .failure(.otherAmount(receipt: total, bank: bankTotal)) }

        // Added tax goes on every line but those marked untaxed: a line with
        // no mark is more likely a mark that didn't read than an untaxed item.
        // A gap that takes money off, like a coupon, comes off every line.
        var weights = items.map { gap > 0 && $0.taxed == false ? 0 : $0.cents }
        if weights.allSatisfy({ $0 == 0 }) { weights = items.map(\.cents) }
        let parts = zip(items, Self.spread(gap, by: weights)).map { ($0.name, $0.cents + $1) }
        guard parts.allSatisfy({ $0.1 > 0 }) else { return .failure(.taxDoesntAddUp) }
        return .success(parts)
    }

    /// Splits `amount` cents in proportion to `weights`, to the cent: each
    /// share rounds down, then the leftover cents go to the shares that lost
    /// the most in rounding (the earlier one on a tie). A negative amount
    /// is spread the same way, taken off instead of added.
    static func spread(_ amount: Int, by weights: [Int]) -> [Int] {
        if amount < 0 { return spread(-amount, by: weights).map { -$0 } }
        let whole = weights.reduce(0, +)
        guard whole > 0 else { return weights.map { _ in 0 } }
        var shares = weights.map { amount * $0 / whole }
        let lost = weights.map { amount * $0 % whole }
        let left = amount - shares.reduce(0, +)
        for index in weights.indices.sorted(by: { lost[$0] > lost[$1] || (lost[$0] == lost[$1] && $0 < $1) }).prefix(left) {
            shares[index] += 1
        }
        return shares
    }

    // MARK: Reading a line

    /// `12.00`, `$12.00`, `-$2.00`, `2.00-`: two decimals, not part of a
    /// longer number (a tax rate like `5.5000` isn't a price).
    /// Swift's regexes have no lookbehind, so the character before is matched
    /// and left out of the price.
    private static var price: Regex<(Substring, Substring?, Substring, Substring, Substring?)> { #/(?:^|[^\d.,$\-])(-)?\$?\s?(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2})(?![\d.])(-)?/#}

    private static func lastPrice(in line: String) -> (cents: Int, range: Range<String.Index>)? {
        guard let match = line.matches(of: price).last else { return nil }
        let units = Int(match.output.2.replacing(",", with: "")) ?? 0
        let cents = units * 100 + (Int(match.output.3) ?? 0)
        let negative = match.output.1 != nil || match.output.4 != nil
        return (negative ? -cents : cents, match.range)
    }

    /// Lines that carry a price but aren't one: "Regular price $20.00",
    /// "You saved $14.00", the card that paid.
    private static func isNote(_ upper: String) -> Bool {
        ["REGULAR", "REG PRICE", "SAVED", "SAVINGS", "YOU SAVE", "CHANGE DUE", "CASH BACK"].contains { upper.contains($0) }
    }

    /// The words before the price, without item codes and tax letters.
    private static func name(before range: Range<String.Index>, in line: String) -> String? {
        let words = line[..<range.lowerBound].split(separator: " ").filter { word in
            let digits = word.filter(\.isNumber).count
            // Item numbers (`211300035`, `211-30-0035`) and lone flags go.
            return !(digits >= 5 && digits * 2 >= word.count) && !flags.contains(word.uppercased())
        }
        let name = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return name.contains(where: \.isLetter) ? name : nil
    }

    private static let flags: Set<String> = ["T", "N", "F", "X", "TF", "NF"]

    /// A receipt's tax column: `T` taxed, `N` not, beside the price.
    private static func taxFlag(after range: Range<String.Index>, in line: String) -> Bool? {
        let before = line[..<range.lowerBound].split(separator: " ").last.map { $0.uppercased() }
        let after = line[range.upperBound...].split(separator: " ").first.map { $0.uppercased() }
        for word in [after, before].compactMap({ $0 }) where flags.contains(word) {
            return word.hasPrefix("T")
        }
        return nil
    }
}

nonisolated enum ReceiptProblem: Error, Equatable, LocalizedError {
    case unreadable
    case noItems
    case noTotal
    case itemsDontAddUp(items: Int, subtotal: Int)
    case taxDoesntAddUp
    case otherAmount(receipt: Int, bank: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: "Couldn't open that file as a receipt."
        case .noItems: "Couldn't find the items on this receipt."
        case .noTotal: "Couldn't find the receipt's total."
        case .itemsDontAddUp(let items, let subtotal):
            "The items read as \(Money.text(items)), but the receipt's subtotal is \(Money.text(subtotal)). Some lines didn't read cleanly; try a sharper, straighter photo."
        case .taxDoesntAddUp: "The items and tax don't come to the receipt's total. Try a sharper, straighter photo."
        case .otherAmount(let receipt, let bank):
            "This receipt comes to \(Money.text(receipt)), but the transaction is \(Money.text(bank)). It may be a different receipt."
        }
    }

    /// For the log, which never holds amounts.
    var code: String {
        switch self {
        case .unreadable: "unreadable"
        case .noItems: "no-items"
        case .noTotal: "no-total"
        case .itemsDontAddUp: "items-dont-add-up"
        case .taxDoesntAddUp: "tax-doesnt-add-up"
        case .otherAmount: "other-amount"
        }
    }
}
