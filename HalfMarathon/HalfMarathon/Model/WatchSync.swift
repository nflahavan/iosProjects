import Foundation
import SwiftData
import WatchConnectivity

/// Turns what the watch sends into sessions, and the log into what the watch needs.
enum WatchImporter {
    /// The session id for a watch run. It comes from the payload's id, so a run that arrives
    /// twice lands on the same session.
    static func sessionID(_ r: WatchRunResult, date: DayKey) -> String {
        "\(date)-cardio-w" + r.id.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A run session shaped like one logged by hand. Nil when the payload doesn't make sense.
    /// A date after `today` (a watch with the wrong date) is logged as today, as the log form does.
    static func session(from r: WatchRunResult, calendar: PlanCalendar, today: DayKey = Day.today()) -> Session? {
        guard !r.id.isEmpty, Day.date(r.date) != nil, r.minutes.isFinite, r.minutes > 0,
              let slot = RunSlot(rawValue: r.slot) else { return nil }
        let date = min(r.date, today)
        let wk = calendar.weekNo(date)
        let planned = slot != .extra && wk >= 1 && wk <= PlanCalendar.weeks
        let mi = r.miles.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let hr = r.avgHeartRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return Session(id: sessionID(r, date: r.date), date: date, type: "cardio", name: Activity.run.label,
                       createdAt: Date.now.timeIntervalSince1970 * 1000,
                       note: "Apple Watch" + (hr.map { " · avg \(Int($0.rounded())) bpm" } ?? ""),
                       activity: Activity.run.rawValue, slot: planned ? slot.rawValue : nil,
                       minutes: round1(LogModel.clamp(r.minutes, 0.1, 600)),
                       miles: mi.map { round1(LogModel.clamp($0, 0, 200)) }.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Adds a watch run to the log. Returns nil, adding nothing, for a malformed payload or
    /// one that's already here.
    @discardableResult
    static func importRun(_ r: WatchRunResult, into context: ModelContext, raceDate: DayKey,
                          today: DayKey = Day.today()) throws -> Session? {
        let race = Day.date(raceDate) != nil ? raceDate : PlanCalendar.defaultRace
        guard let s = session(from: r, calendar: PlanCalendar(raceDate: race), today: today) else { return nil }
        return try insert(s, into: context)
    }

    /// A lift session shaped like one logged by hand: the same kinds, limits and rounding as
    /// the log form. Exercises the app doesn't know, and sets with nothing counted, are dropped.
    /// Nil when nothing loggable is left.
    static func session(from r: WatchLiftResult, today: DayKey = Day.today()) -> Session? {
        guard !r.id.isEmpty, Day.date(r.date) != nil, let workout = Workout(rawValue: r.workout) else { return nil }
        var exercises: [LoggedExercise] = []
        for e in r.exercises {
            guard let def = Exercises.def(e.key), !exercises.contains(where: { $0.key == e.key }) else { continue }
            let sets: [LoggedSet] = e.sets.prefix(Exercises.maxSets).compactMap { s in
                guard s.n.isFinite, s.n > 0 else { return nil }
                let weight = s.w.flatMap { $0.isFinite && $0 > 0 ? round1(LogModel.clamp($0, 0, 2000)) : nil }
                switch def.kind {
                case .reps: return LoggedSet(w: weight, r: round1(LogModel.clamp(s.n, 0, 500)))
                case .bw: return LoggedSet(r: round1(LogModel.clamp(s.n, 0, 500)))
                case .time: return LoggedSet(s: round1(LogModel.clamp(s.n, 0, 3600)))
                case .carry: return LoggedSet(w: weight, s: round1(LogModel.clamp(s.n, 0, 3600)))
                }
            }
            if !sets.isEmpty { exercises.append(LoggedExercise(key: e.key, name: def.name, kind: def.kind, sets: sets)) }
        }
        guard !exercises.isEmpty else { return nil }
        let date = min(r.date, today)
        let hr = r.avgHeartRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let id = "\(r.date)-\(workout.rawValue)-w" + r.id.lowercased().filter { $0.isLetter || $0.isNumber }
        return Session(id: id, date: date, type: workout.rawValue, name: workout.label,
                       createdAt: Date.now.timeIntervalSince1970 * 1000,
                       note: "Apple Watch" + (hr.map { " · avg \(Int($0.rounded())) bpm" } ?? ""),
                       exercises: exercises)
    }

    /// Adds a watch lift to the log. Returns nil, adding nothing, for a malformed payload or
    /// one that's already here.
    @discardableResult
    static func importLift(_ r: WatchLiftResult, into context: ModelContext, today: DayKey = Day.today()) throws -> Session? {
        guard let s = session(from: r, today: today) else { return nil }
        return try insert(s, into: context)
    }

    private static func insert(_ s: Session, into context: ModelContext) throws -> Session? {
        let id = s.id
        guard try context.fetchCount(FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })) == 0 else { return nil }
        context.insert(s)
        try context.save()
        return s
    }

    /// What to aim for on each exercise of either workout, as the log form would suggest it.
    static func liftHints(for plan: Plan) -> [String: PhoneContext.LiftHint] {
        var hints: [String: PhoneContext.LiftHint] = [:]
        for key in Exercises.order {
            guard let def = Exercises.def(key) else { continue }
            let sug = plan.suggest(key)
            let first = plan.lastFor(key)?.sets.first
            hints[key] = PhoneContext.LiftHint(weight: sug.weight, count: def.countsReps ? first?.r : first?.s,
                                               sets: sug.sets, chip: sug.chip)
        }
        return hints
    }

    /// What the watch needs to pick the next run and lift: the race date, the slot runs of
    /// the last few weeks, and the last lift.
    static func context(for plan: Plan) -> PhoneContext {
        let since = Day.adding(-21, to: plan.today)
        let runs = plan.sessions
            .filter { $0.isCardio && $0.date >= since && RunSlot(rawValue: $0.slot ?? "") != nil }
            .map { PhoneContext.DoneRun(date: $0.date, slot: $0.slot ?? "") }
        let lift = plan.sessions.first(where: \.isLift).map { PhoneContext.LastLift(date: $0.date, workout: $0.type) }
        return PhoneContext(raceDate: plan.raceDate, doneRuns: runs.sorted { ($0.date, $0.slot) < ($1.date, $1.slot) }, lastLift: lift,
                            liftHints: liftHints(for: plan))
    }
}

/// The phone's end of the link to the watch: keeps the watch's copy of the plan state current
/// and logs the runs and lifts it sends back.
final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()

    private var container: ModelContainer?
    private var latest: PhoneContext?
    private var sent: PhoneContext?

    func start(container: ModelContainer) {
        self.container = container
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the context if it has changed. Kept until the link is up if it isn't yet.
    func push(_ context: PhoneContext) {
        latest = context
        let link = WCSession.isSupported() ? WCSession.default : nil
        guard let link, link.activationState == .activated, link.isPaired, link.isWatchAppInstalled, context != sent else { return }
        do {
            try link.updateApplicationContext(context.dictionary)
            sent = context
        } catch {
            // The watch went away between the check and the send. It's sent when it's back.
        }
    }

    private func receive(_ result: WatchRunResult) {
        guard let container else { return }
        let race = UserDefaults.standard.string(forKey: "raceDate") ?? PlanCalendar.defaultRace
        _ = try? WatchImporter.importRun(result, into: container.mainContext, raceDate: race)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let latest = self.latest { self.push(latest) }
        }
    }

    /// A watch was paired, or the watch app installed: it needs the context now.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            if let latest = self.latest { self.push(latest) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A different watch was paired: bring the link back up for it.
        session.activate()
    }

    private func receive(_ result: WatchLiftResult) {
        guard let container else { return }
        _ = try? WatchImporter.importLift(result, into: container.mainContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let run = WatchRunResult(userInfo: userInfo) {
            Task { @MainActor in self.receive(run) }
        } else if let lift = WatchLiftResult(userInfo: userInfo) {
            Task { @MainActor in self.receive(lift) }
        }
    }
}
