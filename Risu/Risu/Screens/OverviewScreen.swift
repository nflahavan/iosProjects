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
            VStack(alignment: .leading, spacing: 8) {
                Text("Where it went").font(.headline)
                SankeyView(sankey: Sankey(totals: totals)) { category = $0 }
            }
            TrendChart(overview: overview, period: period) { go($0) }
            NetTrend(overview: overview, period: period)
            MonthBreakdown(overview: overview, period: period) { go($0) }
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

// MARK: Where it went

/// What a Sankey diagram of a period draws: income by category on the
/// left, all of it in the middle, spending by category on the right. What
/// wasn't spent flows on to Saved; spending past income comes in from
/// savings on the left, so both sides always add up to the middle.
/// Categories past the first few fold into one, so no flow is a thread.
nonisolated struct Sankey: Equatable {
    enum Role: Equatable { case income, fromSavings, spending, saved, rest }

    struct Node: Equatable {
        var name: String
        var cents: Int
        var role: Role
    }

    var left: [Node] = []
    var right: [Node] = []
    /// Both sides' total, which the middle bar stands for.
    var middle = 0

    init(totals: MonthTotals, maxLeft: Int = 4, maxRight: Int = 7) {
        // A category whose refunds outweigh its spending has nothing to draw.
        let income = totals.incomeLines.filter { $0.cents > 0 }
        let spending = totals.expenseLines.filter { $0.cents > 0 }
        left = Self.fold(income, keep: maxLeft, role: .income)
        right = Self.fold(spending, keep: maxRight, role: .spending)
        let inTotal = income.reduce(0) { $0 + $1.cents }, outTotal = spending.reduce(0) { $0 + $1.cents }
        if inTotal > outTotal { right.append(Node(name: "Saved", cents: inTotal - outTotal, role: .saved)) }
        if outTotal > inTotal { left.append(Node(name: "From savings", cents: outTotal - inTotal, role: .fromSavings)) }
        middle = max(inTotal, outTotal)
    }

    private static func fold(_ lines: [MonthTotals.Line], keep: Int, role: Role) -> [Node] {
        guard lines.count > keep + 1 else { return lines.map { Node(name: $0.name, cents: $0.cents, role: role) } }
        let rest = lines.dropFirst(keep).reduce(0) { $0 + $1.cents }
        return lines.prefix(keep).map { Node(name: $0.name, cents: $0.cents, role: role) }
            + [Node(name: "Everything else", cents: rest, role: .rest)]
    }
}

/// The Sankey drawn: bars for each side and the middle, ribbons between
/// them as wide as the money they carry, labels outside. Tap a category's
/// label for its history.
struct SankeyView: View {
    let sankey: Sankey
    let open: (CategoryPick) -> Void

    private let nodeWidth: CGFloat = 8, gap: CGFloat = 6, labelGap: CGFloat = 26
    private let leftLabels: CGFloat = 96, rightLabels: CGFloat = 124

    var body: some View {
        let rows = max(sankey.left.count, sankey.right.count)
        let height = max(240, CGFloat(rows) * (labelGap + gap) + 60)
        GeometryReader { geo in
            let layout = Layout(sankey: sankey, size: geo.size, nodeWidth: nodeWidth, gap: gap, slot: labelGap,
                                leftLabels: leftLabels, rightLabels: rightLabels)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for ribbon in layout.ribbons {
                        context.fill(ribbon.path, with: .color(color(ribbon.role).opacity(0.3)))
                    }
                    for bar in layout.bars {
                        context.fill(Path(roundedRect: bar.rect, cornerRadius: 2), with: .color(color(bar.role)))
                    }
                }
                ForEach(Array(labels(layout.leftBars, side: .leading, height: geo.size.height).enumerated()), id: \.offset) { _, label in
                    labelView(label).frame(width: leftLabels - 8, alignment: .trailing).position(x: (leftLabels - 8) / 2, y: label.y)
                }
                ForEach(Array(labels(layout.rightBars, side: .trailing, height: geo.size.height).enumerated()), id: \.offset) { _, label in
                    labelView(label).frame(width: rightLabels - 8, alignment: .leading)
                        .position(x: geo.size.width - (rightLabels - 8) / 2, y: label.y)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    private func color(_ role: Sankey.Role) -> Color {
        switch role {
        case .income, .saved: ChartColor.income
        case .spending: ChartColor.spending
        case .fromSavings, .rest: Color.secondary
        }
    }

    private struct Label {
        var node: Sankey.Node
        var y: CGFloat
    }

    /// Each bar's label at its middle, pushed apart where bars are too thin
    /// for their labels to fit beside them, and kept inside the frame.
    private func labels(_ bars: [Bar], side: HorizontalAlignment, height: CGFloat) -> [Label] {
        var labels = bars.map { Label(node: $0.node, y: $0.rect.midY) }
        for i in labels.indices.dropFirst() { labels[i].y = max(labels[i].y, labels[i - 1].y + labelGap) }
        if let last = labels.last, last.y > height - labelGap / 2 {
            labels[labels.count - 1].y = height - labelGap / 2
            for i in labels.indices.dropLast().reversed() { labels[i].y = min(labels[i].y, labels[i + 1].y - labelGap) }
        }
        return labels
    }

    @ViewBuilder
    private func labelView(_ label: Label) -> some View {
        let text = VStack(alignment: .leading, spacing: 0) {
            Text(label.node.name).font(.caption).lineLimit(1)
            Text(Money.text(label.node.cents)).font(.caption2).foregroundStyle(.secondary)
        }
        switch label.node.role {
        case .income, .spending:
            Button { open(CategoryPick(name: label.node.name, kind: label.node.role == .income ? .income : .expense)) } label: { text }
                .buttonStyle(.plain)
        default:
            text
        }
    }

    struct Bar {
        var node: Sankey.Node
        var rect: CGRect
        var role: Sankey.Role { node.role }
    }

    struct Ribbon {
        var path: Path
        var role: Sankey.Role
    }

    /// Where everything goes for a given size: one scale, cents to points,
    /// for both sides and the middle, so a ribbon is as wide at each end.
    struct Layout {
        var leftBars: [Bar] = []
        var rightBars: [Bar] = []
        var middle = CGRect.zero
        var ribbons: [Ribbon] = []
        var bars: [Bar] { leftBars + rightBars + [Bar(node: .init(name: "", cents: 0, role: .income), rect: middle)] }

        /// Every bar gets at least `slot` of height to itself, so its label
        /// can sit beside it; a thin bar is centred in its slot.
        init(sankey: Sankey, size: CGSize, nodeWidth: CGFloat, gap: CGFloat, slot: CGFloat, leftLabels: CGFloat, rightLabels: CGFloat) {
            guard sankey.middle > 0 else { return }
            // The scale that lets the fuller side fit, its thin bars' slots included.
            func fits(_ nodes: [Sankey.Node]) -> CGFloat {
                let room = size.height - gap * CGFloat(max(nodes.count - 1, 0))
                var scale = room / CGFloat(sankey.middle)
                for _ in 0..<4 {
                    let thin = nodes.filter { CGFloat($0.cents) * scale < slot }
                    let thick = nodes.reduce(0) { CGFloat($1.cents) * scale < slot ? $0 : $0 + $1.cents }
                    guard thick > 0 else { break }
                    scale = max(room - CGFloat(thin.count) * slot, 1) / CGFloat(thick)
                }
                return scale
            }
            let scale = min(fits(sankey.left), fits(sankey.right))
            func stack(_ nodes: [Sankey.Node], x: CGFloat) -> [Bar] {
                let slots = nodes.map { max(CGFloat($0.cents) * scale, slot) }
                var y = (size.height - slots.reduce(0, +) - gap * CGFloat(nodes.count - 1)) / 2
                return zip(nodes, slots).map { node, room in
                    let h = max(CGFloat(node.cents) * scale, 2)
                    defer { y += room + gap }
                    return Bar(node: node, rect: CGRect(x: x, y: y + (room - h) / 2, width: nodeWidth, height: h))
                }
            }
            leftBars = stack(sankey.left, x: leftLabels)
            rightBars = stack(sankey.right, x: size.width - rightLabels - nodeWidth)
            let middleHeight = CGFloat(sankey.middle) * scale
            middle = CGRect(x: (size.width - nodeWidth) / 2, y: (size.height - middleHeight) / 2, width: nodeWidth, height: middleHeight)

            func ribbon(from a: CGRect, edgeA: CGFloat, to b: CGRect, edgeB: CGFloat) -> Path {
                let mid = (edgeA + edgeB) / 2
                var p = Path()
                p.move(to: CGPoint(x: edgeA, y: a.minY))
                p.addCurve(to: CGPoint(x: edgeB, y: b.minY), control1: CGPoint(x: mid, y: a.minY), control2: CGPoint(x: mid, y: b.minY))
                p.addLine(to: CGPoint(x: edgeB, y: b.maxY))
                p.addCurve(to: CGPoint(x: edgeA, y: a.maxY), control1: CGPoint(x: mid, y: b.maxY), control2: CGPoint(x: mid, y: a.maxY))
                p.closeSubpath()
                return p
            }
            var into = middle.minY
            for bar in leftBars {
                let h = CGFloat(bar.node.cents) * scale
                let slot = CGRect(x: middle.minX, y: into, width: nodeWidth, height: h)
                into += h
                ribbons.append(Ribbon(path: ribbon(from: bar.rect, edgeA: bar.rect.maxX, to: slot, edgeB: middle.minX), role: bar.role))
            }
            var out = middle.minY
            for bar in rightBars {
                let h = CGFloat(bar.node.cents) * scale
                let slot = CGRect(x: middle.minX, y: out, width: nodeWidth, height: h)
                out += h
                ribbons.append(Ribbon(path: ribbon(from: slot, edgeA: middle.maxX, to: bar.rect, edgeB: bar.rect.minX), role: bar.role))
            }
        }
    }
}

// MARK: Net over time

/// Net over a rolling window, day by day: each point is what came in less
/// what went out over the days before it. Above the line is saving, below
/// is spending past income. The stretch on screen is shaded.
struct NetTrend: View {
    let overview: Overview
    let period: Period
    @AppStorage("netWindow") private var window = 30

    private static let windows = [7, 30, 90, 365]

    /// From the start of the trend's first period to the end of this one,
    /// stopping at the last day with anything in it.
    private var span: (first: Day, last: Day, shaded: (Day, Day))? {
        let periods = overview.trend(endingAt: period)
        guard let firstPeriod = periods.first, let lastData = overview.dailyNet.keys.max().flatMap(Day.init(key:)) else { return nil }
        let (start, _) = Self.bounds(firstPeriod)
        let (shadeStart, shadeEnd) = Self.bounds(period)
        let end = min(shadeEnd, lastData)
        guard start <= end else { return nil }
        return (start, end, (shadeStart, min(shadeEnd, end)))
    }

    static func bounds(_ p: Period) -> (Day, Day) {
        switch p {
        case .year(let y): return (Day(year: y, month: 1, day: 1), Day(year: y, month: 12, day: 31))
        case .month(let key):
            let first = Day(key: key + "-01") ?? Day(year: 1970, month: 1, day: 1)
            return (first, Period.month(key).next.firstDay.adding(days: -1))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Net over time").font(.headline)
                Spacer()
                Picker("Window", selection: $window) {
                    ForEach(Self.windows, id: \.self) { Text("\($0)d").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .onChange(of: window) { _, new in Telemetry.shared.log("net-window", ["days": "\(new)"]) }
            }
            if let span {
                let days = (span.last.date.timeIntervalSince(span.first.date) / 86_400).rounded()
                let points = overview.rollingNet(window: window, from: span.first, to: span.last, step: max(Int(days / 240), 1))
                if let latest = points.last {
                    Text("Past \(window) days to \(latest.day.shortTitle): \(latest.cents < 0 ? "−" : "+")\(Money.text(latest.cents))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Chart {
                    RectangleMark(xStart: .value("From", span.shaded.0.date), xEnd: .value("To", span.shaded.1.date))
                        .foregroundStyle(Color.secondary.opacity(0.1))
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
                    ForEach(points, id: \.day) { point in
                        LineMark(x: .value("Day", point.day.date), y: .value("Net", Double(point.cents) / 100))
                            .foregroundStyle(Color.primary)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
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
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine().foregroundStyle(.clear); AxisValueLabel().font(.caption2) } }
                .frame(height: 200)
                .accessibilityLabel("Net over \(window)-day windows")
            } else {
                Text("No reviewed income or spending in this stretch yet.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Months

/// Month by month: income, spending and net, newest first: the year's
/// months, or the last twelve. Tap one to look at it.
struct MonthBreakdown: View {
    let overview: Overview
    let period: Period
    let go: (Period) -> Void

    private var months: [String] {
        switch period {
        case .year(let y): overview.months.filter { $0.hasPrefix(String(format: "%04d-", y)) }
        case .month: overview.trend(endingAt: period).reversed().compactMap { if case .month(let k) = $0, overview.has($0) { k } else { nil } }
        }
    }

    var body: some View {
        let months = months
        if !months.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(period.isYear ? "Month by month" : "The last 12 months, month by month").font(.headline)
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 0) {
                    GridRow {
                        Text("Month").gridColumnAlignment(.leading)
                        Text("Income"); Text("Spending"); Text("Net")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                    ForEach(months, id: \.self) { key in
                        let t = overview.totals(for: .month(key))
                        GridRow {
                            Text(OverviewScreen.shortMonth(key) + (period.isYear ? "" : " \(key.prefix(4).suffix(2))"))
                                .gridColumnAlignment(.leading)
                            Text(Money.text(t.income))
                            Text(Money.text(t.expenses))
                            Text((t.net < 0 ? "−" : "+") + Money.text(t.net))
                        }
                        .font(.subheadline.monospacedDigit())
                        .fontWeight(period == .month(key) ? .bold : .regular)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { go(.month(key)) }
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
        }
    }
}
