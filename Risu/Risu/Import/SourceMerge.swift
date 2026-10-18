import Foundation

/// Which rows of a new file a source hasn't seen yet.
///
/// Rows are compared by `ParsedRow.mergeKey` and *counted*, not just looked up:
/// two identical $5 coffees on one day are two real purchases. If the source
/// already has two of a row and the new file has three, one is new. That's
/// what makes overlapping downloads safe in any order and any overlap.
nonisolated enum SourceMerge {

    /// `existing` is every merge key the source already holds, repeats
    /// included. Returns the incoming rows that are new, in file order, with
    /// their row numbers in the file.
    static func newRows(_ incoming: [(row: Int, parsed: ParsedRow)],
                        existing: [String]) -> [(row: Int, parsed: ParsedRow)] {
        var seen = Dictionary(existing.map { ($0, 1) }, uniquingKeysWith: +)
        return incoming.filter { item in
            let key = item.parsed.mergeKey
            if let count = seen[key], count > 0 {
                seen[key] = count - 1
                return false
            }
            return true
        }
    }
}
