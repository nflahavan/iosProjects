import SwiftUI

/// A run that can be started: one of this week's, or a free run.
struct RunChoice: Identifiable {
    var slot: RunSlot
    var title: String
    /// Nil for a free run.
    var planned: PlannedRun?
    var done = false

    var id: String { slot.rawValue }

    static func title(_ slot: RunSlot, label: String) -> String {
        slot == .long && label == "Long" ? "Long run" : label
    }

    static let free = RunChoice(slot: .extra, title: "Free run")

    init(slot: RunSlot, title: String, planned: PlannedRun? = nil, done: Bool = false) {
        self.slot = slot; self.title = title; self.planned = planned; self.done = done
    }

    init(_ o: WatchPlan.Option) {
        self.init(slot: o.slot, title: Self.title(o.slot, label: o.label), planned: o.run, done: o.done)
    }

    var detail: String { planned?.describe ?? "No target. Time, distance and heart rate." }

    /// How long it takes on the watch, where the plan gives a time.
    var length: String? {
        guard let planned else { return nil }
        switch RunProgram(planned) {
        case let .intervals(s): return "\(fmtNum(s.total / 60)) min with warm-up and cool-down"
        default: return nil
        }
    }
}

struct StartView: View {
    @Environment(WorkoutModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Reading the scene phase redraws this when the watch wakes, so "today" is today.
        let _ = scenePhase
        let plan = model.plan
        let choices = plan.options.map(RunChoice.init)
        let next = choices.first { $0.slot == plan.nextSlot } ?? .free
        NavigationStack {
            List {
                Section {
                    NextCard(choice: next, reason: freeReason(plan))
                } header: {
                    Text(header(plan))
                }
                Section("Other runs") {
                    ForEach(choices.filter { $0.slot != next.slot }) { c in
                        NavigationLink { RunPreview(choice: c) } label: { ChoiceRow(choice: c) }
                    }
                    if next.slot != .extra {
                        NavigationLink { RunPreview(choice: .free) } label: { ChoiceRow(choice: .free) }
                    }
                }
                Section("Lift") {
                    ForEach([plan.upNext, plan.upNext.other]) { w in
                        NavigationLink { LiftPreview(workout: w) } label: { LiftRow(workout: w, upNext: w == plan.upNext) }
                    }
                }
                Section {
                    Text(footer(plan))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Half Build")
        }
    }

    private func header(_ plan: WatchPlan) -> String {
        if plan.rawWeek < 1 { return "Starts \(Day.short(plan.calendar.planStart))" }
        if plan.rawWeek > PlanCalendar.weeks { return "Plan finished" }
        return "Week \(plan.week) · \(PlanCalendar.phase(plan.week).name)"
    }

    /// Why a free run is on offer rather than a planned one.
    private func freeReason(_ plan: WatchPlan) -> String {
        if plan.rawWeek < 1 { return "The plan starts \(Day.long(plan.calendar.planStart))." }
        if plan.rawWeek > PlanCalendar.weeks { return "The plan is finished." }
        return "This week's runs are done."
    }

    private func footer(_ plan: WatchPlan) -> String {
        let days = Day.diff(plan.calendar.raceDate, plan.today)
        let race = days > 1 ? "\(days) days to race day" : days == 1 ? "Race day is tomorrow" : days == 0 ? "Race day" : "Race day was \(Day.short(plan.calendar.raceDate))"
        return model.link.context == nil ? "\(race). Open Half Build on your iPhone to sync." : "\(race)."
    }
}

/// The run on offer, with its Start button.
private struct NextCard: View {
    @Environment(WorkoutModel.self) private var model
    let choice: RunChoice
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(choice.planned == nil ? "FREE RUN" : "NEXT · \(choice.title.uppercased())")
                .font(.display(22, .heavy))
                .foregroundStyle(Color.run)
            Text(choice.planned == nil ? reason : choice.detail)
                .font(.footnote)
            if let length = choice.length {
                Text(length).font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                model.startRun(slot: choice.slot, title: choice.title, planned: choice.planned)
            } label: {
                Label("Start", systemImage: "figure.run").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.run)
            .foregroundStyle(.black)
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .listRowBackground(RoundedRectangle(cornerRadius: 18).fill(Color.run.opacity(0.14)))
    }
}

private struct ChoiceRow: View {
    let choice: RunChoice

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title).font(.headline)
                Text(choice.planned?.small ?? "No target").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if choice.done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.run)
                    .accessibilityLabel("Done")
            }
        }
    }
}

private struct LiftRow: View {
    let workout: Workout
    let upNext: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workout.label).font(.headline)
            Text(upNext ? "Up next" : "\(workout.items.count) exercises")
                .font(.caption2)
                .foregroundStyle(upNext ? Color.accentColor : .secondary)
        }
    }
}

/// A run other than the one on offer: what it is, and Start.
struct RunPreview: View {
    @Environment(WorkoutModel.self) private var model
    let choice: RunChoice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(choice.detail).font(.body)
                if let length = choice.length {
                    Text(length).font(.footnote).foregroundStyle(.secondary)
                }
                if choice.done {
                    Text("Already logged this week.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    model.startRun(slot: choice.slot, title: choice.title, planned: choice.planned)
                } label: {
                    Label("Start", systemImage: "figure.run").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.run)
                .foregroundStyle(.black)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(choice.title)
    }
}

struct LiftPreview: View {
    @Environment(WorkoutModel.self) private var model
    let workout: Workout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(workout.items, id: \.self) { key in
                    if let def = Exercises.def(key) {
                        HStack {
                            Text(def.name).font(.footnote)
                            Spacer()
                            Text(def.target).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    model.startLift(workout)
                } label: {
                    Label("Start", systemImage: "dumbbell.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
        }
        .navigationTitle(workout.label)
    }
}
