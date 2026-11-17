import SwiftUI

/// This week at a glance: plan week, lifts and runs done, the seven days, and the week's runs.
struct WeekCard: View {
    let plan: Plan

    var body: some View {
        let t = plan.today
        let start = Day.weekStart(t)
        let keys = (0..<7).map { Day.adding($0, to: start) }
        let mine = plan.sessions.filter { keys.contains($0.date) }
        let lifts = mine.filter(\.isLift).count
        let runs = mine.filter { $0.isCardio && $0.activity == Activity.run.rawValue }.count
        let raw = plan.rawWeek, wk = plan.currentWeek
        let early = raw < 1, over = raw > Plan.weeks
        let planned = early || over ? Array(repeating: "", count: 7) : plan.dayLabels(wk)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week").font(.display(14, .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                Spacer()
                Text("\(Day.short(keys[0])) – \(Day.short(keys[6]))").font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(over ? "Plan complete" : "Week \(wk) of \(Plan.weeks)")
                    .font(.display(22)).textCase(.uppercase)
                if !over {
                    Text(early ? "Starts \(Day.long(plan.weekDate(1)))"
                         : [Plan.phase(wk).name, plan.countdown].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                stat("Lifts", value: lifts, of: Plan.liftTarget(wk), color: .accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    stat("Runs", value: runs, of: 3, color: .go)
                    ProgressView(value: min(Double(runs), 3), total: 3).tint(.go)
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { i in
                    dayCell(i, key: keys[i], sessions: mine.filter { $0.date == keys[i] }, planned: planned[i], today: t)
                }
            }
            if !over {
                Divider()
                RunRows(plan: plan, week: wk)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func stat(_ label: String, value: Int, of total: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: label == "Runs" ? 5 : 2).fill(color).frame(width: 10, height: 10)
                Text(label).font(.display(14, .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(value)").font(.display(32))
                Text(" of \(total)").font(.display(17, .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func dayCell(_ i: Int, key: DayKey, sessions: [Session], planned: String, today: DayKey) -> some View {
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        let liftTypes = Array(Set(sessions.filter(\.isLift).map(\.type))).sorted().joined()
        let cardio = sessions.contains(where: \.isCardio)
        let isToday = key == today
        return VStack(spacing: 4) {
            Text(letters[i]).font(.caption.weight(.semibold)).foregroundStyle(isToday ? .primary : .secondary)
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(liftTypes.isEmpty ? Color(.tertiarySystemFill) : Color.accentColor)
                    .overlay { Text(liftTypes).font(.display(16)).foregroundStyle(.white) }
                if cardio {
                    Circle().fill(Color.go).frame(width: 8, height: 8).padding(4)
                }
            }
            .frame(height: 30)
            .overlay { if isToday { RoundedRectangle(cornerRadius: 7).stroke(.primary, lineWidth: 2).padding(-2) } }
            Text(planned).font(.system(size: 10, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                .frame(minHeight: 14)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Day.weekdayName(key)): \(describe(liftTypes, cardio))\(planned.isEmpty ? "" : ", planned: \(planned)")")
    }

    private func describe(_ lifts: String, _ cardio: Bool) -> String {
        let parts = [lifts.isEmpty ? "" : "Workout \(lifts.map(String.init).joined(separator: " and "))", cardio ? "cardio" : ""]
        let s = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        return s.isEmpty ? "nothing logged" : s
    }
}

/// A week's three runs, ticked when logged.
struct RunRows: View {
    let plan: Plan
    let week: Int

    var body: some View {
        let done = plan.runsDone(week)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Plan.slots(week), id: \.slot) { row in
                let s = done[row.slot]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: s == nil ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(s == nil ? Color.secondary : Color.go)
                    Text(row.label).fontWeight(.semibold).frame(width: 50, alignment: .leading)
                    Text(s.map { "Done \(Day.short($0.date)) · \(Plan.loggedText($0))" } ?? row.run.describe)
                        .foregroundStyle(s == nil ? Color.secondary : Color.go)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
