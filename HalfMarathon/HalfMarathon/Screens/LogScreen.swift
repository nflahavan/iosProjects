import SwiftData
import SwiftUI

struct LogScreen: View {
    let plan: Plan
    @Bindable var log: LogModel
    let showToast: (String) -> Void
    @Environment(\.modelContext) private var context
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WeekCard(plan: plan)
                    if let e = log.editing { editBanner(e) }
                    modePicker
                    if let saveError {
                        Text(saveError).font(.subheadline).foregroundStyle(Color.race)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.race.opacity(0.12), in: .rect(cornerRadius: 10))
                    }
                    if let w = log.mode.workout {
                        StrengthFormView(plan: plan, log: log, workout: w)
                    } else {
                        CardioFormView(plan: plan, log: log)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Half Marathon Build")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { saveBar }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
        }
        .onAppear { log.follow(plan) }
        .onChange(of: plan.sessions.count) { log.follow(plan) }
    }

    private func editBanner(_ e: LogModel.Editing) -> some View {
        let what = e.mode.workout?.label ?? "cardio"
        let date = e.mode.workout.map { log.strength($0).date } ?? log.cardio.date
        let kept = e.extra.map(\.name)
        return HStack(alignment: .firstTextBaseline) {
            Text("Editing \(what) from \(Day.long(date)).\(kept.isEmpty ? "" : " Kept as logged: \(kept.joined(separator: ", ")).")")
            Spacer()
            Button("Cancel") { log.cancelEdit(); saveError = nil }.fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    private var modePicker: some View {
        let next = plan.upNext
        return HStack(spacing: 8) {
            ForEach(LogMode.allCases) { m in
                let on = log.mode == m
                Button {
                    log.modeChosen = true
                    if log.mode != m { log.mode = m; saveError = nil; log.persist() }
                } label: {
                    VStack(spacing: 2) {
                        if let w = m.workout {
                            Text(w.rawValue).font(.display(32))
                            Text(w == next ? "Up next" : lastDone(w)).font(.caption2.weight(.semibold)).textCase(.uppercase)
                                .opacity(0.85)
                        } else {
                            Text("Run").font(.display(22)).textCase(.uppercase)
                            Text("Or bike · row").font(.caption2.weight(.semibold)).textCase(.uppercase).opacity(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 66)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(log.editing != nil && m != log.mode)
                .opacity(log.editing != nil && m != log.mode ? 0.4 : 1)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func lastDone(_ w: Workout) -> String {
        plan.sessions.first { $0.type == w.rawValue }.map { "Done \(Day.short($0.date))" } ?? "Workout"
    }

    private var saveBar: some View {
        let editing = log.editing != nil
        let label: String, sub: String, ready: Bool
        if let w = log.mode.workout {
            let c = log.completedSets(w)
            label = "\(editing ? "Update" : "Save") \(w.label)"
            sub = c > 0 ? "\(plural(c, "set", "sets")) logged" : "Log reps as you go"
            ready = c > 0
        } else {
            let m = parseNum(log.cardio.min) ?? 0
            label = "\(editing ? "Update" : "Save") \(log.cardio.isRun ? "run" : "cardio")"
            sub = m > 0 ? "\(fmtNum(m)) min" : "Enter your time"
            ready = m > 0
        }
        return Button(action: save) {
            HStack(spacing: 12) {
                Text(label).font(.display(22)).textCase(.uppercase)
                Text(sub).font(.subheadline.weight(.semibold)).opacity(0.85).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(!ready)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func save() {
        do {
            if let msg = try log.save(context: context, plan: plan) {
                saveError = nil
                showToast(msg)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } catch {
            saveError = "Couldn't save. Your entries are still here. (\(error.localizedDescription))"
        }
    }
}

// MARK: - Strength

struct StrengthFormView: View {
    let plan: Plan
    @Bindable var log: LogModel
    let workout: Workout
    @State private var learnOpen: Set<String> = []

    var body: some View {
        let f = log.strength(workout)
        VStack(alignment: .leading, spacing: 10) {
            FormHead(title: workout.label, date: dateBinding,
                     sub: Plan.liftNote(min(max(plan.weekNo(f.date), 1), Plan.weeks)))
            ForEach(workout.items, id: \.self) { k in
                if let def = Exercises.def(k) { exerciseCard(def, sets: f.ex[k] ?? []) }
            }
            extras
        }
        .onAppear { log.prepareSets(workout, plan: plan) }
        .onChange(of: workout) { log.prepareSets(workout, plan: plan) }
        .onChange(of: plan.sessions.count) { log.prepareSets(workout, plan: plan) }
        .onChange(of: log.editing?.id) { log.prepareSets(workout, plan: plan) }
    }

    private var dateBinding: Binding<DayKey> {
        Binding(get: { log.strength(workout).date }, set: { v in
            var f = log.strength(workout); f.date = v; log.setStrength(workout, f); log.persist()
        })
    }

    private func exerciseCard(_ def: ExerciseDef, sets: [SetEntry]) -> some View {
        let sug = plan.suggest(def.id, skipping: log.editing?.id)
        let open = learnOpen.contains(def.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(def.name).font(.title3.weight(.semibold))
                if let tag = def.tag {
                    Text(tag).font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(.separator)))
                }
                Spacer()
                Text(def.target).font(.display(17, .semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                Text(def.hint).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.snappy) { if open { learnOpen.remove(def.id) } else { learnOpen.insert(def.id) } }
                } label: {
                    Label("How to", systemImage: open ? "chevron.up" : "chevron.down")
                        .labelStyle(TrailingIconLabel())
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            if open { LearnView(def: def, compact: true) }
            if !sug.text.isEmpty || !sug.chip.isEmpty {
                HStack(spacing: 8) {
                    if !sug.text.isEmpty { Text(sug.text).font(.subheadline).foregroundStyle(.secondary) }
                    if !sug.chip.isEmpty {
                        Text(sug.chip).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .foregroundStyle(sug.up ? Color.go : Color.primary)
                            .background(sug.up ? Color.go.opacity(0.15) : Color(.tertiarySystemFill), in: .capsule)
                    }
                }
            }
            ForEach(sets.indices, id: \.self) { i in setRow(def, i, sets[i]) }
            HStack(spacing: 18) {
                Button("+ Add set") { log.addSet(workout, key: def.id, plan: plan) }
                    .disabled(sets.count >= Exercises.maxSets)
                if sets.count > 1 {
                    Button("Remove set") { log.removeSet(workout, key: def.id) }.foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func setRow(_ def: ExerciseDef, _ i: Int, _ s: SetEntry) -> some View {
        HStack(spacing: 8) {
            Text("\(i + 1)").font(.display(17)).foregroundStyle(.secondary).frame(width: 16)
            if def.hasWeight {
                NumberField(text: Binding(get: { s.w }, set: { log.setWeight(workout, key: def.id, index: i, value: $0, plan: plan) }),
                            unit: def.wUnit, placeholder: "", decimal: true,
                            label: "\(def.name), set \(i + 1), weight in pounds")
                Text("×").foregroundStyle(.secondary)
            }
            NumberField(text: Binding(get: { s.n }, set: { log.setCount(workout, key: def.id, index: i, value: $0) }),
                        unit: def.countsReps ? "reps" : "sec", placeholder: "\(def.lo)–\(def.hi)", decimal: false,
                        label: "\(def.name), set \(i + 1), \(def.countsReps ? "reps" : "seconds")")
        }
    }

    private var extras: some View {
        let f = log.strength(workout)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Cardio after").fontWeight(.semibold)
                    Text("Easy bike or walk. Optional.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                NumberField(text: Binding(get: { f.finisher }, set: { v in
                    var f = log.strength(workout); f.finisher = v; log.setStrength(workout, f); log.persist()
                }), unit: "min", placeholder: "10–15", decimal: false, label: "Cardio after lifting, in minutes")
                .frame(maxWidth: 150)
            }
            Text("Notes").fontWeight(.semibold)
            NotesField(text: Binding(get: { f.note }, set: { v in
                var f = log.strength(workout); f.note = v; log.setStrength(workout, f); log.persist()
            }), prompt: "How did it feel? Any aches?")
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }
}

// MARK: - Cardio

struct CardioFormView: View {
    let plan: Plan
    @Bindable var log: LogModel

    var body: some View {
        let f = log.cardio
        let wk = plan.weekNo(f.date)
        let inPlan = f.isRun && wk >= 1 && wk <= Plan.weeks
        let cur = RunSlot(rawValue: f.slot) ?? plan.autoSlot(f.date, skipping: log.editing?.id)
        let picked = Plan.slots(wk).first { $0.slot == cur }
        var minHint = "30"
        if inPlan, let p = picked, p.run.minutes > 0 { minHint = String(p.run.minutes) }

        return VStack(alignment: .leading, spacing: 10) {
            FormHead(title: f.isRun ? "Run" : "Cardio", date: Binding(get: { log.cardio.date }, set: {
                log.cardio.date = $0
                if log.editing == nil { log.cardio.slot = "" }
                log.persist()
            }), sub: f.isRun
                ? "Walk 5 minutes to warm up and 5 to cool down. Easy means you could hold a conversation, and extra walk breaks are always fine. Sharp or one-sided pain means stop, and swap the next run for the bike."
                : "Bike, rower or a walk can stand in for a run when your legs need a break. Same easy effort, same time.")
            VStack(alignment: .leading, spacing: 12) {
                Text("Activity").fontWeight(.semibold)
                Chips(options: Activity.allCases.map { ($0.rawValue, $0.label) }, selection: Binding(
                    get: { log.cardio.activity }, set: { log.cardio.activity = $0; log.persist() }))
                if inPlan {
                    Text("Week \(wk): which run is this?").fontWeight(.semibold)
                    Chips(options: Plan.slots(wk).map { ($0.slot.rawValue, $0.label) } + [(RunSlot.extra.rawValue, "Extra")],
                          selection: Binding(get: { cur.rawValue }, set: { log.cardio.slot = $0; log.persist() }))
                    Group {
                        if let p = picked, cur != .extra {
                            Text("**Plan:** \(p.run.describe)\(p.run.isRunWalk ? " · \(p.run.minutes) min" : "")")
                        } else {
                            Text("An extra run on top of the plan. Keep it short and easy.")
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Time").fontWeight(.semibold)
                        NumberField(text: Binding(get: { log.cardio.min }, set: { log.cardio.min = $0; log.persist() }),
                                    unit: "min", placeholder: minHint, decimal: false, label: "Minutes")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Distance (optional)").fontWeight(.semibold)
                        NumberField(text: Binding(get: { log.cardio.mi }, set: { log.cardio.mi = $0; log.persist() }),
                                    unit: "mi", placeholder: "", decimal: true, label: "Distance in miles")
                    }
                }
                Text("Notes").fontWeight(.semibold)
                NotesField(text: Binding(get: { log.cardio.note }, set: { log.cardio.note = $0; log.persist() }),
                           prompt: "Route, pace, how your knees and feet felt")
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
    }
}

// MARK: - Pieces

struct FormHead: View {
    let title: String
    @Binding var date: DayKey
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.display(30)).textCase(.uppercase)
                Spacer()
                DatePicker("Date", selection: Binding(
                    get: { Day.date(date) ?? .now },
                    set: { date = Day.key($0) }), in: ...Date.now, displayedComponents: .date)
                    .labelsHidden()
            }
            Text(sub).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}

struct NumberField: View {
    @Binding var text: String
    let unit: String
    let placeholder: String
    let decimal: Bool
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .font(.title3.weight(.semibold).monospacedDigit())
                .accessibilityLabel(label)
            Text(unit).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))
    }
}

struct NotesField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(2...6)
            .padding(10)
            .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))
    }
}

struct Chips: View {
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.0) { value, label in
                let on = selection == value
                Button { selection = value } label: {
                    Text(label).fontWeight(.semibold)
                        .padding(.horizontal, 16).frame(minHeight: 42)
                        .foregroundStyle(on ? Color.accentColor : Color.primary)
                        .background(on ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill), in: .capsule)
                        .overlay(Capsule().stroke(on ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + s.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
