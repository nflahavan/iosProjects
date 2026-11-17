import SwiftUI

struct PlanScreen: View {
    let plan: Plan
    @Binding var raceDate: String
    let logDay: (DayKey) -> Void
    @AppStorage("planView") private var view: String = "cal"
    @State private var selected: DayKey = Day.today()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: view == "cal" ? [.sectionHeaders] : []) {
                        raceCard
                        HStack {
                            Picker("Plan view", selection: $view) {
                                Text("Calendar").tag("cal")
                                Text("Weeks").tag("weeks")
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                            Spacer()
                            if plan.rawWeek >= 1 && plan.rawWeek <= Plan.weeks {
                                Button(view == "cal" ? "Jump to this month" : "Jump to week \(plan.rawWeek)") {
                                    withAnimation { proxy.scrollTo("now", anchor: .top) }
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                        }
                        if view == "cal" {
                            Section {
                                Text("Outlined is planned, filled is done. Dots mark what you logged that day. Tap a day for details.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                calendar
                            } header: {
                                detail
                            }
                        } else {
                            weeks
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Plan")
            }
        }
    }

    // MARK: Race

    private var raceCard: some View {
        let days = Day.diff(plan.raceDate, plan.today)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Race day").font(.display(22)).textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if days > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(days)").font(.display(32))
                            Text(days == 1 ? " day to go" : " days to go").font(.display(17, .semibold)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(plan.countdown.isEmpty ? "Done" : plan.countdown).font(.display(32))
                    }
                    Spacer()
                    DatePicker("Race day", selection: Binding(
                        get: { Day.date(raceDate) ?? .now },
                        set: { raceDate = Day.key($0) }), displayedComponents: .date)
                        .labelsHidden()
                }
                DisclosureGroup("How the plan works") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Checked against published beginner plans and research. See the **Sources** tab for what matched, what changed and what is still a judgment call.")
                        Text("Change the date and all 26 weeks shift to end on it. Week 1 starts **\(Day.long(plan.weekDate(1)))**.")
                        Text("**Your week:** Mon lift, Tue run, Wed lift, Thu run, Sat long run. Fri and Sun are rest. Move days to fit your life, but keep a day between a leg-heavy lift and the long run.")
                        Text("**Goal pace** is the pace you think you can hold for 13.1 miles. Those miles are optional: published novice plans get first-timers to the finish on easy running alone.")
                        Text("**Missed a week?** Repeat any week that felt too hard, or the last one you finished if you missed two or more. To get back on the calendar, skip an easier week (13, 17, 20 or 22). That gives you up to four repeats.")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
    }

    // MARK: Calendar

    private var detail: some View {
        let t = plan.today
        let sel = plan.dayPlan(selected)
        let logged = plan.sessions.filter { $0.date == selected }
        let n = plan.weekNo(selected)
        return VStack(alignment: .leading, spacing: 4) {
            Text(Day.long(selected) + (selected == t ? " · Today" : "")).font(.headline)
            Group {
                if let sel {
                    Text("**\(sel.text):** \(sel.detail)") + (sel.done ? Text(" Done this week.").foregroundStyle(Color.go).bold() : Text(""))
                } else {
                    Text(n < 1 ? "Before the plan starts." : n > Plan.weeks || selected > plan.raceDate ? "After race day." : "Rest day.")
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            ForEach(logged) { s in
                Text(s.isLift ? "Logged: \(s.name)" : "Logged: \(plan.runName(s)) · \(Plan.loggedText(s))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.go)
            }
            if selected <= t {
                Button("Log this day") { logDay(selected) }.font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 9, y: 6)
        .padding(.vertical, 4)
    }

    private var months: [DayKey] {
        var out: [DayKey] = []
        guard var c = Day.date(plan.planStart).flatMap({ Day.calendar.date(from: Day.calendar.dateComponents([.year, .month], from: $0)) }),
              let last = Day.date(plan.raceDate) else { return [] }
        while c <= last {
            out.append(Day.key(c))
            c = Day.calendar.date(byAdding: .month, value: 1, to: c)!
        }
        return out
    }

    @ViewBuilder private var calendar: some View {
        let byDate = Dictionary(grouping: plan.sessions, by: \.date)
        let thisMonth = String(plan.today.prefix(7))
        ForEach(months, id: \.self) { first in
            VStack(alignment: .leading, spacing: 4) {
                Text(Day.format(first, .dateTime.month(.wide).year())).font(.display(22)).textCase(.uppercase)
                    .padding(.top, 8)
                let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
                LazyVGrid(columns: cols, spacing: 4) {
                    ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(0..<Day.weekdayIndex(first), id: \.self) { _ in Color.clear.frame(height: 1) }
                    ForEach(daysIn(first), id: \.self) { k in dayCell(k, logged: byDate[k] ?? []) }
                }
            }
            .id(first.hasPrefix(thisMonth) ? "now" : first)
        }
    }

    private func daysIn(_ first: DayKey) -> [DayKey] {
        guard let d = Day.date(first), let r = Day.calendar.range(of: .day, in: .month, for: d) else { return [] }
        return r.map { Day.adding($0 - 1, to: first) }
    }

    private func dayCell(_ k: DayKey, logged: [Session]) -> some View {
        let p = plan.dayPlan(k)
        let n = plan.weekNo(k)
        let out = n < 1 || n > Plan.weeks || k > plan.raceDate
        let missed = p != nil && !(p!.done) && n < plan.weekNo(plan.today)
        let isToday = k == plan.today
        return Button { selected = k } label: {
            VStack(spacing: 2) {
                Text(String(Int(k.suffix(2)) ?? 0))
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: 22, minHeight: 22)
                    .foregroundStyle(isToday ? Color(.systemBackground) : out ? Color.secondary : Color.primary)
                    .background(isToday ? Color.primary : .clear, in: .capsule)
                if let p {
                    chip(p).opacity(missed ? 0.45 : 1)
                    if !p.small.isEmpty {
                        Text(p.small).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7).opacity(missed ? 0.45 : 1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    ForEach(logged) { s in
                        RoundedRectangle(cornerRadius: s.isLift ? 1.5 : 3.5)
                            .fill(s.isLift ? Color.accentColor : Color.go).frame(width: 7, height: 7)
                    }
                }
                .frame(minHeight: 7)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(out ? Color.clear : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 8))
            .overlay {
                if k == selected { RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor, lineWidth: 2).padding(-1) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Day.long(k)): \(p.map { "\($0.text)\($0.done ? ", done" : "")" } ?? "nothing planned")\(logged.isEmpty ? "" : ", logged")")
        .accessibilityAddTraits(k == selected ? .isSelected : [])
    }

    private func chip(_ p: Plan.DayPlan) -> some View {
        let color: Color = p.kind == .lift ? .accentColor : p.kind == .race ? .race : .go
        let filled = p.done || p.kind == .race
        return Text(p.chip)
            .font(.display(11)).textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .foregroundStyle(filled ? Color.white : color)
            .background(filled ? color : .clear, in: .rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color))
    }

    // MARK: Weeks

    @ViewBuilder private var weeks: some View {
        let raw = plan.rawWeek
        ForEach(Plan.phases, id: \.from) { phase in
            VStack(alignment: .leading, spacing: 10) {
                Text("\(phase.name) · weeks \(phase.from)–\(phase.to)").font(.display(22)).textCase(.uppercase)
                Text(phase.note).font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(phase.from...phase.to, id: \.self) { n in
                        weekRow(n, raw: raw).id(n == raw ? "now" : "w\(n)")
                        if n < phase.to { Divider() }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))
            }
        }
    }

    private func weekRow(_ n: Int, raw: Int) -> some View {
        let tags = [Plan.weekTotal(n), Plan.downWeeks.contains(n) ? "Easier week" : "", n == raw ? "This week" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(n)").font(.display(28))
                Text(Day.short(plan.weekDate(n))).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            }
            .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(Day.short(plan.weekDate(n))) – \(Day.short(plan.weekDate(n, 6)))")
                    Spacer()
                    Text(tags)
                }
                .font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                RunRows(plan: plan, week: n)
                Text(n >= Plan.weeks ? "1 easy lift, Monday" : n >= 25 ? "2 lifts, lighter" : n >= 18 ? "2 lifts, hold leg weights" : "2 lifts, A and B")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(n == raw ? Color.accentColor.opacity(0.12) : .clear)
        .opacity(n < raw ? 0.72 : 1)
    }
}
