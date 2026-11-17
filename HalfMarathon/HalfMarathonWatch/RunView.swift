import SwiftUI

/// A run in progress: the readout, with Pause and End a swipe away.
struct RunView: View {
    let run: ActiveRun
    @State private var page = 1

    var body: some View {
        TabView(selection: $page) {
            ControlsPage(noun: "run").tag(0)
            // Redrawn each second from the clock, and once more by the model at each cue.
            TimelineView(.periodic(from: run.clock.start, by: 1)) { context in
                RunFace(run: run, now: context.date)
            }
            .tag(1)
        }
        .tabViewStyle(.page)
    }
}

/// Pause and End, shared by runs and lifts.
struct ControlsPage: View {
    @Environment(WorkoutModel.self) private var model
    let noun: String
    @State private var confirmEnd = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                model.togglePause()
            } label: {
                Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(Color.paused)
            Button(role: .destructive) {
                confirmEnd = true
            } label: {
                Label("End", systemImage: "xmark").frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .confirmationDialog("End this \(noun)?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End", role: .destructive) { model.end() }
            Button("Keep going", role: .cancel) {}
        }
    }
}

/// What the readout shows at one moment, worked out from the clock and the readings.
struct RunReadout {
    var title: String
    var color: Color
    /// Top right: "3 of 8", "25 min", "of 4.5 mi".
    var badge: String
    /// The big number: a countdown to `countdownTo`, or fixed text.
    var countdownTo: Date?
    var countUpFrom: Date?
    var big: String
    var unit: String = ""
    /// 0…1 through the current stretch or target.
    var progress: Double?
    var note: String

    init(run: ActiveRun, miles: Double, now: Date) {
        let e = run.clock.elapsed(at: now)
        // The moment the clock read zero, had it never been paused: a count up from here shows elapsed time.
        let zero = run.clock.date(at: 0, from: now)
        countdownTo = nil
        countUpFrom = nil
        progress = nil
        switch run.program {
        case let .intervals(s):
            if let p = s.position(at: e) {
                title = p.segment.title
                color = p.segment.kind == .run ? .run : .walk
                badge = p.segment.rep > 0 ? "\(p.segment.rep) of \(s.reps)" : ""
                countdownTo = run.clock.date(at: p.segment.end, from: now)
                big = fmtClock(p.remaining.rounded(.up))
                progress = p.elapsed / p.segment.duration
                note = s.next(after: p.index).map { "Next: \($0.short) \(fmtClock($0.duration))" } ?? "Last stretch"
            } else {
                title = "DONE"; color = .run; badge = ""
                countUpFrom = zero
                big = fmtClock(e)
                note = "All \(s.reps) intervals done. Swipe right to end."
            }
        case let .timed(target):
            badge = "\(fmtNum(target / 60)) min"
            if e < target {
                title = "EASY RUN"; color = .run
                countdownTo = run.clock.date(at: target, from: now)
                big = fmtClock((target - e).rounded(.up))
                progress = e / target
                note = "Nonstop, at talking pace"
            } else {
                title = "TARGET HIT"; color = .run
                countUpFrom = zero
                big = fmtClock(e)
                note = "Swipe right to end, or keep going."
            }
        case let .distance(d):
            badge = "of \(fmtNum(d.miles)) mi"
            big = String(format: "%.2f", miles)
            unit = "mi"
            progress = min(miles / d.miles, 1)
            switch d.zone(at: miles) {
            case .done:
                title = "DONE"; color = .run
                note = "Swipe right to end, or keep going."
            case .goalPace:
                title = "GOAL PACE"; color = .race
                note = "Goal pace for \(Self.left((d.goalRange?.upperBound ?? d.miles) - miles)) more, \(Self.left(d.miles - miles)) to go"
            case .easy:
                title = "EASY"; color = .run
                if let g = d.goalRange, miles < g.lowerBound {
                    note = "Goal pace in \(Self.left(g.lowerBound - miles)), for \(fmtNum(d.goalPace)) mi"
                } else {
                    note = "\(Self.left(d.miles - miles)) to go"
                }
            }
        case .open:
            title = "FREE RUN"; color = .run; badge = ""
            countUpFrom = zero
            big = fmtClock(e)
            note = ""
        }
        if run.clock.isPaused {
            title = "PAUSED"
            color = .paused
        }
    }

    private static func left(_ miles: Double) -> String { String(format: "%.2f mi", max(miles, 0)) }
}

private struct RunFace: View {
    @Environment(WorkoutModel.self) private var model
    @Environment(\.isLuminanceReduced) private var dimmed
    let run: ActiveRun
    let now: Date

    var body: some View {
        let miles = model.manager.miles
        let r = RunReadout(run: run, miles: miles, now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.title)
                    .font(.display(30, .heavy))
                    .foregroundStyle(r.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                Text(r.badge)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            BigNumber(readout: r, paused: run.clock.isPaused, now: now)
            if let p = r.progress {
                ProgressView(value: min(max(p, 0), 1))
                    .tint(r.color)
                    .opacity(dimmed ? 0.5 : 1)
                    .padding(.bottom, 3)
            }
            Text(r.note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            // Above the bottom edge, which belongs to the page dots.
            StatsRow(run: run, now: now)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

/// The time left or elapsed, kept ticking by the system between redraws (and with the screen
/// dimmed), or a distance.
private struct BigNumber: View {
    let readout: RunReadout
    let paused: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            number
                .font(.system(size: 54, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if !readout.unit.isEmpty {
                Text(readout.unit).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var number: some View {
        if paused {
            Text(readout.big)
        } else if let end = readout.countdownTo, end > now {
            Text(timerInterval: now...end, countsDown: true)
        } else if let start = readout.countUpFrom, start < now {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
        } else {
            Text(readout.big)
        }
    }
}

/// Heart rate, distance or pace, and the total time.
private struct StatsRow: View {
    @Environment(WorkoutModel.self) private var model
    let run: ActiveRun
    let now: Date

    var body: some View {
        let e = run.clock.elapsed(at: now)
        let showsDistanceBig = if case .distance = run.program { true } else { false }
        HStack(spacing: 0) {
            Label(model.manager.heartRate.map { "\(Int($0.rounded()))" } ?? "––", systemImage: "heart.fill")
                .labelStyle(StatLabel(tint: .red))
            Spacer(minLength: 2)
            if showsDistanceBig {
                Text(pace(e, miles)).accessibilityLabel("Pace \(pace(e, miles)) per mile")
            } else {
                Text(String(format: "%.2f mi", miles))
            }
            Spacer(minLength: 2)
            Label(fmtClock(e), systemImage: "stopwatch")
                .labelStyle(StatLabel(tint: .secondary))
        }
        .font(.footnote.weight(.medium))
        .monospacedDigit()
        .lineLimit(1)
    }

    private var miles: Double { model.manager.miles }

    /// Average pace so far, as minutes per mile.
    private func pace(_ elapsed: TimeInterval, _ miles: Double) -> String {
        miles >= 0.05 ? "\(fmtClock(elapsed / miles))/mi" : "–:––/mi"
    }
}

struct StatLabel: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.foregroundStyle(tint).imageScale(.small)
            configuration.title
        }
    }
}
