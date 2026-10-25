import Foundation

/// A calendar day, with no time and no time zone.
///
/// A bank's "10/03/2026" is a day, not an instant. Stored as a `Date` at noon
/// UTC, it would still read as the 3rd in any zone the phone travels to, but
/// it's simpler to never make it an instant at all.
nonisolated struct Day: Hashable, Comparable, Codable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    /// `2026-10-03`. Also what a transaction stores, so it sorts as text.
    var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var monthKey: String { String(format: "%04d-%02d", year, month) }

    static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Reads a date in one of the layouts banks use.
    init?(_ text: String, format: DateLayout) {
        let s = text.trimmingCharacters(in: .whitespaces)
        let numbers = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        let (y, m, d): (Int, Int, Int)
        switch format {
        case .monthDayYear: (m, d, y) = (numbers[0], numbers[1], numbers[2])
        case .dayMonthYear: (d, m, y) = (numbers[0], numbers[1], numbers[2])
        case .yearMonthDay: (y, m, d) = (numbers[0], numbers[1], numbers[2])
        }
        let year = y < 100 ? 2000 + y : y
        guard (1...12).contains(m), (1...31).contains(d), (1900...2200).contains(year) else { return nil }
        var c = DateComponents(); c.year = year; c.month = m; c.day = d
        guard let date = Calendar(identifier: .gregorian).date(from: c),
              Calendar(identifier: .gregorian).component(.day, from: date) == d else { return nil }
        self.init(year: year, month: m, day: d)
    }

    var title: String {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        let date = Calendar(identifier: .gregorian).date(from: c) ?? .now
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "Oct 19", with the year only when it isn't this one: "Mar 3, 2014".
    var shortTitle: String {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: c) ?? .now
        return year == calendar.component(.year, from: .now)
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// The order a CSV writes day, month and year in.
nonisolated enum DateLayout: String, Codable, CaseIterable, Sendable {
    case monthDayYear, dayMonthYear, yearMonthDay

    var title: String {
        switch self {
        case .monthDayYear: "Month/Day/Year"
        case .dayMonthYear: "Day/Month/Year"
        case .yearMonthDay: "Year-Month-Day"
        }
    }

    /// Every layout that reads all of `values`, most likely first. US banks
    /// write month first, so when a column fits both orders that one leads.
    static func fitting(_ values: [String]) -> [DateLayout] {
        let present = values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !present.isEmpty else { return [] }
        return [.yearMonthDay, .monthDayYear, .dayMonthYear].filter { layout in
            present.allSatisfy { Day($0, format: layout) != nil }
        }
    }
}
