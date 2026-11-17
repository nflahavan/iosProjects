import Foundation

// How a planned run plays out on the watch: the run/walk schedule, the clock that times it,
// and the moments the wrist gets tapped. All of it is plain arithmetic on elapsed seconds
// (or miles), so it can be tested without a watch.

/// One stretch of a run/walk session.
struct Segment: Equatable {
    enum Kind: Equatable { case warmUp, run, walk, coolDown }
    var kind: Kind
    /// Seconds from the start of the session.
    var start: TimeInterval
    var duration: TimeInterval
    /// 1-based interval number for run and walk stretches, 0 for the warm-up and cool-down.
    var rep: Int

    var end: TimeInterval { start + duration }
    var title: String {
        switch kind {
        case .warmUp: "WARM UP"
        case .run: "RUN"
        case .walk: "WALK"
        case .coolDown: "COOL DOWN"
        }
    }
    /// How the next stretch is announced: "Run 1:00".
    var short: String {
        switch kind {
        case .warmUp: "Warm-up walk"
        case .run: "Run"
        case .walk: "Walk"
        case .coolDown: "Cool-down walk"
        }
    }
}

/// A tap on the wrist, at `at` seconds into a timed run or `at` miles into a measured one.
struct Cue: Equatable {
    enum Kind: Equatable { case headsUp, run, walk, goalPace, easy, finish }
    var at: Double
    var kind: Kind
}

/// A run/walk session: a warm-up walk, N × (run, walk), then a cool-down walk.
struct IntervalSchedule: Equatable {
    /// The plan's "walk 5 minutes before and after each one".
    static let walkAround: TimeInterval = 300
    /// How long before a change the heads-up tap comes.
    static let headsUp: TimeInterval = 5

    let segments: [Segment]
    let reps: Int

    /// `run` and `walk` are minutes, as in the plan; the warm-up and cool-down are seconds.
    init(run: Double, walk: Double, reps: Int,
         warmUp: TimeInterval = IntervalSchedule.walkAround, coolDown: TimeInterval = IntervalSchedule.walkAround) {
        var out: [Segment] = []
        var t: TimeInterval = 0
        func add(_ kind: Segment.Kind, _ seconds: TimeInterval, _ rep: Int) {
            guard seconds > 0 else { return }
            out.append(Segment(kind: kind, start: t, duration: seconds, rep: rep))
            t += seconds
        }
        add(.warmUp, warmUp, 0)
        for i in 0..<max(reps, 0) {
            add(.run, (run * 60).rounded(), i + 1)
            add(.walk, (walk * 60).rounded(), i + 1)
        }
        add(.coolDown, coolDown, 0)
        segments = out
        self.reps = max(reps, 0)
    }

    /// Nil unless the planned run is a run/walk one.
    init?(_ planned: PlannedRun) {
        guard case let .runWalk(r, w, n) = planned else { return nil }
        self.init(run: r, walk: w, reps: n)
    }

    var total: TimeInterval { segments.last?.end ?? 0 }
    /// Where each stretch after the first begins, and where the session ends.
    var boundaries: [TimeInterval] { segments.map(\.end) }
    /// The intervals themselves, without the warm-up and cool-down.
    var mainStart: TimeInterval { segments.first { $0.rep > 0 }?.start ?? 0 }
    var mainEnd: TimeInterval { segments.last { $0.rep > 0 }?.end ?? mainStart }

    struct Position: Equatable {
        var index: Int
        var segment: Segment
        var elapsed: TimeInterval
        var remaining: TimeInterval
    }

    /// The stretch a moment falls in. A boundary belongs to the stretch that starts there.
    /// Nil once the session is over.
    func position(at elapsed: TimeInterval) -> Position? {
        let e = max(elapsed, 0)
        guard let i = segments.firstIndex(where: { e < $0.end }) else { return nil }
        let s = segments[i]
        return Position(index: i, segment: s, elapsed: e - s.start, remaining: s.end - e)
    }

    func next(after index: Int) -> Segment? { segments.indices.contains(index + 1) ? segments[index + 1] : nil }

    /// Seconds spent in the intervals themselves, which is what a run/walk run is logged as:
    /// the plan's "8 × (1 min run, 1.5 min walk)" is a 20 minute run, not a 30 minute one.
    func mainElapsed(at elapsed: TimeInterval) -> TimeInterval {
        min(max(elapsed, mainStart), mainEnd) - mainStart
    }

    /// A heads-up before each change, then the change itself, in order.
    var cues: [Cue] {
        var out: [Cue] = []
        for (i, s) in segments.enumerated() {
            if s.duration > Self.headsUp * 2 { out.append(Cue(at: s.end - Self.headsUp, kind: .headsUp)) }
            guard let n = next(after: i) else { out.append(Cue(at: s.end, kind: .finish)); break }
            out.append(Cue(at: s.end, kind: n.kind == .run ? .run : .walk))
        }
        return out
    }
}

/// A run measured in miles, some of them in the middle at goal pace.
struct DistanceTarget: Equatable {
    var miles: Double
    var goalPace: Double = 0

    /// The plan's "middle N at goal pace": easy miles split evenly either side.
    var goalRange: ClosedRange<Double>? {
        guard goalPace > 0, goalPace < miles else { return nil }
        let lead = (miles - goalPace) / 2
        return lead...(lead + goalPace)
    }

    enum Zone: Equatable { case easy, goalPace, done }

    func zone(at done: Double) -> Zone {
        if done >= miles { return .done }
        if let g = goalRange, done >= g.lowerBound, done < g.upperBound { return .goalPace }
        return .easy
    }

    var cues: [Cue] {
        var out: [Cue] = []
        if let g = goalRange {
            out.append(Cue(at: g.lowerBound, kind: .goalPace))
            out.append(Cue(at: g.upperBound, kind: .easy))
        }
        out.append(Cue(at: miles, kind: .finish))
        return out
    }
}

/// What the watch does for a run.
enum RunProgram: Equatable {
    case intervals(IntervalSchedule)
    /// Nonstop running to a number of seconds.
    case timed(TimeInterval)
    case distance(DistanceTarget)
    /// A free run: no target.
    case open

    init(_ planned: PlannedRun) {
        switch planned {
        case let .runWalk(r, w, n): self = .intervals(IntervalSchedule(run: r, walk: w, reps: n))
        case let .continuous(m): self = .timed(TimeInterval(m) * 60)
        case let .distance(m, gp): self = .distance(DistanceTarget(miles: m, goalPace: gp))
        case .race: self = .distance(DistanceTarget(miles: 13.1))
        }
    }

    /// Cues by elapsed seconds.
    var timeCues: [Cue] {
        switch self {
        case let .intervals(s): s.cues
        case let .timed(t): (t > IntervalSchedule.headsUp * 2 ? [Cue(at: t - IntervalSchedule.headsUp, kind: .headsUp)] : [])
            + [Cue(at: t, kind: .finish)]
        case .distance, .open: []
        }
    }

    /// Cues by miles covered.
    var distanceCues: [Cue] {
        if case let .distance(d) = self { d.cues } else { [] }
    }

    /// The minutes to log for a run that took `elapsed` seconds. Run/walk runs leave out the
    /// warm-up and cool-down, unless the run ended before the first interval got going.
    func loggedMinutes(elapsed: TimeInterval) -> Double {
        if case let .intervals(s) = self {
            let main = s.mainElapsed(at: elapsed)
            if main >= 60 { return main / 60 }
        }
        return max(elapsed, 0) / 60
    }
}

extension [Cue] {
    /// The cues passed since `last`, up to and including `now`.
    func due(after last: Double, through now: Double) -> [Cue] { filter { $0.at > last && $0.at <= now } }
    func next(after now: Double) -> Cue? { first { $0.at > now } }
}

/// Times a workout from wall-clock dates, so nothing drifts or stops while the watch sleeps:
/// elapsed time is always worked out from "now", never counted up.
struct RunClock: Equatable {
    var start: Date
    var pausedAt: Date?
    /// Seconds spent in pauses that have ended.
    var pausedTotal: TimeInterval = 0

    var isPaused: Bool { pausedAt != nil }

    func elapsed(at now: Date) -> TimeInterval {
        max(0, (pausedAt ?? now).timeIntervalSince(start) - pausedTotal)
    }

    mutating func pause(at now: Date) {
        if pausedAt == nil { pausedAt = max(now, start) }
    }

    mutating func resume(at now: Date) {
        guard let p = pausedAt else { return }
        pausedTotal += max(0, now.timeIntervalSince(p))
        pausedAt = nil
    }

    /// When the clock will read `elapsed`, if it keeps running from `now` without a pause.
    func date(at elapsed: TimeInterval, from now: Date) -> Date {
        now.addingTimeInterval(elapsed - self.elapsed(at: now))
    }
}

/// "12:05", or "1:02:05" from an hour up.
func fmtClock(_ seconds: TimeInterval) -> String {
    let s = Int(max(seconds, 0).rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
