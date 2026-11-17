import Foundation
import HealthKit
import Observation

/// A run in progress.
struct ActiveRun {
    var slot: RunSlot
    var title: String
    var program: RunProgram
    var clock: RunClock
    /// The last cues played, as elapsed seconds and as miles, so each plays once.
    var lastTimeCue: Double = 0
    var lastMilesCue: Double = 0
}

typealias LiftSet = WatchLiftResult.LiftSet

/// A lifting session in progress: the sets logged, and the rest since the last one.
struct ActiveLift {
    /// The plan's "rest 60–90 s between sets".
    static let restReady: TimeInterval = 60
    static let restOver: TimeInterval = 90
    static let plannedSets = 2

    var workout: Workout
    var clock: RunClock
    /// Sets logged so far, by exercise key.
    var logged: [String: [LiftSet]] = [:]
    /// What the phone suggests for each exercise, from last time.
    var hints: [String: PhoneContext.LiftHint] = [:]
    var restStart: Date?
    /// How many of the two rest taps have played for this rest.
    var restCues = 0

    func setsDone(_ key: String) -> Int { logged[key]?.count ?? 0 }
    /// Sets shown for an exercise: as many as last time, or more once you've done more.
    func setsShown(_ key: String) -> Int { max(hints[key]?.sets ?? Self.plannedSets, setsDone(key)) }
    var totalDone: Int { logged.values.reduce(0) { $0 + $1.count } }

    /// What the next set of an exercise most likely is: the same as the set before it, or
    /// the phone's suggestion for the first one.
    func proposal(_ key: String) -> LiftSet {
        if let last = logged[key]?.last { return last }
        let def = Exercises.def(key)
        let hint = hints[key]
        return LiftSet(w: def?.hasWeight == true ? hint?.weight : nil, n: hint?.count ?? Double(def?.lo ?? 10))
    }

    /// The sets in workout order, for the phone's log.
    var entries: [WatchLiftResult.Entry] {
        workout.items.compactMap { key in
            guard let sets = logged[key], !sets.isEmpty else { return nil }
            return WatchLiftResult.Entry(key: key, sets: sets)
        }
    }
}

/// A finished workout, waiting for Save or Discard.
struct Summary {
    enum Kind { case run(RunSlot), lift(Workout) }
    var kind: Kind
    var title: String
    var date: DayKey
    var elapsed: TimeInterval
    /// What a run is logged as on the phone. Differs from `elapsed` for run/walk runs.
    var loggedMinutes: Double = 0
    var sets = 0
    var lift: [WatchLiftResult.Entry] = []
}

/// Everything the watch app does: which workout is on, its clock, its cues, and where the
/// result goes.
@Observable
final class WorkoutModel {
    let manager = WorkoutManager()
    let link = WatchLink()

    private(set) var run: ActiveRun?
    private(set) var lift: ActiveLift?
    private(set) var summary: Summary?
    private(set) var saving = false
    /// Set by the debug launch arguments: no HealthKit, no phone, made-up readings.
    private(set) var demo = false
    @ObservationIgnored var todayOverride: DayKey?

    @ObservationIgnored private var cueTask: Task<Void, Never>?
    @ObservationIgnored private var endTask: Task<Void, Never>?

    init() {
        #if DEBUG
        demo = ProcessInfo.processInfo.arguments.contains { $0 == "-demoRun" || $0 == "-demo" }
        #endif
        link.start(live: !demo)
        manager.onPause = { [weak self] paused, date in self?.setPaused(paused, at: date, tellHealth: false) }
        manager.onStats = { [weak self] in self?.playDistanceCues() }
        #if DEBUG
        debugLaunch()
        #endif
    }

    var today: DayKey { todayOverride ?? Day.today() }
    var plan: WatchPlan { link.plan(today: today) }
    var isPaused: Bool { run?.clock.isPaused ?? lift?.clock.isPaused ?? false }

    // MARK: Starting

    /// `planned` nil is a free run.
    func startRun(slot: RunSlot, title: String, planned: PlannedRun?, at now: Date = .now) {
        guard run == nil, lift == nil, summary == nil else { return }
        run = ActiveRun(slot: slot, title: title, program: planned.map(RunProgram.init) ?? .open, clock: RunClock(start: now))
        if !demo { manager.begin(.running, location: .outdoor, at: now) }
        Haptics.begin()
        scheduleCues()
    }

    func startLift(_ workout: Workout, at now: Date = .now) {
        guard run == nil, lift == nil, summary == nil else { return }
        lift = ActiveLift(workout: workout, clock: RunClock(start: now), hints: link.liftHints)
        if !demo { manager.begin(.traditionalStrengthTraining, location: .indoor, at: now) }
        Haptics.begin()
    }

    // MARK: Pausing and ending

    func togglePause() { setPaused(!isPaused, at: .now, tellHealth: true) }

    private func setPaused(_ paused: Bool, at date: Date, tellHealth: Bool) {
        guard paused != isPaused else { return }
        if paused { run?.clock.pause(at: date); lift?.clock.pause(at: date) }
        else { run?.clock.resume(at: date); lift?.clock.resume(at: date) }
        if tellHealth { if paused { manager.pause() } else { manager.resume() } }
        scheduleCues()
    }

    func end(at now: Date = .now) {
        cueTask?.cancel()
        let day = Day.key
        if let run {
            let e = run.clock.elapsed(at: now)
            summary = Summary(kind: .run(run.slot), title: run.title, date: day(run.clock.start), elapsed: e,
                              loggedMinutes: run.program.loggedMinutes(elapsed: e))
        } else if let lift {
            summary = Summary(kind: .lift(lift.workout), title: lift.workout.label, date: day(lift.clock.start),
                              elapsed: lift.clock.elapsed(at: now), sets: lift.totalDone, lift: lift.entries)
        }
        run = nil
        lift = nil
        endTask = Task { await manager.end(at: now) }
    }

    /// Sends the run or lift to the phone and saves the workout to Health.
    func save() async {
        guard let s = summary, !saving else { return }
        saving = true
        await endTask?.value
        switch s.kind {
        case let .run(slot):
            let miles = (manager.miles * 100).rounded() / 100
            link.send(WatchRunResult(date: s.date, slot: slot.rawValue, minutes: max(round1(s.loggedMinutes), 0.1),
                                     miles: miles > 0 ? miles : nil, avgHeartRate: manager.avgHeartRate))
        case let .lift(workout):
            link.noteLift(workout, on: s.date)
            if !s.lift.isEmpty {
                link.send(WatchLiftResult(date: s.date, workout: workout.rawValue, exercises: s.lift,
                                          avgHeartRate: manager.avgHeartRate))
            }
        }
        await manager.finish(save: true)
        finishUp()
    }

    func discard() async {
        guard summary != nil, !saving else { return }
        saving = true
        await endTask?.value
        await manager.finish(save: false)
        finishUp()
    }

    private func finishUp() {
        saving = false
        summary = nil
        manager.reset()
    }

    // MARK: Lifting

    /// Logs the next set of an exercise and starts the rest. With no `set`, logs the proposal.
    func markSet(_ key: String, _ set: LiftSet? = nil, at now: Date = .now) {
        guard var l = lift, l.setsDone(key) < Exercises.maxSets else { return }
        l.logged[key, default: []].append(set ?? l.proposal(key))
        l.restStart = now
        l.restCues = 0
        lift = l
        Haptics.click()
        scheduleCues()
    }

    func undoSet(_ key: String) {
        guard var l = lift, l.setsDone(key) > 0 else { return }
        l.logged[key]?.removeLast()
        l.restStart = nil
        lift = l
        scheduleCues()
    }

    func skipRest() {
        lift?.restStart = nil
        scheduleCues()
    }

    // MARK: Cues

    /// Sleeps until the next cue is due, then plays it. The time left is worked out from the
    /// clock on every pass, so a late wake-up can't make the cues drift.
    private func scheduleCues() {
        cueTask?.cancel()
        cueTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.playDueCues(at: .now) else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Plays what's due. Returns how long until the next look, or nil when nothing's coming.
    private func playDueCues(at now: Date) -> TimeInterval? {
        if var r = run {
            guard !r.clock.isPaused else { return nil }
            let e = r.clock.elapsed(at: now)
            let cues = r.program.timeCues
            if let last = cues.due(after: r.lastTimeCue, through: e).last {
                // A heads-up that's late has nothing left to warn of.
                if last.kind != .headsUp || e - last.at < 3 { Haptics.play(last.kind) }
                r.lastTimeCue = last.at
                run = r
            }
            guard let next = cues.next(after: e) else { return nil }
            return min(max(next.at - e, 0.05), 15)
        }
        if var l = lift, let rest = l.restStart {
            let e = now.timeIntervalSince(rest)
            let marks = [ActiveLift.restReady, ActiveLift.restOver]
            let passed = marks.filter { $0 <= e }.count
            if passed > l.restCues {
                Haptics.rest(over: passed == marks.count)
                l.restCues = passed
                lift = l
            }
            guard let next = marks.first(where: { $0 > e }) else { return nil }
            return min(max(next - e, 0.05), 15)
        }
        return nil
    }

    private func playDistanceCues() {
        guard var r = run else { return }
        let miles = manager.miles
        guard let last = r.program.distanceCues.due(after: r.lastMilesCue, through: miles).last else { return }
        Haptics.play(last.kind)
        r.lastMilesCue = last.at
        run = r
    }

    // MARK: Debug

    #if DEBUG
    /// `-today 2026-11-17` pretends it's that day. `-demoRun r1|r2|long|free|A|B` starts that
    /// workout at once without HealthKit, `-demoElapsed 700` that many seconds in, with
    /// made-up heart rate and distance, for screenshots in the simulator.
    private func debugLaunch() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        if let t = value("-today"), Day.date(t) != nil { todayOverride = t }
        guard let what = value("-demoRun") else { return }
        let elapsed = value("-demoElapsed").flatMap(Double.init) ?? 0
        let start = Date.now.addingTimeInterval(-elapsed)
        if let w = Workout(rawValue: what) {
            startLift(w, at: start)
            for (i, key) in w.items.prefix(2).enumerated() {
                markSet(key, LiftSet(w: key == "legpress" ? 180 : 32.5, n: 10), at: start)
                if i == 0 { markSet(key, at: start) }
            }
            lift?.restStart = Date.now.addingTimeInterval(-42)
            scheduleCues()
            manager.heartRate = 104
            return
        }
        let p = plan
        if let o = p.options.first(where: { $0.slot.rawValue == what }) {
            startRun(slot: o.slot, title: RunChoice.title(o.slot, label: o.label), planned: o.run, at: start)
        } else {
            startRun(slot: .extra, title: "Free run", planned: nil, at: start)
        }
        manager.heartRate = 142
        manager.avgHeartRate = 138
        manager.meters = elapsed / 660 * 1609.344
    }
    #endif
}
