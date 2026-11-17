import Foundation

// The plan itself: what each week asks for and how weeks map to dates. Compiled by the
// iPhone app and the watch app. Nothing here knows about logged sessions.

/// One planned run.
enum PlannedRun: Equatable {
    case runWalk(run: Double, walk: Double, reps: Int) // minutes
    case continuous(minutes: Int)                      // nonstop easy running
    case distance(miles: Double, goalPace: Double)     // miles, some at goal pace
    case race

    var minutes: Int {
        switch self {
        case let .runWalk(r, w, n): Int(((r + w) * Double(n)).rounded())
        case let .continuous(m): m
        default: 0
        }
    }

    var miles: Double? {
        switch self {
        case let .distance(m, _): m
        case .race: 13.1
        default: nil
        }
    }

    var describe: String {
        switch self {
        case .race: "13.1 mi. Start slower than you want to."
        case let .runWalk(r, w, n): "\(n) × (\(fmtNum(r)) min run, \(fmtNum(w)) min walk)"
        case let .continuous(m): "\(m) min nonstop, easy"
        case let .distance(m, gp): gp > 0 ? "\(fmtNum(m)) mi, middle \(fmtNum(gp)) at goal pace" : "\(fmtNum(m)) mi easy"
        }
    }

    /// What a calendar cell shows under the chip.
    var small: String {
        if let m = miles { return "\(fmtNum(m)) mi" }
        return "\(minutes) min"
    }

    var isRunWalk: Bool { if case .runWalk = self { true } else { false } }
}

enum RunSlot: String, CaseIterable, Identifiable {
    case r1, r2, long, extra
    var id: String { rawValue }
    var label: String {
        switch self {
        case .r1: "Run 1"
        case .r2: "Run 2"
        case .long: "Long"
        case .extra: "Extra"
        }
    }
}

struct Phase {
    let from: Int
    let to: Int
    let name: String
    let note: String
}

/// The 26-week half marathon plan, ending on race day: the run tables and the week math.
struct PlanCalendar {
    static let weeks = 26
    static let defaultRace: DayKey = "2027-05-15"
    static let liftDays = [0, 2] // Mon, Wed
    static let downWeeks: Set<Int> = [13, 17, 20, 22]

    private static func rw(_ r: Double, _ w: Double, _ n: Int) -> PlannedRun { .runWalk(run: r, walk: w, reps: n) }
    private static func c(_ m: Int) -> PlannedRun { .continuous(minutes: m) }
    private static func d(_ m: Double, _ gp: Double = 0) -> PlannedRun { .distance(miles: m, goalPace: gp) }

    /// Each week: Run 1, Run 2, Long run. Index 0 is week 1.
    static let runs: [[PlannedRun]] = [
        [rw(1, 1.5, 8), rw(1, 1.5, 8), rw(1, 1.5, 8)],
        [rw(1.5, 2, 6), rw(1.5, 2, 6), rw(1.5, 2, 6)],
        [rw(3, 3, 3), rw(3, 3, 3), rw(3, 3, 3)],
        [rw(4, 2, 4), rw(4, 2, 4), rw(4, 2, 4)],
        [rw(5, 3, 3), rw(8, 5, 2), c(20)],
        [rw(6, 3, 3), rw(10, 3, 2), c(25)],
        [c(25), c(25), c(25)],
        [c(28), c(28), c(28)],
        [c(30), c(30), c(30)],
        [d(2.5), d(2.5), d(3.5)],
        [d(3), d(2.5), d(4)],
        [d(3), d(3), d(4.5)],
        [d(3), d(2.5), d(4)],
        [d(3), d(3), d(5.5)],
        [d(3.5), d(3), d(6.5)],
        [d(3.5), d(3), d(7.5)],
        [d(3), d(3), d(6)],
        [d(4), d(3), d(8.5)],
        [d(4), d(3), d(10)],
        [d(3), d(3), d(7)],
        [d(4.5, 2), d(3), d(11)],
        [d(5, 2), d(3), d(9)],
        [d(5, 3), d(3), d(12)],
        [d(4, 2), d(3), d(9)],
        [d(3, 1), d(3), d(6)],
        [d(3, 1), d(2), .race],
    ]

    static let phases: [Phase] = [
        Phase(from: 1, to: 9, name: "Run/walk base",
              note: "This phase follows the NHS Couch to 5K progression: three sessions a week with a rest day between, the running stretches growing until you run 30 minutes nonstop in week 9. Walk 5 minutes before and after each one. Repeat any week that feels too hard."),
        Phase(from: 10, to: 17, name: "Build",
              note: "All running now, measured in miles: two short easy runs and a long run that grows from 3.5 to 7.5 miles. Every run stays at talking pace, and walk breaks are always allowed. Keep lifting twice a week."),
        Phase(from: 18, to: 24, name: "Half-specific",
              note: "The long run climbs to 12 miles. From week 21 a few midweek miles are at goal pace, and those are optional. Lifting becomes maintenance: two sets, and your leg weights stay where they are."),
        Phase(from: 25, to: 26, name: "Taper",
              note: "Two weeks with running cut by about half, keeping a touch of goal pace so your legs stay sharp. Lift lighter in week 25. In race week, one easy lift on Monday at most."),
    ]

    var raceDate: DayKey

    // MARK: Weeks

    var planStart: DayKey { Day.adding(-(PlanCalendar.weeks - 1) * 7, to: Day.weekStart(raceDate)) }
    func weekNo(_ day: DayKey) -> Int {
        guard Day.date(day) != nil else { return 0 }
        return Int((Double(Day.diff(Day.weekStart(day), planStart)) / 7).rounded(.down)) + 1
    }
    func weekDate(_ n: Int, _ offset: Int = 0) -> DayKey { Day.adding((n - 1) * 7 + offset, to: planStart) }
    static func phase(_ n: Int) -> Phase { phases.first { n >= $0.from && n <= $0.to } ?? phases[0] }
    static func liftTarget(_ n: Int) -> Int { n >= weeks ? 1 : 2 }

    static func slots(_ n: Int) -> [(slot: RunSlot, label: String, run: PlannedRun)] {
        let w = runs[min(max(n, 1), weeks) - 1]
        return [(.r1, "Run 1", w[0]), (.r2, "Run 2", w[1]), (.long, w[2] == .race ? "Race" : "Long", w[2])]
    }

    static func weekTotal(_ n: Int) -> String {
        let ws = runs[n - 1]
        if ws[0].miles != nil { return "\(fmtNum(round1(ws.reduce(0) { $0 + ($1.miles ?? 0) }))) mi" }
        return "\(ws.reduce(0) { $0 + $1.minutes }) min"
    }

    /// Mon … Sun labels for a week.
    func dayLabels(_ n: Int) -> [String] {
        if n < PlanCalendar.weeks { return ["Lift", "Run", "Lift", "Run", "", "Long", ""] }
        var out = ["Lift", "Run", "", "Run", "", "", ""]
        if Day.date(raceDate) != nil { out[Day.weekdayIndex(raceDate)] = "Race" }
        return out
    }

    static func liftNote(_ n: Int) -> String {
        if n >= weeks { return "Race week: one easy session on Monday at most. Skip leg press and calf raises if your legs feel at all heavy." }
        if n >= 25 { return "Taper: two easy sets, about 10% lighter on legs. Finish feeling like you could do more." }
        if n >= 18 { return "Maintenance block: two sets each, and your leg weights stay where they are so your legs are fresh for the long run. Upper body can still go up." }
        return "Warm up 5–10 min. Rest 60–90 s between sets. When you hit the top of the range on every set, the weight goes up next time. On leg moves, stop with a rep or two in hand so tomorrow's run isn't on tired legs. New to a move? Tap How to."
    }

    /// Which run a new run on this day most likely is, given the slots already logged that week.
    func autoSlot(_ day: DayKey, done: Set<RunSlot>) -> RunSlot {
        let n = weekNo(day)
        guard Day.date(day) != nil, n >= 1, n <= PlanCalendar.weeks else { return .extra }
        let weekend = Day.weekdayIndex(day) >= 5
        if !done.contains(.long), day == raceDate || (weekend && n < PlanCalendar.weeks) { return .long }
        if n == PlanCalendar.weeks, day > raceDate { return .extra }
        for k in [RunSlot.r1, .r2, .long] where !done.contains(k) && !(k == .long && n == PlanCalendar.weeks) { return k }
        return .extra
    }
}
