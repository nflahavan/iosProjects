import Foundation

/// Money as whole cents. Never `Double`: 0.1 + 0.2 isn't 0.3 in floating point,
/// and a budget that's off by a cent is a budget nobody trusts.
nonisolated enum Money {

    /// Reads an amount the way banks write them: `1234.56`, `$1,234.56`,
    /// `-12.34`, `12.34-`, `(12.34)` for a negative, `+5`. Nil for anything
    /// else, including more than two decimal places, which would mean the
    /// column isn't money.
    static func cents(from text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        s = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("-") { negative.toggle(); s.removeFirst() }
        else if s.hasPrefix("+") { s.removeFirst() }
        if s.hasSuffix("-") { negative.toggle(); s.removeLast() }
        if s.hasPrefix("$") { s.removeFirst() }

        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let whole = parts[0], fraction = parts.count == 2 ? parts[1] : ""
        guard !(whole.isEmpty && fraction.isEmpty), fraction.count <= 2 else { return nil }
        guard let dollars = Int(whole.isEmpty ? "0" : whole) else { return nil }
        let cents = Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        let total = dollars * 100 + cents
        return negative ? -total : total
    }

    /// `$1,234.56`, always positive; the screens say which way it went.
    static func text(_ cents: Int) -> String {
        let value = Decimal(abs(cents)) / 100
        return value.formatted(.currency(code: "USD"))
    }
}
