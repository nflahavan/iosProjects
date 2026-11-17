import SwiftUI

/// A finished workout: what it came to, and whether to keep it.
struct SummaryView: View {
    @Environment(WorkoutModel.self) private var model
    let summary: Summary

    var body: some View {
        let m = model.manager
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.title.uppercased())
                    .font(.display(24, .heavy))
                    .foregroundStyle(Color.run)
                row("Time", fmtClock(summary.elapsed))
                if case .run = summary.kind {
                    if abs(summary.loggedMinutes * 60 - summary.elapsed) >= 30 {
                        row("Logged as", "\(fmtNum(summary.loggedMinutes)) min")
                    }
                    row("Distance", m.miles > 0 ? String(format: "%.2f mi", m.miles) : "–")
                } else {
                    row("Sets", "\(summary.sets)")
                }
                row("Avg heart rate", m.avgHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "–")
                if let problem = m.problem {
                    Text("\(problem). The workout won't be in Health.")
                        .font(.caption2).foregroundStyle(Color.paused)
                }
                Text(explanation).font(.caption2).foregroundStyle(.secondary)
                Button {
                    Task { await model.save() }
                } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.run)
                .foregroundStyle(.black)
                .padding(.top, 4)
                Button(role: .destructive) {
                    Task { await model.discard() }
                } label: {
                    Text("Discard").frame(maxWidth: .infinity)
                }
            }
            .disabled(model.saving)
        }
    }

    private var explanation: String {
        switch summary.kind {
        case .run: "Save logs it in Half Build on your iPhone and adds the workout to Health."
        case .lift:
            summary.lift.isEmpty
                ? "No sets logged. Save adds the workout to Health only."
                : "Save logs your sets in Half Build on your iPhone and adds the workout to Health."
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.weight(.semibold)).monospacedDigit()
        }
    }
}
