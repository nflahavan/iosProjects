import Foundation

/// The plan (`PlanCalendar`, shared with the watch app) and what has been done against it.
struct Plan {
    static let weeks = PlanCalendar.weeks
    static let defaultRace = PlanCalendar.defaultRace
    static let liftDays = PlanCalendar.liftDays
    static let downWeeks = PlanCalendar.downWeeks
    static var runs: [[PlannedRun]] { PlanCalendar.runs }
    static var phases: [Phase] { PlanCalendar.phases }

    var raceDate: DayKey
    /// Newest first.
    var sessions: [Session]
    var today: DayKey = Day.today()

    // MARK: Weeks

    var calendar: PlanCalendar { PlanCalendar(raceDate: raceDate) }
    var planStart: DayKey { calendar.planStart }
    func weekNo(_ day: DayKey) -> Int { calendar.weekNo(day) }
    func weekDate(_ n: Int, _ offset: Int = 0) -> DayKey { calendar.weekDate(n, offset) }
    var rawWeek: Int { weekNo(today) }
    var currentWeek: Int { min(max(rawWeek, 1), Plan.weeks) }
    static func phase(_ n: Int) -> Phase { PlanCalendar.phase(n) }
    static func liftTarget(_ n: Int) -> Int { PlanCalendar.liftTarget(n) }
    var holdLegs: Bool { rawWeek >= 18 }
    static func slots(_ n: Int) -> [(slot: RunSlot, label: String, run: PlannedRun)] { PlanCalendar.slots(n) }
    static func weekTotal(_ n: Int) -> String { PlanCalendar.weekTotal(n) }
    func dayLabels(_ n: Int) -> [String] { calendar.dayLabels(n) }
    static func liftNote(_ n: Int) -> String { PlanCalendar.liftNote(n) }

    var countdown: String {
        let d = Day.diff(raceDate, today)
        return d > 1 ? "\(d) days to race day" : d == 1 ? "Race day is tomorrow" : d == 0 ? "Race day" : ""
    }

    // MARK: Runs done

    /// Logged runs for a plan week, by slot. Skips the session being edited.
    func runsDone(_ n: Int, skipping skipID: String? = nil) -> [RunSlot: Session] {
        var out: [RunSlot: Session] = [:]
        for s in sessions where s.isCardio && s.id != skipID {
            guard let slot = RunSlot(rawValue: s.slot ?? ""), slot != .extra else { continue }
            if weekNo(s.date) == n, out[slot] == nil { out[slot] = s }
        }
        return out
    }

    /// Which run a new run on this day most likely is.
    func autoSlot(_ day: DayKey, skipping skipID: String? = nil) -> RunSlot {
        calendar.autoSlot(day, done: Set(runsDone(weekNo(day), skipping: skipID).keys))
    }

    func runName(_ s: Session) -> String {
        guard let slot = RunSlot(rawValue: s.slot ?? ""), slot != .extra else {
            return s.name.isEmpty ? (Activity(rawValue: s.activity ?? "")?.label ?? "Cardio") : s.name
        }
        if slot == .long { return s.date == raceDate ? "Race" : "Long run" }
        return slot.label
    }

    static func loggedText(_ s: Session) -> String {
        let mi = s.miles ?? 0
        return "\(fmtNum(s.minutes)) min" + (mi > 0 ? " · \(fmtNum(mi)) mi" : "")
    }

    // MARK: Lifts

    var upNext: Workout {
        guard let last = sessions.first(where: \.isLift) else { return .A }
        return last.type == "A" ? .B : .A
    }

    struct DayPlan {
        enum Kind { case lift, run, race }
        let kind: Kind
        let chip: String
        let small: String
        let text: String
        let detail: String
        let done: Bool
        var slot: RunSlot? = nil
    }

    /// What the plan puts on a given day, and whether it has been done that week.
    func dayPlan(_ day: DayKey) -> DayPlan? {
        let n = weekNo(day)
        guard Day.date(day) != nil, n >= 1, n <= Plan.weeks else { return nil }
        let i = Day.weekdayIndex(day)
        let lab = dayLabels(n)[i]
        if lab.isEmpty { return nil }
        if lab == "Lift" {
            let k = n >= Plan.weeks ? "" : (i == 0 ? "A" : "B")
            let lifts = sessions.filter { $0.isLift && weekNo($0.date) == n }.count
            return DayPlan(kind: .lift, chip: k.isEmpty ? "Lift" : "Lift \(k)", small: "",
                           text: k.isEmpty ? "One easy lift" : "Workout \(k)", detail: Plan.liftNote(n),
                           done: lifts >= (i == 0 ? 1 : 2))
        }
        let key: RunSlot = lab == "Run" ? (i == 1 ? .r1 : .r2) : .long
        let w = Plan.slots(n).first { $0.slot == key }!.run
        return DayPlan(kind: lab == "Race" ? .race : .run, chip: lab, small: w.small,
                       text: lab == "Race" ? "Race day" : lab == "Long" ? "Long run" : key.label,
                       detail: w.describe + (w.isRunWalk ? " · \(w.minutes) min" : ""),
                       done: runsDone(n)[key] != nil, slot: key)
    }
}

// MARK: - Progression

struct Suggestion: Equatable {
    var text: String
    var chip: String
    var up: Bool
    var weight: Double?
    var sets: Int
}

extension Plan {
    func lastFor(_ key: String, skipping skipID: String? = nil) -> (date: DayKey, sets: [LoggedSet])? {
        for s in sessions where s.id != skipID {
            if let e = s.liftExercises.first(where: { $0.key == key }) { return (s.date, e.sets) }
        }
        return nil
    }

    static func fmtSets(_ kind: ExerciseKind, _ sets: [LoggedSet]) -> String {
        switch kind {
        case .time: return sets.map { "\(fmtNum($0.s)) s" }.joined(separator: ", ")
        case .bw: return sets.map { fmtNum($0.r) }.joined(separator: ", ") + " reps"
        default:
            let cnt: (LoggedSet) -> String = { fmtNum(kind == .reps ? $0.r : $0.s) }
            let ws: [String?] = sets.map { ($0.w ?? 0) > 0 ? fmtNum($0.w) : nil }
            let unit = kind == .carry ? " s" : ""
            if ws.allSatisfy({ $0 == ws.first! }) {
                return "\(ws.first!.map { "\($0) lb" } ?? "Bodyweight") × \(sets.map(cnt).joined(separator: ", "))\(unit)"
            }
            return zip(sets, ws).map { s, w in "\(w.map { "\($0) lb" } ?? "BW") × \(cnt(s))\(unit)" }.joined(separator: ", ")
        }
    }

    /// What to aim for this time, from the last time the exercise was logged.
    func suggest(_ key: String, skipping skipID: String? = nil) -> Suggestion {
        guard let def = Exercises.def(key) else { return Suggestion(text: "", chip: "", up: false, weight: nil, sets: 2) }
        guard let last = lastFor(key, skipping: skipID) else {
            let first = def.first ?? (def.kind == .time ? "First time: hold for \(def.lo)–\(def.hi) s."
                : def.kind == .carry ? "First time: pick dumbbells you could carry for about a minute."
                : "First time: start light, with a weight you could lift about \(def.hi + 3) times.")
            return Suggestion(text: first, chip: "", up: false, weight: nil, sets: 2)
        }
        let sets = last.sets
        let counts = sets.map { (def.countsReps ? $0.r : $0.s) ?? 0 }
        let weights = sets.compactMap(\.w).filter { $0 > 0 }
        let work = weights.max()
        let allTop = counts.count >= 2 && counts.allSatisfy { $0 >= Double(def.hi) }
        let text = "Last · \(Day.long(last.date)) · \(Plan.fmtSets(def.kind, sets))"
        let setCount = min(max(sets.count, 2), Exercises.maxSets)
        switch def.kind {
        case .time:
            let best = counts.filter { $0 > 0 }.max() ?? 0
            return allTop
                ? Suggestion(text: text, chip: "↑ Try \(fmtNum(best + def.inc)) s", up: true, weight: nil, sets: setCount)
                : Suggestion(text: text, chip: "Aim for \(def.hi) s", up: false, weight: nil, sets: setCount)
        case .bw:
            return allTop
                ? Suggestion(text: text, chip: def.upText ?? "↑ Make it harder", up: true, weight: nil, sets: setCount)
                : Suggestion(text: text, chip: "Aim for \(def.hi) reps", up: false, weight: nil, sets: setCount)
        default:
            if allTop, let work, Exercises.legs.contains(key), holdLegs {
                return Suggestion(text: text, chip: "Hold at \(fmtNum(work)) lb", up: false, weight: work, sets: setCount)
            }
            if allTop {
                if let work {
                    let hand = def.wUnit == "lb/hand" ? " a hand" : ""
                    return Suggestion(text: text, chip: "↑ Add \(fmtNum(def.inc)) lb\(hand)", up: true, weight: round1(work + def.inc), sets: setCount)
                }
                return Suggestion(text: text, chip: def.bwUp ?? "↑ Ready to add weight", up: true, weight: nil, sets: setCount)
            }
            let chip = work.map { "Stay at \(fmtNum($0)) lb" } ?? "Aim for \(def.hi) \(def.kind == .carry ? "s" : "reps")"
            return Suggestion(text: text, chip: chip, up: false, weight: work, sets: setCount)
        }
    }

    /// The best number in a session for the progress chart: top weight, else top reps or seconds.
    static func metric(_ kind: ExerciseKind, _ sets: [LoggedSet]) -> (v: Double, unit: String)? {
        if kind == .time {
            let v = sets.compactMap(\.s).max() ?? 0
            return v > 0 ? (v, "s") : nil
        }
        if kind != .bw, let w = sets.compactMap(\.w).filter({ $0 > 0 }).max() { return (w, "lb") }
        let c = sets.compactMap { kind == .carry ? $0.s : $0.r }.filter { $0 > 0 }
        return c.max().map { ($0, kind == .carry ? "s" : "reps") }
    }
}
