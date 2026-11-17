import Foundation
import Observation
import WatchConnectivity

/// The watch's end of the link to the phone. Keeps the last context the phone sent, so the
/// app knows the plan without the phone in reach, and hands finished runs to the system to
/// deliver whenever it can.
@Observable
final class WatchLink: NSObject, WCSessionDelegate {
    /// Nil until the phone has sent one. The plan then runs off the default race date.
    private(set) var context: PhoneContext?
    /// Runs saved on this watch, which count as done before the phone reports them back.
    private(set) var localRuns: [PhoneContext.DoneRun] = []
    private(set) var localLift: PhoneContext.LastLift?
    /// Results not yet handed to WatchConnectivity, because the link wasn't up.
    private var pending: [WatchRunResult] = []
    private var pendingLifts: [WatchLiftResult] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var live = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        context = load("phoneContext")
        localRuns = load("localRuns") ?? []
        localLift = load("localLift")
        pending = load("pendingRuns") ?? []
        pendingLifts = load("pendingLifts") ?? []
    }

    /// `live: false` keeps WatchConnectivity out of it, for the demo launch arguments.
    func start(live: Bool = true) {
        self.live = live && WCSession.isSupported()
        guard self.live else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func plan(today: DayKey = Day.today()) -> WatchPlan {
        WatchPlan(context: context, localRuns: localRuns, localLift: localLift, today: today)
    }

    func send(_ result: WatchRunResult) {
        pending.append(result)
        localRuns.append(PhoneContext.DoneRun(date: result.date, slot: result.slot))
        let since = Day.adding(-21, to: Day.today())
        localRuns.removeAll { $0.date < since }
        store(localRuns, "localRuns")
        flush()
    }

    /// Queues a lift with its sets for the phone's log.
    func send(_ result: WatchLiftResult) {
        pendingLifts.append(result)
        flush()
    }

    /// Hints for the lift form: what the phone suggests for each exercise.
    var liftHints: [String: PhoneContext.LiftHint] { context?.liftHints ?? [:] }

    func noteLift(_ workout: Workout, on date: DayKey) {
        localLift = PhoneContext.LastLift(date: date, workout: workout.rawValue)
        store(localLift, "localLift")
    }

    /// Hands waiting results to the system, which keeps them queued until the phone has them,
    /// across launches of either app.
    private func flush() {
        if live, WCSession.default.activationState == .activated {
            for r in pending { WCSession.default.transferUserInfo(r.userInfo) }
            for r in pendingLifts { WCSession.default.transferUserInfo(r.userInfo) }
            pending = []
            pendingLifts = []
        }
        store(pending, "pendingRuns")
        store(pendingLifts, "pendingLifts")
    }

    private func receive(_ new: PhoneContext) {
        context = new
        store(new, "phoneContext")
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let received = PhoneContext(dictionary: session.receivedApplicationContext)
        Task { @MainActor in
            if let received { self.receive(received) }
            self.flush()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let received = PhoneContext(dictionary: applicationContext) else { return }
        Task { @MainActor in self.receive(received) }
    }
}
