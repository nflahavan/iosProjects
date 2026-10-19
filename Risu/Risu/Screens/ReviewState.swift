import Foundation
import Observation
import SwiftData

/// The review's rows, read off the main thread, and how current they are.
///
/// The screen looks up only the card it shows. A decision made here moves
/// its row at once (it's saved, so that's where it is) and a read follows
/// to confirm. Anything else that changes the rows, an import or an edit in
/// Transactions, shows as updating until the read is back.
@Observable
final class ReviewState {
    private(set) var snapshot: ReviewSnapshot?
    /// Why the last read failed; the snapshot, if any, is from before it.
    private(set) var problem: String?
    /// A read is under way for a change made elsewhere: counts may change.
    private(set) var updating = false
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var reading: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
    }

    enum Cause: String { case decision, elsewhere }

    /// Starts a read, replacing any still running: an older read could
    /// predate the latest change, so only the newest gets to answer.
    func refresh(after cause: Cause) {
        reading?.cancel()
        if cause == .elsewhere { updating = true }
        let container = container
        let started = Date.now
        reading = Task {
            do {
                let fresh = try await LedgerReader(modelContainer: container).review()
                guard !Task.isCancelled else { return }
                snapshot = fresh
                problem = nil
                Telemetry.shared.log("review-ready", ["cause": cause.rawValue, "waiting": "\(fresh.waiting.count)",
                                                      "seconds": String(format: "%.2f", Date.now.timeIntervalSince(started))])
            } catch {
                guard !Task.isCancelled else { return }
                problem = error.localizedDescription
                Telemetry.shared.log("review-failed")
            }
            updating = false
        }
    }

    /// The row on the card was saved.
    func decided(_ id: PersistentIdentifier) {
        snapshot?.decide(id)
        refresh(after: .decision)
    }
}
