import Foundation
import SwiftData
import Testing
@testable import HalfMarathon

/// The logic the watch app shares with the phone: the interval schedule, the clock, the
/// payloads, and logging a run the watch sends. Invented runs only.
@MainActor
struct WatchTests {
    // MARK: Interval schedule

    /// Week 1: 8 × (1 min run, 1.5 min walk), with 5 minutes of walking either side.
    let week1 = IntervalSchedule(run: 1, walk: 1.5, reps: 8)

    @Test func scheduleIsWarmUpThenRepsThenCoolDown() {
        #expect(week1.segments.count == 18)
        #expect(week1.segments.first?.kind == .warmUp)
        #expect(week1.segments.last?.kind == .coolDown)
        #expect(week1.segments[1] == Segment(kind: .run, start: 300, duration: 60, rep: 1))
        #expect(week1.segments[2] == Segment(kind: .walk, start: 360, duration: 90, rep: 1))
        #expect(week1.segments[16] == Segment(kind: .walk, start: 1410, duration: 90, rep: 8))
        #expect(week1.reps == 8)
    }

    @Test func scheduleTotals() {
        #expect(week1.total == 30 * 60)
        #expect(week1.mainStart == 300)
        #expect(week1.mainEnd == 1500)
        #expect(week1.boundaries.prefix(3) == [300, 360, 450])
        #expect(week1.boundaries.last == 1800)
        // Every run/walk week in the plan: the intervals come to the plan's minutes, plus ten.
        for week in PlanCalendar.runs {
            for run in week {
                guard let s = IntervalSchedule(run) else { continue }
                #expect(s.mainEnd - s.mainStart == Double(run.minutes) * 60)
                #expect(s.total == Double(run.minutes) * 60 + 600)
                // Segments butt up against each other with no gaps.
                for (a, b) in zip(s.segments, s.segments.dropFirst()) { #expect(a.end == b.start) }
            }
        }
    }

    @Test func findsThePhaseForAnElapsedTime() throws {
        #expect(week1.position(at: 0)?.segment.kind == .warmUp)
        #expect(week1.position(at: 299.9)?.segment.kind == .warmUp)
        // A boundary belongs to the stretch that starts there.
        let firstRun = try #require(week1.position(at: 300))
        #expect(firstRun.segment.kind == .run && firstRun.segment.rep == 1)
        #expect(firstRun.remaining == 60 && firstRun.elapsed == 0)
        let walk3 = try #require(week1.position(at: 300 + 2 * 150 + 75))
        #expect(walk3.segment.kind == .walk && walk3.segment.rep == 3)
        #expect(walk3.elapsed == 15 && walk3.remaining == 75)
        #expect(week1.position(at: 1500)?.segment.kind == .coolDown)
        #expect(week1.position(at: 1799)?.remaining == 1)
        #expect(week1.position(at: 1800) == nil)
        #expect(week1.position(at: -5)?.index == 0)
    }

    @Test func cuesComeBeforeAndAtEachChange() {
        let s = IntervalSchedule(run: 3, walk: 3, reps: 1)
        #expect(s.cues == [
            Cue(at: 295, kind: .headsUp), Cue(at: 300, kind: .run),
            Cue(at: 475, kind: .headsUp), Cue(at: 480, kind: .walk),
            Cue(at: 655, kind: .headsUp), Cue(at: 660, kind: .walk), // into the cool-down
            Cue(at: 955, kind: .headsUp), Cue(at: 960, kind: .finish),
        ])
        #expect(s.cues.due(after: 295, through: 300.2) == [Cue(at: 300, kind: .run)])
        #expect(s.cues.due(after: 300, through: 300.2).isEmpty)
        #expect(s.cues.next(after: 300)?.at == 475)
        #expect(s.cues.next(after: 960) == nil)
    }

    @Test func runWalkRunsAreLoggedWithoutTheWarmUpAndCoolDown() {
        let p = RunProgram(.runWalk(run: 1, walk: 1.5, reps: 8))
        #expect(p.loggedMinutes(elapsed: 1800) == 20)
        #expect(p.loggedMinutes(elapsed: 2000) == 20)
        #expect(p.loggedMinutes(elapsed: 300 + 600) == 10)
        // Ended in the warm-up: log what there was.
        #expect(p.loggedMinutes(elapsed: 240) == 4)
        #expect(RunProgram(.continuous(minutes: 25)).loggedMinutes(elapsed: 1530) == 25.5)
    }

    @Test func programsFollowThePlannedRun() {
        #expect(RunProgram(.continuous(minutes: 25)) == .timed(1500))
        #expect(RunProgram(.continuous(minutes: 25)).timeCues == [Cue(at: 1495, kind: .headsUp), Cue(at: 1500, kind: .finish)])
        #expect(RunProgram(.race) == .distance(DistanceTarget(miles: 13.1)))
        #expect(RunProgram(.distance(miles: 3, goalPace: 0)).distanceCues == [Cue(at: 3, kind: .finish)])
    }

    @Test func goalPaceMilesSitInTheMiddle() {
        let d = DistanceTarget(miles: 5, goalPace: 3)
        #expect(d.goalRange == 1...4)
        #expect(d.zone(at: 0.99) == .easy)
        #expect(d.zone(at: 1) == .goalPace)
        #expect(d.zone(at: 3.99) == .goalPace)
        #expect(d.zone(at: 4) == .easy)
        #expect(d.zone(at: 5) == .done)
        #expect(d.cues == [Cue(at: 1, kind: .goalPace), Cue(at: 4, kind: .easy), Cue(at: 5, kind: .finish)])
        #expect(DistanceTarget(miles: 4).goalRange == nil)
    }

    // MARK: Clock

    @Test func clockCountsFromDatesAndSkipsPauses() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var c = RunClock(start: t0)
        #expect(c.elapsed(at: t0 + 90) == 90)
        c.pause(at: t0 + 100)
        #expect(c.isPaused)
        #expect(c.elapsed(at: t0 + 500) == 100)
        c.pause(at: t0 + 300) // already paused: no effect
        c.resume(at: t0 + 160)
        #expect(c.elapsed(at: t0 + 200) == 140)
        #expect(c.date(at: 300, from: t0 + 200) == t0 + 360)
        c.resume(at: t0 + 400) // not paused: no effect
        #expect(c.elapsed(at: t0 + 200) == 140)
        #expect(c.elapsed(at: t0 - 10) == 0)
        #expect(fmtClock(65) == "1:05")
        #expect(fmtClock(3725) == "1:02:05")
    }

    // MARK: Payloads

    @Test func runResultSurvivesTheTrip() throws {
        let r = WatchRunResult(id: "ABC-123", date: "2026-11-17", slot: "r1", minutes: 20, miles: 1.62, avgHeartRate: 141)
        let back = try #require(WatchRunResult(userInfo: r.userInfo))
        #expect(back == r)
        let bare = WatchRunResult(date: "2026-11-17", slot: "extra", minutes: 12)
        #expect(WatchRunResult(userInfo: bare.userInfo) == bare)
        #expect(!bare.id.isEmpty)
        // The dictionary holds only property-list values, as WatchConnectivity requires.
        #expect(PropertyListSerialization.propertyList(r.userInfo, isValidFor: .binary))
    }

    @Test func malformedPayloadsAreRejected() {
        #expect(WatchRunResult(userInfo: [:]) == nil)
        #expect(WatchRunResult(userInfo: [WatchRunResult.key: "not data"]) == nil)
        #expect(WatchRunResult(userInfo: [WatchRunResult.key: Data("{\"id\": 3}".utf8)]) == nil)
        #expect(WatchRunResult(userInfo: ["something.else": Data()]) == nil)
        #expect(PhoneContext(dictionary: [PhoneContext.key: Data("[]".utf8)]) == nil)
    }

    @Test func contextSurvivesTheTrip() throws {
        let c = PhoneContext(raceDate: "2027-06-05", doneRuns: [.init(date: "2026-12-08", slot: "r1")],
                             lastLift: .init(date: "2026-12-07", workout: "A"))
        #expect(PhoneContext(dictionary: c.dictionary) == c)
        #expect(PropertyListSerialization.propertyList(c.dictionary, isValidFor: .binary))
    }

    // MARK: What the watch offers

    @Test func watchOffersTheNextUnloggedRun() {
        // Week 1 starts Mon 2026-11-16.
        let none = WatchPlan(context: nil, today: "2026-11-17")
        #expect(none.calendar.raceDate == PlanCalendar.defaultRace)
        #expect(none.week == 1 && none.nextSlot == .r1)
        #expect(none.options.map(\.label) == ["Run 1", "Run 2", "Long"])
        #expect(none.upNext == .A)

        let ctx = PhoneContext(raceDate: "2027-05-15", doneRuns: [.init(date: "2026-11-17", slot: "r1")],
                               lastLift: .init(date: "2026-11-16", workout: "A"))
        let thu = WatchPlan(context: ctx, today: "2026-11-19")
        #expect(thu.nextSlot == .r2)
        #expect(thu.options.map(\.done) == [true, false, false])
        #expect(thu.upNext == .B)
        // Weekends offer the long run, as on the phone.
        #expect(WatchPlan(context: ctx, today: "2026-11-21").nextSlot == .long)
        // A run saved on the watch counts before the phone reports it back.
        let local = WatchPlan(context: ctx, localRuns: [.init(date: "2026-11-19", slot: "r2")],
                              localLift: .init(date: "2026-11-18", workout: "B"), today: "2026-11-20")
        #expect(local.nextSlot == .long)
        #expect(local.upNext == .A)
        // Last week's runs don't count this week.
        #expect(WatchPlan(context: ctx, today: "2026-11-24").nextSlot == .r1)
        // Before the plan starts there's nothing planned to offer.
        let before = WatchPlan(context: ctx, today: "2026-11-15")
        #expect(!before.inPlan && before.nextSlot == .extra && before.week == 1)
        // A race date that isn't a date falls back to the default.
        #expect(WatchPlan(context: PhoneContext(raceDate: "soon"), today: "2026-11-17").calendar.raceDate == PlanCalendar.defaultRace)
    }

    @Test func watchAgreesWithThePhoneAboutTheNextRun() {
        let run = Session(id: "2026-11-17-cardio-test", date: "2026-11-17", type: "cardio", name: "Run", createdAt: 1,
                          activity: "run", slot: "r1", minutes: 20)
        let lift = Session(id: "2026-11-16-A-test", date: "2026-11-16", type: "A", name: "Workout A", createdAt: 1,
                           exercises: [LoggedExercise(key: "legpress", name: "Leg press", kind: .reps, sets: [LoggedSet(w: 100, r: 10)])])
        let plan = Plan(raceDate: "2027-05-15", sessions: [run, lift], today: "2026-11-19")
        let ctx = WatchImporter.context(for: plan)
        #expect(ctx.doneRuns == [.init(date: "2026-11-17", slot: "r1")])
        #expect(ctx.lastLift == .init(date: "2026-11-16", workout: "A"))
        let watch = WatchPlan(context: ctx, today: plan.today)
        #expect(watch.nextSlot == plan.autoSlot(plan.today))
        #expect(watch.upNext == plan.upNext)
        #expect(watch.rawWeek == plan.rawWeek)
    }

    // MARK: Logging a watch run on the phone

    func store() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    @Test func watchRunBecomesACardioSession() throws {
        let ctx = try store()
        let r = WatchRunResult(id: "6F1C-22", date: "2026-11-17", slot: "r1", minutes: 20.04, miles: 1.62, avgHeartRate: 141.4)
        let s = try #require(try WatchImporter.importRun(r, into: ctx, raceDate: "2027-05-15", today: "2026-11-18"))
        #expect(s.isCardio && s.activity == "run" && s.name == "Run")
        #expect(s.slot == "r1" && s.date == "2026-11-17")
        #expect(s.minutes == 20 && s.miles == 1.6)
        #expect(s.note == "Apple Watch · avg 141 bpm")
        // The plan sees it exactly as it sees a run logged by hand.
        let all = try ctx.fetch(FetchDescriptor<Session>())
        let plan = Plan(raceDate: "2027-05-15", sessions: all, today: "2026-11-18")
        #expect(plan.runsDone(1)[.r1]?.id == s.id)
        #expect(plan.autoSlot("2026-11-19") == .r2)
        #expect(plan.runName(s) == "Run 1")
        #expect(Plan.loggedText(s) == "20 min · 1.6 mi")
    }

    @Test func aRunDeliveredTwiceIsLoggedOnce() throws {
        let ctx = try store()
        let r = WatchRunResult(id: "6F1C-22", date: "2026-11-17", slot: "r1", minutes: 20)
        #expect(try WatchImporter.importRun(r, into: ctx, raceDate: "2027-05-15", today: "2026-11-18") != nil)
        #expect(try WatchImporter.importRun(r, into: ctx, raceDate: "2027-05-15", today: "2026-11-18") == nil)
        // The same run, round-tripped through its dictionary, is still the same run.
        let again = try #require(WatchRunResult(userInfo: r.userInfo))
        #expect(try WatchImporter.importRun(again, into: ctx, raceDate: "2027-05-15", today: "2026-11-18") == nil)
        #expect(try ctx.fetchCount(FetchDescriptor<Session>()) == 1)
        // A different run the same day is its own session.
        let other = WatchRunResult(id: "9A00-01", date: "2026-11-17", slot: "extra", minutes: 10)
        #expect(try WatchImporter.importRun(other, into: ctx, raceDate: "2027-05-15", today: "2026-11-18") != nil)
        #expect(try ctx.fetchCount(FetchDescriptor<Session>()) == 2)
    }

    @Test func badWatchRunsAreIgnored() throws {
        let ctx = try store()
        let bad = [
            WatchRunResult(id: "a", date: "tomorrow", slot: "r1", minutes: 20),
            WatchRunResult(id: "b", date: "2026-11-17", slot: "r9", minutes: 20),
            WatchRunResult(id: "c", date: "2026-11-17", slot: "r1", minutes: 0),
            WatchRunResult(id: "d", date: "2026-11-17", slot: "r1", minutes: -.infinity),
            WatchRunResult(id: "e", date: "2026-11-17", slot: "r1", minutes: .nan),
            WatchRunResult(id: "", date: "2026-11-17", slot: "r1", minutes: 20),
        ]
        for r in bad { #expect(try WatchImporter.importRun(r, into: ctx, raceDate: "2027-05-15", today: "2026-11-18") == nil) }
        #expect(try ctx.fetchCount(FetchDescriptor<Session>()) == 0)
    }

    @Test func freeRunsAndRunsOutsideThePlanHaveNoSlot() throws {
        let cal = PlanCalendar(raceDate: "2027-05-15")
        let free = try #require(WatchImporter.session(from: WatchRunResult(id: "f", date: "2026-11-17", slot: "extra", minutes: 15), calendar: cal, today: "2026-11-18"))
        #expect(free.slot == nil && free.miles == nil && free.note == "Apple Watch")
        let early = try #require(WatchImporter.session(from: WatchRunResult(id: "g", date: "2026-11-10", slot: "r1", minutes: 15, miles: -2), calendar: cal, today: "2026-11-18"))
        #expect(early.slot == nil && early.miles == nil)
        let late = try #require(WatchImporter.session(from: WatchRunResult(id: "i", date: "2026-11-20", slot: "r2", minutes: 15), calendar: cal, today: "2026-11-18"))
        #expect(late.date == "2026-11-18" && late.slot == "r2")
        let long = try #require(WatchImporter.session(from: WatchRunResult(id: "h", date: "2026-11-10", slot: "long", minutes: 9000, miles: 0.04), calendar: cal, today: "2026-11-18"))
        #expect(long.minutes == 600 && long.miles == nil)
    }
    // MARK: Lifts from the watch

    let watchLift = WatchLiftResult(id: "ABC-123", date: "2026-11-18", workout: "B", exercises: [
        .init(key: "legpress", sets: [.init(w: 180, n: 12), .init(w: 180, n: 11)]),
        .init(key: "backext", sets: [.init(w: nil, n: 10)]),
        .init(key: "carry", sets: [.init(w: 30, n: 45)]),
        .init(key: "plank", sets: [.init(w: 25, n: 30)]),
        .init(key: "unknown", sets: [.init(w: 10, n: 10)]),
        .init(key: "calf", sets: [.init(w: 100, n: 0)]),
    ], avgHeartRate: 111.6)

    @Test func liftPayloadRoundTrips() {
        #expect(WatchLiftResult(userInfo: watchLift.userInfo) == watchLift)
        #expect(WatchLiftResult(userInfo: [:]) == nil)
        // A run payload isn't a lift, and the other way round.
        #expect(WatchRunResult(userInfo: watchLift.userInfo) == nil)
    }

    @Test func watchLiftBecomesALoggedWorkout() throws {
        let s = try #require(WatchImporter.session(from: watchLift, today: "2026-11-18"))
        #expect(s.type == "B" && s.name == "Workout B" && s.isLift)
        #expect(s.date == "2026-11-18")
        #expect(s.note == "Apple Watch · avg 112 bpm")
        // Unknown exercises and sets with nothing counted are dropped.
        #expect(s.exercises.map(\.key) == ["legpress", "backext", "carry", "plank"])
        #expect(s.exercises[0].sets == [LoggedSet(w: 180, r: 12), LoggedSet(w: 180, r: 11)])
        #expect(s.exercises[1].sets == [LoggedSet(r: 10)])
        #expect(s.exercises[2].sets == [LoggedSet(w: 30, s: 45)])
        // A plank is timed: a weight sent with it is ignored.
        #expect(s.exercises[3].sets == [LoggedSet(s: 30)])
    }

    @Test func malformedLiftsAreIgnored() {
        var bad = watchLift
        bad.workout = "C"
        #expect(WatchImporter.session(from: bad) == nil)
        bad = watchLift
        bad.date = "yesterday"
        #expect(WatchImporter.session(from: bad) == nil)
        bad = watchLift
        bad.exercises = [.init(key: "legpress", sets: [])]
        #expect(WatchImporter.session(from: bad) == nil)
    }

    @Test func watchLiftIsLoggedOnceAndMovesThePlanOn() throws {
        let container = try ModelContainer(for: Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = container.mainContext
        #expect(try WatchImporter.importLift(watchLift, into: ctx, today: "2026-11-18") != nil)
        #expect(try WatchImporter.importLift(watchLift, into: ctx, today: "2026-11-18") == nil)
        let all = try ctx.fetch(FetchDescriptor<Session>())
        #expect(all.count == 1)
        let plan = Plan(raceDate: "2027-05-15", sessions: all, today: "2026-11-19")
        #expect(plan.upNext == .A)
        // The next context tells the watch what to aim for, as the phone's form would.
        let hints = try #require(WatchImporter.context(for: plan).liftHints)
        #expect(hints["legpress"] == .init(weight: 180, count: 12, sets: 2, chip: "Stay at 180 lb"))
        #expect(hints["backext"]?.weight == nil)
        #expect(hints["carry"]?.count == 45)
        #expect(hints["shoulder"] == .init(weight: nil, count: nil, sets: 2, chip: ""))
    }

    @Test func contextWithoutHintsStillDecodes() throws {
        // What a phone app from before lift logging sent.
        let old = Data(#"{"raceDate":"2027-05-15","doneRuns":[]}"#.utf8)
        let c = try #require(PhoneContext(dictionary: [PhoneContext.key: old]))
        #expect(c.liftHints == nil)
    }
}
