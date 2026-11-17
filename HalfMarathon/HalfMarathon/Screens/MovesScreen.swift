import SwiftUI

/// How to set up and do one move.
struct LearnView: View {
    let def: ExerciseDef
    var compact = false

    var body: some View {
        let l = def.learn
        VStack(alignment: .leading, spacing: 10) {
            if !compact { Text(l.why).foregroundStyle(.secondary) }
            Text("**Set up:** \(l.setup)")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(l.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").font(.display(15)).foregroundStyle(Color.accentColor)
                        Text(step)
                    }
                }
            }
            fact("Feel it in", l.feel)
            fact("Watch out for", l.mistake)
            fact("Easier version", l.easier)
            Link(destination: def.demoURL) {
                Label("Find demo videos on YouTube", systemImage: "arrow.up.right").labelStyle(TrailingIconLabel())
            }
            .fontWeight(.semibold)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.display(13, .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            Text(text)
        }
    }
}

struct MovesScreen: View {
    private var groups: [(String, [String])] {
        let a = Set(Workout.A.items), b = Set(Workout.B.items)
        return [
            ("Both workouts", Workout.A.items.filter { b.contains($0) }),
            ("Workout A", Workout.A.items.filter { !b.contains($0) }),
            ("Workout B", Workout.B.items.filter { !a.contains($0) }),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("How to set up and do each move in your plan. Most machines also have a diagram on the frame. Start light, and stop if you feel sharp or joint pain.")
                                .foregroundStyle(.secondary)
                            FlowLayout(spacing: 6) {
                                ForEach(groups.flatMap(\.1), id: \.self) { k in
                                    Button(Exercises.def(k)?.name ?? k) { withAnimation { proxy.scrollTo(k, anchor: .top) } }
                                        .font(.subheadline.weight(.semibold))
                                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                                }
                            }
                        }
                        ForEach(groups, id: \.0) { title, keys in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(title).font(.display(18)).textCase(.uppercase).foregroundStyle(.secondary)
                                ForEach(keys, id: \.self) { k in
                                    if let def = Exercises.def(k) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text(def.name).font(.title3.weight(.semibold))
                                            LearnView(def: def)
                                        }
                                        .padding(14)
                                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                                        .id(k)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Moves")
            }
        }
    }
}
