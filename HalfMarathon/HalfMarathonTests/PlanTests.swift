import Foundation
import SwiftData
import Testing
@testable import HalfMarathon

/// Invented sessions only.
@MainActor
struct PlanTests {
    func lift(_ date: DayKey, _ type: String, _ key: String, _ sets: [LoggedSet], kind: ExerciseKind = .reps) -> Session {
        Session(id: "\(date)-\(type)-test", date: date, type: type, name: "Workout \(type)", createdAt: 1,
                exercises: [LoggedExercise(key: key, name: key, kind: kind, sets: sets)])
    }

    @Test func weekNumbersEndOnRaceWeek() {
        let p = Plan(raceDate: "2027-05-15", sessions: [], today: "2026-11-16")
        #expect(p.weekNo("2027-05-15") == 26)
        #expect(p.weekNo("2027-05-10") == 26) // Monday of race week
        #expect(p.weekNo(p.planStart) == 1)
        #expect(Day.weekdayIndex(p.planStart) == 0)
        #expect(p.weekNo(Day.adding(-1, to: p.planStart)) == 0)
    }

    @Test func upNextAlternates() {
        let none = Plan(raceDate: Plan.defaultRace, sessions: [])
        #expect(none.upNext == .A)
        let p = Plan(raceDate: Plan.defaultRace, sessions: [lift("2026-11-10", "A", "legpress", [LoggedSet(w: 100, r: 10)])])
        #expect(p.upNext == .B)
    }

    @Test func addsWeightWhenEverySetHitsTheTop() {
        let s = lift("2026-11-10", "A", "chestpress", [LoggedSet(w: 60, r: 12), LoggedSet(w: 60, r: 12)])
        let p = Plan(raceDate: "2027-05-15", sessions: [s], today: "2026-11-16")
        let sug = p.suggest("chestpress")
        #expect(sug.up)
        #expect(sug.weight == 65)
        #expect(sug.chip == "↑ Add 5 lb")
    }

    @Test func staysWhenShortOfTheTop() {
        let s = lift("2026-11-10", "A", "chestpress", [LoggedSet(w: 60, r: 12), LoggedSet(w: 60, r: 10)])
        let sug = Plan(raceDate: "2027-05-15", sessions: [s], today: "2026-11-16").suggest("chestpress")
        #expect(!sug.up)
        #expect(sug.weight == 60)
    }

    @Test func holdsLegWeightsFromWeek18() {
        let s = lift("2027-03-15", "A", "legpress", [LoggedSet(w: 200, r: 12), LoggedSet(w: 200, r: 12)])
        let p = Plan(raceDate: "2027-05-15", sessions: [s], today: "2027-03-17")
        #expect(p.rawWeek == 18)
        #expect(p.suggest("legpress").chip == "Hold at 200 lb")
    }

    @Test func autoSlotPicksLongOnWeekends() {
        let p = Plan(raceDate: "2027-05-15", sessions: [], today: "2026-11-16")
        let monday = p.planStart
        #expect(p.autoSlot(Day.adding(1, to: monday)) == .r1)
        #expect(p.autoSlot(Day.adding(5, to: monday)) == .long)
        #expect(p.autoSlot("2027-05-15") == .long)
    }

    @Test func weekTotals() {
        #expect(Plan.weekTotal(1) == "60 min")
        #expect(Plan.weekTotal(23) == "20 mi")
        #expect(Plan.weekTotal(26) == "18.1 mi")
    }

    @Test func formatsSets() {
        #expect(Plan.fmtSets(.reps, [LoggedSet(w: 180, r: 10), LoggedSet(w: 180, r: 10)]) == "180 lb × 10, 10")
        #expect(Plan.fmtSets(.reps, [LoggedSet(r: 10)]) == "Bodyweight × 10")
        #expect(Plan.fmtSets(.carry, [LoggedSet(w: 30, s: 60)]) == "30 lb × 60 s")
        #expect(Plan.fmtSets(.time, [LoggedSet(s: 25)]) == "25 s")
    }

    @Test func importsTheWebLogAndSkipsRepeats() throws {
        let json = """
        {"raceDate": "2027-06-05", "sessions": [
          {"id": "2026-10-01-B-abc123", "date": "2026-10-01", "type": "B", "name": "Workout B", "createdAt": 1, "unit": "lb",
           "note": "", "finisherMin": null,
           "exercises": [{"key": "legpress", "kind": "reps", "name": "Leg press", "sets": [{"w": 90, "r": 10}, {"w": null, "r": 8}]}]},
          {"id": "2026-10-02-cardio-def456", "date": "2026-10-02", "type": "cardio", "activity": "run", "slot": "r1",
           "minutes": 22, "miles": null, "createdAt": 2}
        ]}
        """
        let container = try ModelContainer(for: Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = container.mainContext
        let first = try LogImporter.importLog(Data(json.utf8), into: ctx)
        #expect(first.added == 2)
        #expect(first.raceDate == "2027-06-05")
        let again = try LogImporter.importLog(Data(json.utf8), into: ctx)
        #expect(again.added == 0 && again.skipped == 2)
        let all = try ctx.fetch(FetchDescriptor<Session>())
        let b = try #require(all.first { $0.type == "B" })
        #expect(b.exercises.first?.sets.last?.w == nil)
        #expect(all.first { $0.isCardio }?.name == "Run")
    }

    @Test func buildsAStrengthSessionFromTypedSets() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let log = LogModel(defaults: defaults)
        var f = StrengthForm(.A)
        f.ex["legpress"] = [SetEntry(w: "100", n: "10", wt: true), SetEntry(w: "100", n: "", wt: false)]
        f.ex["plank"] = [SetEntry(w: "", n: "30")]
        log.setStrength(.A, f)
        let s = log.buildStrength(.A)
        #expect(s?.exercises.count == 2)
        #expect(s?.exercises.first { $0.key == "legpress" }?.sets == [LoggedSet(w: 100, r: 10)])
        #expect(s?.exercises.first { $0.key == "plank" }?.sets == [LoggedSet(s: 30)])
    }
}
