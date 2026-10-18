import Foundation

/// A CSV file, read into a header and the rows under it.
///
/// Reads RFC 4180 CSV: fields in double quotes may hold commas, line breaks and
/// doubled quotes (`""`). Any line ending works, and a UTF-8 byte-order mark is
/// ignored.
///
/// Some banks put a summary block above the real table ("Beginning balance,…",
/// then a blank line). The header is taken to be the first row with the most
/// common number of fields, so that block is skipped without a setting.
nonisolated struct CSVTable: Equatable, Sendable {
    var header: [String]
    var rows: [[String]]

    init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
    }

    init(text: String) {
        let records = Self.records(in: text)
            .filter { record in record.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !records.isEmpty else {
            self.init(header: [], rows: [])
            return
        }
        // The table's width is whatever most rows agree on.
        let widths = Dictionary(grouping: records.map(\.count), by: { $0 }).mapValues(\.count)
        let width = widths.max { ($0.value, $0.key) < ($1.value, $1.key) }!.key
        let headerIndex = records.firstIndex { $0.count == width }!
        let header = records[headerIndex].map { $0.trimmingCharacters(in: .whitespaces) }
        let rows = records[(headerIndex + 1)...]
            .filter { $0.count == width }
            .map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
        self.init(header: header, rows: Array(rows))
    }

    /// Splits text into records of fields, honouring quotes.
    static func records(in text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.unicodeScalars.makeIterator()
        var pending = chars.next()
        if pending == "\u{FEFF}" { pending = chars.next() }

        func endField() { record.append(field); field = "" }
        func endRecord() { endField(); records.append(record); record = [] }

        while let c = pending {
            pending = chars.next()
            if inQuotes {
                if c == "\"" {
                    if pending == "\"" { field.unicodeScalars.append("\""); pending = chars.next() }
                    else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"": inQuotes = true
            case ",": endField()
            case "\r":
                if pending == "\n" { pending = chars.next() }
                endRecord()
            case "\n": endRecord()
            default: field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}
