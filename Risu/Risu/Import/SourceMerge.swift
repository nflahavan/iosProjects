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

    /// Which rows a source holds that a new file says the bank no longer
    /// has: usually a pending charge that has since posted under another
    /// amount, date or description, or one that was reversed.
    ///
    /// A file lists everything the bank had for the days it covers, so a
    /// held row dated within them that the file doesn't list is gone. It's
    /// counted the same way as `newRows`: two coffees held and one in the
    /// file, one is gone (the later held one). Rows outside the file's days
    /// aren't judged. Returns indices into `held`.
    static func goneRows(_ held: [(key: String, day: Day)], incoming: [ParsedRow]) -> [Int] {
        guard let first = incoming.map(\.day).min(), let last = incoming.map(\.day).max() else { return [] }
        var listed = Dictionary(incoming.map { ($0.mergeKey, 1) }, uniquingKeysWith: +)
        return held.indices.filter { index in
            let row = held[index]
            guard first <= row.day, row.day <= last else { return false }
            if let count = listed[row.key], count > 0 {
                listed[row.key] = count - 1
                return false
            }
            return true
        }
    }
}
