import Foundation

/// A calendar day as "yyyy-MM-dd", the same keys the web log used. Comparing the strings
/// compares the days.
typealias DayKey = String

enum Day {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // weeks start on Monday
        c.timeZone = .current
        return c
    }()

    static func key(_ date: Date) -> DayKey {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func date(_ key: DayKey) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, key.count == 10 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func today(_ now: Date = .now) -> DayKey { key(now) }

    static func adding(_ days: Int, to key: DayKey) -> DayKey {
        guard let d = date(key), let r = calendar.date(byAdding: .day, value: days, to: d) else { return key }
        return Day.key(r)
    }

    /// Whole days from `b` to `a`.
    static func diff(_ a: DayKey, _ b: DayKey) -> Int {
        guard let da = date(a), let db = date(b) else { return 0 }
        return calendar.dateComponents([.day], from: db, to: da).day ?? 0
    }

    /// 0 = Monday … 6 = Sunday.
    static func weekdayIndex(_ key: DayKey) -> Int {
        guard let d = date(key) else { return 0 }
        return (calendar.component(.weekday, from: d) + 5) % 7
    }

    static func weekStart(_ key: DayKey) -> DayKey { adding(-weekdayIndex(key), to: key) }

    static func format(_ key: DayKey, _ style: Date.FormatStyle) -> String {
        guard let d = date(key) else { return "No date" }
        return d.formatted(style)
    }

    static func short(_ key: DayKey) -> String { format(key, .dateTime.month(.abbreviated).day()) }
    static func long(_ key: DayKey) -> String { format(key, .dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    static func weekdayName(_ key: DayKey) -> String { format(key, .dateTime.weekday(.wide)) }
}

/// Numbers as the web log showed them: whole numbers bare, others to one decimal place.
func fmtNum(_ n: Double?) -> String {
    guard let n, n.isFinite else { return "–" }
    let r = (n * 10).rounded() / 10
    return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
}

func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

/// Parses what someone typed into a number box. Accepts a comma as the decimal point.
func parseNum(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard let v = Double(t), v.isFinite else { return nil }
    return v
}

func round1(_ n: Double) -> Double { (n * 10).rounded() / 10 }
