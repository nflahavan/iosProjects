import Charts
import SwiftData
import SwiftUI

/// Income against spending for a month or a year: the totals, how they
/// moved over time, and where the money went by category.
struct OverviewScreen: View {
    @Environment(\.modelContext) private var context
    /// The last adding-up that came back; nil before the first.
    @State private var overview: Overview?
    /// True while an adding-up is running. Figures shown meanwhile are the
    /// previous ones, and are marked as such.
    @State private var updating = false
    @State private var problem: String?
    /// Bumped by Try again, to rerun the task.
    @State private var attempt = 0
    /// The month or year picked; nil is the newest month.
    @State private var picked: Period?
    @State private var category: CategoryPick?

    private var newestMonth: Period? { overview?.months.first.map(Period.month) }
    private var oldestMonth: Period? { overview?.months.last.map(Period.month) }

    private var period: Period? { picked ?? newestMonth }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let problem, overview == nil {
                    ContentUnavailableView {
                        Label("Couldn't add up your transactions", systemImage: "exclamationmark.triangle")
                    } description: { Text(problem) } actions: {
                        Button("Try again") { attempt += 1 }.buttonStyle(.borderedProminent)
                    }
                } else if overview == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Adding up your transactions…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else if let overview, let period, !overview.months.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        filters(overview, period)
                        figures(overview, period)
                    }
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView("Nothing yet", systemImage: "chart.bar",
                                           description: Text("Import and review a CSV to see where the money went."))
                }
            }
            .navigationTitle("Overview")
            .screen("overview")
            // Each time the tab is shown, so new decisions are counted.
            .task(id: attempt) { await refresh() }
            .sheet(item: $category) { pick in
                if let overview, let period {
                    CategoryTrend(pick: pick, overview: overview, period: period)
                        .presentationDetents([.medium, .large])
                }
            }
        }
    }

    // MARK: Filters

    /// One row above everything it scopes: month or year, and which one.
    private func filters(_ overview: Overview, _ period: Period) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Period", selection: Binding(get: { period.isYear }, set: { switchTo(year: $0, overview, period) })) {
                    Text("Month").tag(false)
                    Text("Year").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                Spacer()
                status
            }
            HStack(spacing: 4) {
                Button("Earlier", systemImage: "chevron.left") { go(period.previous) }
                    .labelStyle(.iconOnly)
                    .disabled(!canGo(period.previous, overview))
                Menu {
                    if period.isYear {
                        ForEach(overview.years, id: \.self) { year in Button(String(year)) { go(.year(year)) } }
                    } else {
                        ForEach(overview.months, id: \.self) { key in Button(monthTitle(key)) { go(.month(key)) } }
                    }
                } label: {
                    Text(title(period)).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                        .frame(minWidth: 160)
                }
                Button("Later", systemImage: "chevron.right") { go(period.next) }
                    .labelStyle(.iconOnly)
                    .disabled(!canGo(period.next, overview))
                Spacer()
            }
            .font(.title3)
        }
    }

    /// Within the months there are transactions for.
    private func canGo(_ to: Period, _ overview: Overview) -> Bool {
        guard let oldest = oldestMonth, let newest = newestMonth else { return false }
        switch (to, oldest, newest) {
        case (.month(let key), .month(let first), .month(let last)): return key >= first && key <= last
        case (.year(let year), _, _): return overview.years.contains(year) || (overview.years.min() ?? 0) < year && year < (overview.years.max() ?? 0)
        default: return false
        }
    }

    private func go(_ to: Period) {
        picked = to
        Telemetry.shared.log("overview-period", ["kind": to.isYear ? "year" : "month"])
    }

    /// A month becomes its year; a year becomes its newest month with transactions.
    private func switchTo(year: Bool, _ overview: Overview, _ period: Period) {
        switch (year, period) {
        case (true, .month(let key)): go(.year(Int(key.prefix(4)) ?? 0))
        case (false, .year(let y)):
            go(overview.months.first { $0.hasPrefix(String(format: "%04d-", y)) }.map(Period.month) ?? newestMonth ?? period)
        default: break
        }
    }

    /// What's on screen and how current it is: updating, or couldn't update.
    @ViewBuilder
    private var status: some View {
        if updating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if problem != nil {
            Button("Couldn't update · Try again", systemImage: "exclamationmark.triangle") { attempt += 1 }
                .font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: Figures

    /// The period's numbers. While an update runs they're last time's, so
    /// they're dimmed until the new ones arrive.
    private func figures(_ overview: Overview, _ period: Period) -> some View {
        let totals = overview.totals(for: period)
        let before = overview.has(period.previous) ? overview.totals(for: period.previous) : nil
        return VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                tile("Income", totals.income, before?.income, swatch: ChartColor.income)
                tile("Spending", totals.expenses, before?.expenses, swatch: ChartColor.spending)
                tile("Net", totals.net, before?.net, signed: true)
            }
            if totals.unreviewed > 0 {
                Label(totals.unreviewed == 1
                      ? "1 transaction in \(title(period)) isn't reviewed yet, so it isn't counted."
                      : "\(totals.unreviewed) transactions in \(title(period)) aren't reviewed yet, so they aren't counted.",
                      systemImage: "rectangle.stack")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TrendChart(overview: overview, period: period) { go($0) }
            CategoryBars(title: "Spending by category", lines: totals.expenseLines, color: ChartColor.spending) {
                category = CategoryPick(name: $0, kind: .expense)
            }
            CategoryBars(title: "Income by category", lines: totals.incomeLines, color: ChartColor.income) {
                category = CategoryPick(name: $0, kind: .income)
            }
        }
        .opacity(updating ? 0.45 : 1)
        .animation(.default, value: updating)
    }

    /// A headline number, and how it moved from the period before.
    private func tile(_ title: String, _ cents: Int, _ before: Int?, signed: Bool = false, swatch: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8) }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text((signed ? (cents < 0 ? "−" : "+") : "") + Money.text(cents))
                .font(.headline).minimumScaleFactor(0.6).lineLimit(1)
            if let before {
                let change = cents - before
                Label(change == 0 ? "Same as \(previousName)" : "\(Money.text(change)) vs \(previousName)",
                      systemImage: change > 0 ? "arrow.up" : (change < 0 ? "arrow.down" : "equal"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var previousName: String {
        switch period?.previous {
        case .month(let key)?: Self.shortMonth(key)
        case .year(let year)?: String(year)
        case nil: ""
        }
    }

    private func title(_ period: Period) -> String {
        switch period {
        case .month(let key): monthTitle(key)
        case .year(let year): String(year)
        }
    }

    static func shortMonth(_ key: String) -> String {
        guard let day = Day(key: key + "-01") else { return key }
        var c = DateComponents(); c.year = day.year; c.month = day.month; c.day = 1
        return (Calendar(identifier: .gregorian).date(from: c) ?? .now).formatted(.dateTime.month(.abbreviated))
    }

    private func refresh() async {
        updating = true
        problem = nil
        let started = Date.now
        do {
            let fresh = try await LedgerReader(modelContainer: context.container).overview()
            // Left the tab, or Try again, meanwhile: a newer read is under
            // way and owns `updating`, so this one leaves everything alone.
            guard !Task.isCancelled else { return }
            overview = fresh
            Telemetry.shared.log("overview-ready", ["seconds": String(format: "%.2f", Date.now.timeIntervalSince(started)),
                                                    "months": "\(fresh.months.count)"])
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription
            Telemetry.shared.log("overview-failed")
        }
        updating = false
    }
}

/// The two series' colors, the same in every chart: income is blue,
/// spending orange (the reference palette's first two slots, which stay
/// apart for colorblind readers in both modes).
enum ChartColor {
    static let income = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let spending = dynamic(light: 0xEB6834, dark: 0xD95926)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
    }
}

/// Income and spending side by side for each month of the last year, or
/// each year. The period on screen is full strength, the rest recede; tap
/// a column to look at that period.
struct TrendChart: View {
    let overview: Overview
    let period: Period
    let pick: (Period) -> Void
    @State private var selected: String?

    private struct Point: Identifiable {
        var period: Period
        var label: String
        var series: String
        var cents: Int
        var id: String { label + series }
    }

    private var points: [Point] {
        overview.trend(endingAt: period).flatMap { p -> [Point] in
            let totals = overview.totals(for: p)
            let label = Self.label(p)
            return [Point(period: p, label: label, series: "Income", cents: totals.income),
                    Point(period: p, label: label, series: "Spending", cents: totals.expenses)]
        }
    }

    static func label(_ p: Period) -> String {
        switch p {
        case .month(let key): OverviewScreen.shortMonth(key)
        case .year(let year): String(year)
        }
    }

    var body: some View {
        let points = points
        let current = Self.label(period)
        VStack(alignment: .leading, spacing: 8) {
            Text(period.isYear ? "Each year" : "The last 12 months").font(.headline)
            Chart(points) { point in
                BarMark(x: .value("Period", point.label), y: .value("Amount", Double(point.cents) / 100))
                    .foregroundStyle(by: .value("Series", point.series))
                    .position(by: .value("Series", point.series))
                    .cornerRadius(3)
                    .opacity(point.label == current ? 1 : 0.4)
            }
            .chartForegroundStyleScale(["Income": ChartColor.income, "Spending": ChartColor.spending])
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption2) }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel {
                        if let dollars = value.as(Double.self) {
                            Text(dollars.formatted(.currency(code: "USD").notation(.compactName).precision(.significantDigits(2))))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartXSelection(value: $selected)
            .onChange(of: selected) { _, label in
                guard let label, let hit = points.first(where: { $0.label == label }) else { return }
                pick(hit.period)
            }
            .frame(height: 220)
            .accessibilityLabel("Income and spending, \(period.isYear ? "by year" : "by month")")
        }
    }
}

/// One side of the ledger's categories as rows: name, a bar to scale, the
/// amount and its share. Rows, not a chart, so each is easy to tap and
/// reads as a table too. The first eight show; the rest are a tap away.
struct CategoryBars: View {
    let title: String
    let lines: [MonthTotals.Line]
    let color: Color
    let open: (String) -> Void
    @State private var all = false

    var body: some View {
        if !lines.isEmpty {
            let total = lines.reduce(0) { $0 + $1.cents }
            let largest = lines.map(\.cents).max() ?? 1
            let shown = all ? lines : Array(lines.prefix(8))
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                ForEach(shown) { line in
                    Button { open(line.name) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(line.name).lineLimit(1)
                                Spacer()
                                Text(Money.text(line.cents)).monospacedDigit()
                                Text(total > 0 ? "\(Int((Double(line.cents) * 100 / Double(total)).rounded()))%" : "")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                            .font(.subheadline)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color)
                                    .frame(width: max(geo.size.width * CGFloat(max(line.cents, 0)) / CGFloat(max(largest, 1)), 3))
                            }
                            .frame(height: 6)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows how it changed over time")
                }
                if lines.count > 8 {
                    Button(all ? "Show fewer" : "Show all \(lines.count)") { all.toggle() }
                        .font(.subheadline)
                }
            }
        }
    }
}

/// A category picked from the overview's rows.
struct CategoryPick: Identifiable {
    let name: String
    let kind: CategoryKind
    var id: String { kind.rawValue + name }
}

/// One category over the same stretch as the trend chart, against its own
/// average, with the period on screen picked out.
struct CategoryTrend: View {
    let pick: CategoryPick
    let overview: Overview
    let period: Period

    private var points: [(label: String, cents: Int, current: Bool)] {
        overview.trend(endingAt: period).map { p in
            let totals = overview.totals(for: p)
            let lines = pick.kind == .income ? totals.incomeLines : totals.expenseLines
            return (TrendChart.label(p), lines.first { $0.name == pick.name }?.cents ?? 0, p == period)
        }
    }

    var body: some View {
        let points = points
        let average = points.isEmpty ? 0 : points.reduce(0) { $0 + $1.cents } / points.count
        let now = points.last { $0.current }?.cents ?? 0
        let color = pick.kind == .income ? ChartColor.income : ChartColor.spending
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TrendChart.label(period)).font(.caption).foregroundStyle(.secondary)
                        Text(Money.text(now)).font(.title2.weight(.semibold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(period.isYear ? "Average year" : "Average month").font(.caption).foregroundStyle(.secondary)
                        Text(Money.text(average)).font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(points, id: \.label) { point in
                        BarMark(x: .value("Period", point.label), y: .value("Amount", Double(point.cents) / 100))
                            .foregroundStyle(color)
                            .cornerRadius(3)
                            .opacity(point.current ? 1 : 0.4)
                    }
                    RuleMark(y: .value("Average", Double(average) / 100))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Average").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.25))
                        AxisValueLabel {
                            if let dollars = value.as(Double.self) {
                                Text(dollars.formatted(.currency(code: "USD").notation(.compactName).precision(.significantDigits(2))))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 220)
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle(pick.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { Telemetry.shared.log("overview-category", ["kind": pick.kind.rawValue]) }
    }
}
