import Foundation
import Observation
import SwiftData

enum LogMode: String, Codable, CaseIterable, Identifiable {
    case A, B, cardio
    var id: String { rawValue }
    var workout: Workout? { Workout(rawValue: rawValue) }
}

/// One set as typed. `wt` = the weight was typed by you, so it stops following the suggestion.
struct SetEntry: Codable, Hashable {
    var w = ""
    var n = ""
    var wt = false
}

struct StrengthForm: Codable, Equatable {
    var date: DayKey
    var finisher = ""
    var note = ""
    var ex: [String: [SetEntry]] = [:]

    init(_ workout: Workout, date: DayKey = Day.today()) {
        self.date = date
        for k in workout.items { ex[k] = [] }
    }

    var isDirty: Bool {
        !finisher.isEmpty || !note.isEmpty || ex.values.contains { $0.contains { !$0.n.isEmpty || $0.wt } }
    }
}

struct CardioForm: Codable, Equatable {
    var date: DayKey = Day.today()
    var activity: String = Activity.run.rawValue
    var slot: String = "" // empty = pick automatically
    var min = ""
    var mi = ""
    var note = ""

    var isDirty: Bool { !min.isEmpty || !mi.isEmpty || !note.isEmpty }
    var isRun: Bool { activity == Activity.run.rawValue }
}

/// The Log tab's state: the three forms, which one is showing, and an edit in progress.
/// The forms are kept as a draft on the phone so a half-logged workout survives the app closing.
@Observable
final class LogModel {
    struct Editing {
        let id: String
        let mode: LogMode
        let createdAt: Double
        let backupStrength: StrengthForm?
        let backupCardio: CardioForm?
        let prevMode: LogMode
        let prevChosen: Bool
        /// Exercises no longer in the workout, kept exactly as logged.
        let extra: [LoggedExercise]
    }

    private struct Draft: Codable {
        var a: StrengthForm
        var b: StrengthForm
        var cardio: CardioForm
        var mode: LogMode
        var modeChosen: Bool
    }

    var a: StrengthForm
    var b: StrengthForm
    var cardio: CardioForm
    var mode: LogMode = .A
    var modeChosen = false
    var editing: Editing?

    private static let draftKey = "draft.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        a = StrengthForm(.A)
        b = StrengthForm(.B)
        if let data = defaults.data(forKey: Self.draftKey), let d = try? JSONDecoder().decode(Draft.self, from: data) {
            a = d.a.isDirty ? d.a : StrengthForm(.A)
            b = d.b.isDirty ? d.b : StrengthForm(.B)
            cardio = d.cardio.isDirty ? d.cardio : CardioForm()
            let dirty: [LogMode: Bool] = [.A: a.isDirty, .B: b.isDirty, .cardio: cardio.isDirty]
            if dirty[d.mode] == true { mode = d.mode; modeChosen = true }
        } else {
            cardio = CardioForm()
        }
    }

    func strength(_ w: Workout) -> StrengthForm { w == .A ? a : b }
    func setStrength(_ w: Workout, _ f: StrengthForm) { if w == .A { a = f } else { b = f } }

    func persist() {
        // While fixing a saved session, the in-progress workout stays the draft.
        var d = Draft(a: a, b: b, cardio: cardio, mode: mode, modeChosen: modeChosen)
        if let e = editing {
            if let s = e.backupStrength, let w = e.mode.workout { if w == .A { d.a = s } else { d.b = s } }
            if let c = e.backupCardio { d.cardio = c }
            d.mode = e.prevMode
            d.modeChosen = e.prevChosen
        }
        if let data = try? JSONEncoder().encode(d) { defaults.set(data, forKey: Self.draftKey) }
    }

    /// Untouched forms move to today when the day changes.
    func rollToToday() {
        let t = Day.today()
        if !a.isDirty { a.date = t }
        if !b.isDirty { b.date = t }
        if !cardio.isDirty { cardio.date = t }
    }

    /// Follows the plan to the next workout unless you picked one or started typing.
    func follow(_ plan: Plan) {
        guard !modeChosen, editing == nil, let w = mode.workout, !strength(w).isDirty else { return }
        if plan.upNext != w { mode = LogMode(rawValue: plan.upNext.rawValue)! }
    }

    // MARK: Sets

    /// Gives each exercise as many empty sets as last time, if it has none typed yet.
    func prepareSets(_ w: Workout, plan: Plan) {
        var f = strength(w)
        var changed = false
        for k in w.items {
            let sug = plan.suggest(k, skipping: editing?.id)
            var sets = f.ex[k] ?? []
            if sets.allSatisfy({ $0.n.isEmpty && !$0.wt }) && sets.count < sug.sets {
                while sets.count < sug.sets { sets.append(SetEntry()) }
                changed = true
            }
            if fill(&sets, key: k, suggested: sug.weight) { changed = true }
            f.ex[k] = sets
        }
        if changed { setStrength(w, f) }
    }

    /// Untouched weight boxes follow the suggestion, or the set above that you typed.
    @discardableResult
    func fill(_ sets: inout [SetEntry], key: String, suggested: Double?) -> Bool {
        guard Exercises.def(key)?.hasWeight == true else { return false }
        var carry = suggested.map { fmtNum($0) } ?? ""
        var changed = false
        for i in sets.indices {
            if sets[i].wt { carry = sets[i].w; continue }
            if sets[i].w != carry { sets[i].w = carry; changed = true }
        }
        return changed
    }

    func setWeight(_ w: Workout, key: String, index: Int, value: String, plan: Plan) {
        var f = strength(w)
        guard var sets = f.ex[key], sets.indices.contains(index) else { return }
        sets[index].w = value
        sets[index].wt = true
        fill(&sets, key: key, suggested: plan.suggest(key, skipping: editing?.id).weight)
        f.ex[key] = sets
        setStrength(w, f)
        persist()
    }

    func setCount(_ w: Workout, key: String, index: Int, value: String) {
        var f = strength(w)
        guard f.ex[key]?.indices.contains(index) == true else { return }
        f.ex[key]![index].n = value
        setStrength(w, f)
        persist()
    }

    func addSet(_ w: Workout, key: String, plan: Plan) {
        var f = strength(w)
        var sets = f.ex[key] ?? []
        guard sets.count < Exercises.maxSets else { return }
        sets.append(SetEntry())
        fill(&sets, key: key, suggested: plan.suggest(key, skipping: editing?.id).weight)
        f.ex[key] = sets
        setStrength(w, f)
        persist()
    }

    func removeSet(_ w: Workout, key: String) {
        var f = strength(w)
        guard var sets = f.ex[key], sets.count > 1 else { return }
        sets.removeLast()
        f.ex[key] = sets
        setStrength(w, f)
        persist()
    }

    func completedSets(_ w: Workout) -> Int {
        let f = strength(w)
        return w.items.reduce(0) { $0 + (f.ex[$1] ?? []).filter { (parseNum($0.n) ?? 0) > 0 }.count }
    }

    // MARK: Building sessions

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
    static func validDate(_ d: DayKey) -> DayKey { let t = Day.today(); return Day.date(d) != nil && d <= t ? d : t }

    func buildStrength(_ w: Workout) -> Session? {
        let f = strength(w)
        var exercises: [LoggedExercise] = []
        for k in w.items {
            guard let def = Exercises.def(k) else { continue }
            var sets: [LoggedSet] = []
            for s in f.ex[k] ?? [] {
                guard let n = parseNum(s.n), n > 0 else { continue }
                let wv = parseNum(s.w) ?? 0
                let weight = wv > 0 ? round1(Self.clamp(wv, 0, 2000)) : nil
                switch def.kind {
                case .reps: sets.append(LoggedSet(w: weight, r: round1(Self.clamp(n, 0, 500))))
                case .bw: sets.append(LoggedSet(r: round1(Self.clamp(n, 0, 500))))
                case .time: sets.append(LoggedSet(s: round1(Self.clamp(n, 0, 3600))))
                case .carry: sets.append(LoggedSet(w: weight, s: round1(Self.clamp(n, 0, 3600))))
                }
            }
            if !sets.isEmpty { exercises.append(LoggedExercise(key: k, name: def.name, kind: def.kind, sets: sets)) }
        }
        guard !exercises.isEmpty else { return nil }
        let fin = parseNum(f.finisher) ?? 0
        let date = Self.validDate(f.date)
        return Session(id: Session.newID(date: date, type: w.rawValue), date: date, type: w.rawValue, name: w.label,
                       createdAt: Date.now.timeIntervalSince1970 * 1000,
                       note: String(f.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)),
                       exercises: exercises, finisherMin: fin > 0 ? round1(Self.clamp(fin, 0, 600)) : nil)
    }

    func buildCardio(plan: Plan) -> Session? {
        let f = cardio
        guard let m = parseNum(f.min), m > 0 else { return nil }
        let mi = parseNum(f.mi) ?? 0
        let activity = Activity(rawValue: f.activity) ?? .other
        let date = Self.validDate(f.date)
        let wk = plan.weekNo(date)
        var slot: RunSlot?
        if activity == .run, wk >= 1, wk <= Plan.weeks {
            slot = RunSlot(rawValue: f.slot) ?? plan.autoSlot(date, skipping: editing?.id)
        }
        return Session(id: Session.newID(date: date, type: "cardio"), date: date, type: "cardio", name: activity.label,
                       createdAt: Date.now.timeIntervalSince1970 * 1000,
                       note: String(f.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)),
                       activity: activity.rawValue, slot: slot == .extra ? nil : slot?.rawValue,
                       minutes: round1(Self.clamp(m, 0, 600)), miles: mi > 0 ? round1(Self.clamp(mi, 0, 200)) : nil)
    }

    // MARK: Saving

    /// Saves the showing form. Returns the message for the toast.
    func save(context: ModelContext, plan: Plan) throws -> String? {
        if editing != nil { return try saveEdit(context: context, plan: plan) }
        let doc: Session?
        if let w = mode.workout { doc = buildStrength(w) } else { doc = buildCardio(plan: plan) }
        guard let doc else { return nil }
        context.insert(doc)
        try context.save()
        if let w = mode.workout { setStrength(w, StrengthForm(w)); modeChosen = false } else { cardio = CardioForm() }
        persist()
        return savedMessage(doc, plan: plan)
    }

    private func savedMessage(_ s: Session, plan: Plan) -> String {
        if s.isCardio { return "Saved: \(plan.runName(s)), \(fmtNum(s.minutes)) min." }
        let sets = s.exercises.reduce(0) { $0 + $1.sets.count }
        var msg = "Saved \(s.name), \(plural(sets, "set", "sets"))."
        if s.date == Day.today() {
            for i in 1...7 {
                let d = Day.adding(i, to: s.date)
                if Plan.liftDays.contains(Day.weekdayIndex(d)) {
                    msg += " Next up: Workout \(s.type == "A" ? "B" : "A") on \(Day.weekdayName(d))."
                    break
                }
            }
        }
        return msg
    }

    func startEdit(_ s: Session) {
        guard editing == nil else { return }
        let m: LogMode = s.isLift ? LogMode(rawValue: s.type)! : .cardio
        let txt: (Double?) -> String = { ($0 ?? 0) > 0 ? fmtNum($0) : "" }
        let date = Day.date(s.date) != nil ? s.date : Day.today()
        var extra: [LoggedExercise] = []
        var backupS: StrengthForm?
        var backupC: CardioForm?
        if let w = m.workout {
            backupS = strength(w)
            var f = StrengthForm(w, date: date)
            f.finisher = txt(s.finisherMin)
            f.note = s.note
            for e in s.liftExercises {
                guard f.ex[e.key] != nil, let def = Exercises.def(e.key) else { extra.append(e); continue }
                f.ex[e.key] = e.sets.prefix(Exercises.maxSets).map {
                    SetEntry(w: txt($0.w), n: txt(def.countsReps ? $0.r : $0.s), wt: true)
                }
            }
            setStrength(w, f)
        } else {
            backupC = cardio
            cardio = CardioForm(date: date, activity: Activity(rawValue: s.activity ?? "")?.rawValue ?? "other",
                                slot: RunSlot(rawValue: s.slot ?? "")?.rawValue ?? RunSlot.extra.rawValue,
                                min: txt(s.minutes), mi: txt(s.miles), note: s.note)
        }
        editing = Editing(id: s.id, mode: m, createdAt: s.createdAt, backupStrength: backupS, backupCardio: backupC,
                          prevMode: mode, prevChosen: modeChosen, extra: extra)
        mode = m
        modeChosen = true
    }

    func cancelEdit() {
        guard let e = editing else { return }
        editing = nil
        if let s = e.backupStrength, let w = e.mode.workout { setStrength(w, s) }
        if let c = e.backupCardio { cardio = c }
        mode = e.prevMode
        modeChosen = e.prevChosen
        persist()
    }

    private func saveEdit(context: ModelContext, plan: Plan) throws -> String? {
        guard let e = editing else { return nil }
        let built: Session?
        if let w = e.mode.workout { built = buildStrength(w) } else { built = buildCardio(plan: plan) }
        guard let doc = built else { return nil }
        let id = e.id
        guard let s = try context.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })).first else { return nil }
        s.date = doc.date
        s.name = doc.name
        s.note = doc.note
        s.updatedAt = Date.now.timeIntervalSince1970 * 1000
        s.exercises = doc.exercises + (s.isLift ? e.extra : [])
        s.finisherMin = doc.finisherMin
        s.activity = doc.activity
        s.slot = doc.slot
        s.minutes = doc.minutes
        s.miles = doc.miles
        try context.save()
        cancelEdit()
        return s.isCardio ? "Updated: \(plan.runName(s)), \(fmtNum(s.minutes)) min." : "Updated \(s.name) from \(Day.long(s.date))."
    }

    /// Opens the log on a given day from the calendar.
    func logDay(_ day: DayKey, plan: Plan) {
        guard editing == nil, Day.date(day) != nil, day <= Day.today() else { return }
        let p = plan.dayPlan(day)
        if p?.kind == .lift {
            let w = plan.upNext
            if !strength(w).isDirty { var f = strength(w); f.date = day; setStrength(w, f) }
            mode = LogMode(rawValue: w.rawValue)!
        } else {
            if !cardio.isDirty { cardio.date = day; cardio.activity = Activity.run.rawValue; cardio.slot = p?.slot?.rawValue ?? "" }
            mode = .cardio
        }
        modeChosen = true
        persist()
    }
}
