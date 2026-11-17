import SwiftUI

/// A lifting session: tap an exercise to log a set, and the rest timer starts.
struct LiftView: View {
    let lift: ActiveLift
    @State private var page = 1

    var body: some View {
        TabView(selection: $page) {
            ControlsPage(noun: "workout").tag(0)
            LiftList(lift: lift).tag(1)
        }
        .tabViewStyle(.page)
    }
}

private struct LiftList: View {
    @Environment(WorkoutModel.self) private var model
    let lift: ActiveLift
    @State private var entering: EnteringSet?

    var body: some View {
        List {
            Section {
                LiftHeader(lift: lift)
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(lift.workout.items, id: \.self) { key in
                    if let def = Exercises.def(key) {
                        Button {
                            if lift.setsDone(key) < Exercises.maxSets { entering = EnteringSet(key: key) }
                        } label: {
                            ExerciseRow(def: def, sets: lift.logged[key] ?? [], shown: lift.setsShown(key),
                                        chip: lift.hints[key]?.chip ?? "")
                        }
                        .swipeActions {
                            Button("Undo set", systemImage: "arrow.uturn.backward") { model.undoSet(key) }
                        }
                        .accessibilityHint("Logs a set and starts the rest timer")
                    }
                }
            } footer: {
                Text("Tap to log each set. Swipe left to undo one.")
            }
        }
        .sheet(item: $entering) { e in
            if let def = Exercises.def(e.key) {
                SetEntry(def: def, number: lift.setsDone(e.key) + 1, start: lift.proposal(e.key)) { set in
                    model.markSet(e.key, set)
                }
            }
        }
    }
}

private struct EnteringSet: Identifiable {
    let key: String
    var id: String { key }
}

/// Weight and reps for one set, on two wheels the Digital Crown turns. They start on the
/// set before, or on what the phone suggests, so most sets are one tap on Done.
private struct SetEntry: View {
    let def: ExerciseDef
    let number: Int
    let onDone: (LiftSet) -> Void
    @State private var weight: Double
    @State private var count: Double
    @Environment(\.dismiss) private var dismiss

    private static let weights: [Double] = Array(stride(from: 0.0, through: 600.0, by: 2.5))
    private var counts: [Double] {
        def.countsReps ? Array(stride(from: 1.0, through: 50.0, by: 1)) : Array(stride(from: 5.0, through: 300.0, by: 5))
    }

    init(def: ExerciseDef, number: Int, start: LiftSet, onDone: @escaping (LiftSet) -> Void) {
        self.def = def
        self.number = number
        self.onDone = onDone
        // Snapped onto the wheels' steps, so each wheel opens on a real row.
        let w = min(max(((start.w ?? 0) / 2.5).rounded() * 2.5, 0), 600)
        let n = def.countsReps ? min(max(start.n.rounded(), 1), 50) : min(max((start.n / 5).rounded() * 5, 5), 300)
        _weight = State(initialValue: w)
        _count = State(initialValue: n)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(def.name) · set \(number)")
                .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                if def.hasWeight {
                    Picker("lb", selection: $weight) {
                        ForEach(Self.weights, id: \.self) { w in
                            Text(w == 0 ? "BW" : fmtNum(w)).tag(w)
                        }
                    }
                }
                Picker(def.countsReps ? "reps" : "sec", selection: $count) {
                    ForEach(counts, id: \.self) { n in
                        Text(fmtNum(n)).tag(n)
                    }
                }
            }
            .font(.title3.weight(.semibold).monospacedDigit())
            Button {
                onDone(LiftSet(w: def.hasWeight && weight > 0 ? weight : nil, n: count))
                dismiss()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.run)
            .foregroundStyle(.black)
        }
    }
}

/// Elapsed time and heart rate, and the rest since the last set.
private struct LiftHeader: View {
    @Environment(WorkoutModel.self) private var model
    let lift: ActiveLift

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(lift.workout.label.uppercased()).font(.display(20, .heavy))
                Spacer()
                Label(model.manager.heartRate.map { "\(Int($0.rounded()))" } ?? "––", systemImage: "heart.fill")
                    .labelStyle(StatLabel(tint: .red))
                    .font(.footnote.weight(.medium))
            }
            if let rest = lift.restStart {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(restTitle)
                        .font(.display(18, .heavy))
                        .foregroundStyle(restColor)
                    Text(timerInterval: rest...rest.addingTimeInterval(3600), countsDown: false)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack {
                    Text("Rest 60–90 s").foregroundStyle(.secondary)
                    Spacer()
                    Button("Skip") { model.skipRest() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
                .font(.caption2)
            } else {
                HStack(spacing: 4) {
                    if lift.clock.isPaused {
                        Text("Paused").foregroundStyle(Color.paused)
                    } else {
                        Text(timerInterval: lift.clock.date(at: 0, from: .now)...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                    }
                    Text("· \(plural(lift.totalDone, "set", "sets"))")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // `restCues` goes up as the model plays each rest tap, which redraws this.
    private var restTitle: String { lift.restCues >= 2 ? "GO" : lift.restCues == 1 ? "READY" : "REST" }
    private var restColor: Color { lift.restCues >= 1 ? .run : .walk }
}

private struct ExerciseRow: View {
    let def: ExerciseDef
    let sets: [LiftSet]
    let shown: Int
    /// The phone's suggestion: "↑ Add 5 lb", "Stay at 180 lb".
    let chip: String

    private var done: Int { sets.count }

    /// The target and suggestion until a set is logged, then the sets themselves.
    private var detail: String {
        guard !sets.isEmpty else { return chip.isEmpty ? def.target : "\(def.target) · \(chip)" }
        return sets.map { s in
            let n = fmtNum(s.n) + (def.countsReps ? "" : " s")
            return s.w.map { "\(fmtNum($0))×\(n)" } ?? n
        }.joined(separator: ", ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(def.name).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                Text(detail).font(.caption2).foregroundStyle(sets.isEmpty ? Color.secondary : Color.run)
                    .lineLimit(2).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                ForEach(0..<shown, id: \.self) { i in
                    Image(systemName: i < done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(i < done ? Color.run : .secondary)
                        .imageScale(.small)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(done) of \(shown) sets done")
        }
    }
}
