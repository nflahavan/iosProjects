import Foundation

// What the phone and the watch send each other over WatchConnectivity. Each payload travels as
// JSON under one dictionary key. These types are nonisolated because WatchConnectivity
// delivers on a background queue.

/// Phone → watch, as the application context: enough of the log for the watch to know which
/// run and which lift come next.
nonisolated struct PhoneContext: Codable, Equatable, Sendable {
    nonisolated struct DoneRun: Codable, Hashable, Sendable {
        var date: DayKey
        var slot: String
    }

    nonisolated struct LastLift: Codable, Equatable, Sendable {
        var date: DayKey
        /// "A" or "B".
        var workout: String
    }

    /// What to aim for on one exercise, from the last time it was logged.
    nonisolated struct LiftHint: Codable, Equatable, Sendable {
        /// The working weight to start from. Nil for bodyweight or a first time.
        var weight: Double?
        /// Reps or seconds of last time's first set.
        var count: Double?
        var sets: Int
        /// "↑ Add 5 lb", "Stay at 180 lb". Empty for a first time.
        var chip: String
    }

    static let key = "halfbuild.context.v1"

    var raceDate: DayKey
    /// Recent runs logged against a plan slot.
    var doneRuns: [DoneRun] = []
    var lastLift: LastLift?
    /// By exercise key. Nil from a phone app older than lift logging on the watch.
    var liftHints: [String: LiftHint]?

    var dictionary: [String: Any] { (try? JSONEncoder().encode(self)).map { [Self.key: $0] } ?? [:] }

    init(raceDate: DayKey, doneRuns: [DoneRun] = [], lastLift: LastLift? = nil, liftHints: [String: LiftHint]? = nil) {
        self.raceDate = raceDate; self.doneRuns = doneRuns; self.lastLift = lastLift; self.liftHints = liftHints
    }

    init?(dictionary: [String: Any]) {
        guard let data = dictionary[Self.key] as? Data, let v = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = v
    }
}

/// Watch → phone, as a user-info transfer: one finished run.
nonisolated struct WatchRunResult: Codable, Equatable, Sendable {
    static let key = "halfbuild.run.v1"

    /// Unique per run, so a payload delivered twice is logged once.
    var id: String
    /// The day the run started.
    var date: DayKey
    /// A `RunSlot` raw value. "extra" is a free run.
    var slot: String
    var minutes: Double
    var miles: Double?
    var avgHeartRate: Double?

    var userInfo: [String: Any] { (try? JSONEncoder().encode(self)).map { [Self.key: $0] } ?? [:] }

    init(id: String = UUID().uuidString, date: DayKey, slot: String, minutes: Double, miles: Double? = nil, avgHeartRate: Double? = nil) {
        self.id = id; self.date = date; self.slot = slot; self.minutes = minutes; self.miles = miles; self.avgHeartRate = avgHeartRate
    }

    /// Nil when the dictionary isn't a run result this version understands.
    init?(userInfo: [String: Any]) {
        guard let data = userInfo[Self.key] as? Data, let v = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = v
    }
}

/// Watch → phone, as a user-info transfer: one finished lifting workout with its sets.
nonisolated struct WatchLiftResult: Codable, Equatable, Sendable {
    /// One set: the weight, if any, and the reps or seconds, whichever the exercise counts.
    nonisolated struct LiftSet: Codable, Hashable, Sendable {
        var w: Double?
        var n: Double
    }

    nonisolated struct Entry: Codable, Equatable, Sendable {
        var key: String
        var sets: [LiftSet]
    }

    static let key = "halfbuild.lift.v1"

    /// Unique per workout, so a payload delivered twice is logged once.
    var id: String
    var date: DayKey
    /// "A" or "B".
    var workout: String
    var exercises: [Entry]
    var avgHeartRate: Double?

    var userInfo: [String: Any] { (try? JSONEncoder().encode(self)).map { [Self.key: $0] } ?? [:] }

    init(id: String = UUID().uuidString, date: DayKey, workout: String, exercises: [Entry], avgHeartRate: Double? = nil) {
        self.id = id; self.date = date; self.workout = workout; self.exercises = exercises; self.avgHeartRate = avgHeartRate
    }

    init?(userInfo: [String: Any]) {
        guard let data = userInfo[Self.key] as? Data, let v = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = v
    }
}

/// What the watch offers today: the plan, plus the runs it knows are done, from the phone's
/// last context and from runs saved on the watch since.
struct WatchPlan {
    var calendar: PlanCalendar
    var today: DayKey
    var doneRuns: Set<PhoneContext.DoneRun>
    var lastLift: PhoneContext.LastLift?

    /// `local` is what the watch has saved itself and the phone may not have reported back yet.
    init(context: PhoneContext?, localRuns: [PhoneContext.DoneRun] = [], localLift: PhoneContext.LastLift? = nil,
         today: DayKey = Day.today()) {
        let race = context.map(\.raceDate).flatMap { Day.date($0) != nil ? $0 : nil } ?? PlanCalendar.defaultRace
        calendar = PlanCalendar(raceDate: race)
        self.today = today
        doneRuns = Set((context?.doneRuns ?? []) + localRuns)
        lastLift = [context?.lastLift, localLift].compactMap { $0 }.max { $0.date < $1.date }
    }

    /// The plan week today falls in. Below 1 or above 26 outside the plan.
    var rawWeek: Int { calendar.weekNo(today) }
    var inPlan: Bool { rawWeek >= 1 && rawWeek <= PlanCalendar.weeks }
    /// The week whose runs are shown: week 1 before the plan starts, week 26 after it ends.
    var week: Int { min(max(rawWeek, 1), PlanCalendar.weeks) }

    /// Slots already logged in today's plan week.
    var doneSlots: Set<RunSlot> {
        guard inPlan else { return [] }
        return Set(doneRuns.compactMap { r in
            guard let slot = RunSlot(rawValue: r.slot), slot != .extra, calendar.weekNo(r.date) == rawWeek else { return nil }
            return slot
        })
    }

    /// The run to offer first. `.extra` means a free run: the week's runs are done, or today
    /// is outside the plan.
    var nextSlot: RunSlot { calendar.autoSlot(today, done: doneSlots) }

    struct Option: Identifiable {
        var slot: RunSlot
        var label: String
        var run: PlannedRun
        var done: Bool
        var id: String { slot.rawValue }
    }

    var options: [Option] {
        let done = doneSlots
        return PlanCalendar.slots(week).map { Option(slot: $0.slot, label: $0.label, run: $0.run, done: done.contains($0.slot)) }
    }

    var upNext: Workout {
        guard let w = lastLift.flatMap({ Workout(rawValue: $0.workout) }) else { return .A }
        return w.other
    }
}
