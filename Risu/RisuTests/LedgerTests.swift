import Foundation
import SwiftData
import Testing
@testable import Risu

/// The store end to end, with invented files.
@Suite("Ledger")
struct LedgerTests {

    let context: ModelContext
    let mapping = ColumnMapping(date: 0, description: 1, amount: .single(column: 2, moneyInIsPositive: true),
                                dateLayout: .monthDayYear)

    init() throws {
        context = ModelContext(try RisuStore.container(inMemory: true))
    }

    func csv(_ rows: String) -> Data { Data("Date,Description,Amount\n\(rows)".utf8) }

    @Test("A source's second file brings in only what's new")
    func overlappingFiles() throws {
        let card = try context.addSource(name: "Card", header: ["Date", "Description", "Amount"], mapping: mapping)
        let first = try context.importFile(named: "sept.csv", contents: csv("""
        09/30/2026,COFFEE,-4.50
        10/01/2026,GROCER,-20.00
        """), into: card)
        #expect(first == ImportSummary(new: 2, alreadyHere: 0, unreadable: 0))

        let second = try context.importFile(named: "oct.csv", contents: csv("""
        10/01/2026,GROCER,-20.00
        10/02/2026,GAS,-30.00
        oops,BAD,1
        """), into: card)
        #expect(second == ImportSummary(new: 1, alreadyHere: 1, unreadable: 1))
        #expect(try context.reviewQueue().map(\.text) == ["GAS", "GROCER", "COFFEE"])
    }

    @Test("A pending charge that posted differently is found gone, and removed only when asked")
    func pendingPosted() async throws {
        let card = try context.addSource(name: "Card", header: ["Date", "Description", "Amount"], mapping: mapping)
        try context.importFile(named: "early.csv", contents: csv("""
        09/01/2026,RENT,-900.00
        10/01/2026,GROCER,-20.00
        10/02/2026,PENDING DINER,-40.00
        """), into: card)
        let pending = try #require(try context.reviewQueue().first { $0.text == "PENDING DINER" })
        try context.decide(pending, kind: .expense, sign: 1, category: context.category(named: "Eating out", kind: .expense))

        // The tip went on and it posted the next day. September isn't in this file, so rent isn't judged.
        let later = try context.importFile(named: "later.csv", contents: csv("""
        10/01/2026,GROCER,-20.00
        10/03/2026,DINER,-48.00
        """), into: card)
        #expect(later.new == 1)
        #expect(later.gone == [pending.persistentModelID])
        #expect(later.goneReviewed == 1)
        #expect(try context.fetch(FetchDescriptor<LedgerEntry>()).count == 4)

        #expect(try context.removeGone(later.gone) == 1)
        #expect(try context.fetch(FetchDescriptor<LedgerEntry>()).map(\.text).sorted() == ["DINER", "GROCER", "RENT"])
        #expect(try context.removeGone(later.gone) == 0)
        // Read again on its own context, the overview counts the dinner once: unreviewed, as posted.
        let overview = try await LedgerReader(modelContainer: context.container).overview()
        #expect(overview.totals["2026-10"]?.expenses == 0)
        #expect(overview.totals["2026-10"]?.unreviewed == 2)

        // The same file again finds nothing gone or new.
        let again = try context.importFile(named: "later.csv", contents: csv("10/01/2026,GROCER,-20.00\n10/03/2026,DINER,-48.00"), into: card)
        #expect(again == ImportSummary(new: 0, alreadyHere: 2, unreadable: 0))
    }

    @Test("The review reads its rows off the main thread, by account too")
    func oneAccount() async throws {
        let header = ["Date", "Description", "Amount"]
        let card = try context.addSource(name: "Card", header: header, mapping: mapping)
        let bank = try context.addSource(name: "Bank", header: header, mapping: mapping)
        try context.importFile(named: "card.csv", contents: csv("09/30/2026,COFFEE,-4.50\n10/01/2026,GAS,-30.00"), into: card)
        try context.importFile(named: "bank.csv", contents: csv("10/02/2026,RENT,-900.00"), into: bank)
        let reader = { try await LedgerReader(modelContainer: context.container).review() }
        // Looked up the way the screen does, one row at a time.
        func texts(_ rows: [ReviewSnapshot.Row]) throws -> [String] {
            try rows.map { try #require(try context.entry($0.id)).text }
        }

        var snapshot = try await reader()
        #expect(try texts(snapshot.waiting) == ["RENT", "GAS", "COFFEE"])
        #expect(try texts(snapshot.waiting(in: "Bank")) == ["RENT"])

        // Deciding moves the row at once, to where the next read puts it.
        let rent = try #require(snapshot.waiting(in: "Bank").first)
        try context.decide(try #require(try context.entry(rent.id)), kind: .transfer, sign: 1, category: nil)
        snapshot.decide(rent.id)
        #expect(snapshot == (try await reader()))
        #expect(snapshot.waiting(in: "Bank").isEmpty)
        #expect(try texts(snapshot.decided(in: "Bank")) == ["RENT"])
        #expect(snapshot.decided(in: "Card").isEmpty)
    }

    @Test("What you just imported comes up first, ahead of older rows still waiting")
    func newestFirst() throws {
        let card = try context.addSource(name: "Card", header: ["Date", "Description", "Amount"], mapping: mapping)
        try context.importFile(named: "old.csv", contents: csv("01/05/2026,OLD A,-1.00\n01/06/2026,OLD B,-1.00"), into: card)
        try context.importFile(named: "new.csv", contents: csv("10/20/2026,NEW A,-1.00\n10/21/2026,NEW B,-1.00"), into: card)
        #expect(try context.reviewQueue().map(\.text) == ["NEW B", "NEW A", "OLD B", "OLD A"])
    }

    @Test("Another source's identical row isn't a duplicate")
    func perSource() throws {
        let header = ["Date", "Description", "Amount"]
        let a = try context.addSource(name: "Checking", header: header, mapping: mapping)
        let b = try context.addSource(name: "Card", header: header, mapping: mapping)
        let row = csv("10/05/2026,CARD PAYMENT,-500.00")
        try context.importFile(named: "a.csv", contents: row, into: a)
        #expect(try context.importFile(named: "b.csv", contents: row, into: b).new == 1)
    }

    @Test("A file with other columns is refused, and nothing is stored")
    func shape() throws {
        let card = try context.addSource(name: "Card", header: ["Date", "Description", "Amount"], mapping: mapping)
        #expect(throws: LedgerError.shapeMismatch("Card")) {
            try context.importFile(named: "x.csv", contents: Data("Posted,Payee,Debit\n1,2,3".utf8), into: card)
        }
        #expect(try context.fetchCount(FetchDescriptor<ImportedFile>()) == 0)
    }

    @Test("Two sources can't share a name, whatever the case")
    func sourceNames() throws {
        _ = try context.addSource(name: "Card", header: [], mapping: mapping)
        #expect(throws: LedgerError.sourceExists("card")) {
            _ = try context.addSource(name: "card", header: [], mapping: mapping)
        }
    }

    @Test("Deciding needs a category, from the matching list, except for a transfer")
    func decideRules() throws {
        let card = try context.addSource(name: "Card", header: ["Date", "Description", "Amount"], mapping: mapping)
        try context.importFile(named: "a.csv", contents: csv("10/01/2026,X,-1.00"), into: card)
        let entry = try #require(try context.reviewQueue().first)
        let salary = try context.category(named: "Salary", kind: .income)

        #expect(throws: LedgerError.needsCategory) { try context.decide(entry, kind: .expense, sign: 1, category: nil) }
        #expect(throws: LedgerError.wrongCategoryKind) { try context.decide(entry, kind: .expense, sign: 1, category: salary) }
        #expect(throws: LedgerError.wrongCategoryKind) { try context.decide(entry, kind: .transfer, sign: 1, category: salary) }
        try context.decide(entry, kind: .transfer, sign: 1, category: nil)
        #expect(entry.kind == .transfer)
        #expect(entry.category == nil)
        #expect(try context.reviewQueue().isEmpty)
        let savings = try context.category(named: "To savings", kind: .transfer)
        try context.decide(entry, kind: .transfer, sign: 1, category: savings)
        #expect(entry.category === savings)
    }

    @Test("Chips come most-used first, then by name")
    func chipOrder() throws {
        let card = try context.addSource(name: "Card", header: ["Date", "Description", "Amount"], mapping: mapping)
        try context.importFile(named: "a.csv", contents: csv("""
        10/01/2026,A,-1.00
        10/02/2026,B,-1.00
        10/03/2026,C,-1.00
        """), into: card)
        let dining = try context.category(named: "Dining", kind: .expense)
        let groceries = try context.category(named: "Groceries", kind: .expense)
        _ = try context.category(named: "Auto", kind: .expense)
        for entry in try context.reviewQueue() {
            try context.decide(entry, kind: .expense, sign: 1, category: entry.text == "A" ? dining : groceries)
        }
        #expect(context.categories(.expense).map(\.name) == ["Groceries", "Dining", "Auto"])
    }

    @Test("Adding a category that exists hands back the existing one")
    func categoryReuse() throws {
        let one = try context.category(named: "Groceries", kind: .expense)
        let two = try context.category(named: " groceries ", kind: .expense)
        #expect(one === two)
        #expect(try context.category(named: "Groceries", kind: .income) !== one)
    }

    @Test("A category in use can't be deleted")
    func removeInUse() throws {
        let card = try context.addSource(name: "Card", header: ["Date", "Description", "Amount"], mapping: mapping)
        try context.importFile(named: "a.csv", contents: csv("10/01/2026,X,-1.00"), into: card)
        let gifts = try context.category(named: "Gifts", kind: .expense)
        try context.decide(try #require(try context.reviewQueue().first), kind: .expense, sign: 1, category: gifts)
        #expect(throws: LedgerError.categoryInUse("Gifts")) { try context.remove(gifts) }
    }
}

@Suite("Month totals")
struct MonthTotalsTests {

    typealias Item = MonthTotals.Item

    @Test("A refund takes away from its category; transfers and unreviewed rows don't count")
    func totals() {
        let items = [
            Item(monthKey: "2026-10", kind: .income, contribution: 300000, category: "Salary"),
            Item(monthKey: "2026-10", kind: .expense, contribution: 10000, category: "Groceries"),
            Item(monthKey: "2026-10", kind: .expense, contribution: -2500, category: "Groceries"),
            Item(monthKey: "2026-10", kind: .expense, contribution: 4000, category: "Dining"),
            Item(monthKey: "2026-10", kind: .transfer, contribution: 50000, category: nil),
            Item(monthKey: "2026-10", kind: nil, contribution: 999, category: nil),
            Item(monthKey: "2026-09", kind: .expense, contribution: 777, category: "Dining"),
        ]
        let t = MonthTotals(month: "2026-10", items: items)
        #expect(t.income == 300000)
        #expect(t.expenses == 11500)
        #expect(t.net == 288500)
        #expect(t.expenseLines.map(\.name) == ["Groceries", "Dining"])
        #expect(t.expenseLines.first?.cents == 7500)
        #expect(t.unreviewed == 1)
    }

    @Test("Transfers add up by label, out and in apart, with the unlabelled last")
    func transfers() {
        let items = [
            Item(monthKey: "2026-10", kind: .transfer, contribution: -50000, category: "To savings"),
            Item(monthKey: "2026-10", kind: .transfer, contribution: 50000, category: "To savings"),
            Item(monthKey: "2026-10", kind: .transfer, contribution: -20000, category: "To savings"),
            Item(monthKey: "2026-10", kind: .transfer, contribution: -999999, category: nil),
            Item(monthKey: "2026-10", kind: .transfer, contribution: -1000, category: "Card payment"),
        ]
        let t = MonthTotals(month: "2026-10", items: items)
        #expect(t.income == 0 && t.expenses == 0)
        #expect(t.transferLines.map(\.name) == ["To savings", "Card payment", MonthTotals.unlabelled])
        #expect(t.transferLines[0].out == 70000 && t.transferLines[0].into == 50000)
        let year = MonthTotals(adding: [t, t])
        #expect(year.transferLines[0].out == 140000)
        #expect(year.transferLines.last?.out == 1999998)
    }

    @Test("A transaction's contribution follows its sign, not the bank's")
    func contribution() throws {
        let context = ModelContext(try RisuStore.container(inMemory: true))
        let source = Source(name: "S", header: [], mapping: ColumnMapping(date: 0, description: 0,
            amount: .single(column: 0, moneyInIsPositive: true), dateLayout: .monthDayYear))
        context.insert(source)
        let file = ImportedFile(name: "f", contents: Data(), source: source)
        context.insert(file)
        let refund = LedgerEntry(parsed: ParsedRow(day: Day(year: 2026, month: 10, day: 1), text: "R", amountCents: 2500),
                                 row: 0, file: file)
        context.insert(refund)
        refund.sign = -1
        #expect(refund.contribution == -2500)
        refund.sign = 1
        #expect(refund.contribution == 2500)
    }
}

@Suite("Going back in the review")
struct GoingBackTests {

    @Test("Back steps through decided rows, newest first; changing one keeps its place")
    func order() async throws {
        let context = ModelContext(try RisuStore.container(inMemory: true))
        let mapping = ColumnMapping(date: 0, description: 1, amount: .single(column: 2, moneyInIsPositive: true),
                                    dateLayout: .monthDayYear)
        let card = try context.addSource(name: "Card", header: ["Date", "Description", "Amount"], mapping: mapping)
        try context.importFile(named: "a.csv", contents: Data("Date,Description,Amount\n10/01/2026,A,-1\n10/02/2026,B,-1\n10/03/2026,C,-1".utf8), into: card)
        let food = try context.category(named: "Food", kind: .expense)
        for entry in try context.reviewQueue() {
            try context.decide(entry, kind: .expense, sign: 1, category: food)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(try context.recentlyDecided().map(\.text) == ["A", "B", "C"])

        let fun = try context.category(named: "Fun", kind: .expense)
        let b = try #require(try context.recentlyDecided().first { $0.text == "B" })
        try context.decide(b, kind: .expense, sign: 1, category: fun)
        #expect(b.category === fun)
        #expect(try context.recentlyDecided().map(\.text) == ["A", "B", "C"])
    }
}

@Suite("Splitting a transaction")
struct SplitTests {

    let context: ModelContext
    let entry: LedgerEntry
    let groceries: Risu.Category
    let household: Risu.Category

    init() throws {
        context = ModelContext(try RisuStore.container(inMemory: true))
        let mapping = ColumnMapping(date: 0, description: 1, amount: .single(column: 2, moneyInIsPositive: true),
                                    dateLayout: .monthDayYear)
        let card = try context.addSource(name: "Card", header: ["Date", "Description", "Amount"], mapping: mapping)
        try context.importFile(named: "a.csv", contents: Data("Date,Description,Amount\n10/04/2026,TARGET,-150.00".utf8), into: card)
        entry = try #require(try context.reviewQueue().first)
        groceries = try context.category(named: "Groceries", kind: .expense)
        household = try context.category(named: "Household", kind: .expense)
    }

    @Test("Parts must add up to the bank amount, to the cent")
    func addsUp() throws {
        #expect(throws: LedgerError.splitDoesNotAddUp(total: 14999, expected: 15000)) {
            try context.decideSplit(entry, kind: .expense, sign: 1, parts: [(10000, groceries, ""), (4999, household, "")])
        }
        try context.decideSplit(entry, kind: .expense, sign: 1, parts: [(10000, groceries, ""), (5000, household, "")])
        #expect(entry.isSplit)
        #expect(entry.category == nil)
        #expect(entry.shares.map(\.contribution) == [10000, 5000])
    }

    @Test("A transfer can't be split, and a split needs two real parts")
    func rules() {
        #expect(throws: LedgerError.transferSplit) {
            try context.decideSplit(entry, kind: .transfer, sign: 1, parts: [(10000, groceries, ""), (5000, household, "")])
        }
        #expect(throws: LedgerError.splitNeedsParts) {
            try context.decideSplit(entry, kind: .expense, sign: 1, parts: [(15000, groceries, "")])
        }
        #expect(throws: LedgerError.splitNeedsParts) {
            try context.decideSplit(entry, kind: .expense, sign: 1, parts: [(15000, groceries, ""), (0, household, "")])
        }
    }

    @Test("Deciding it as one category again clears the parts")
    func unsplit() throws {
        try context.decideSplit(entry, kind: .expense, sign: 1, parts: [(10000, groceries, ""), (5000, household, "")])
        try context.decide(entry, kind: .expense, sign: 1, category: groceries)
        #expect(!entry.isSplit)
        #expect(try context.fetchCount(FetchDescriptor<SplitPart>()) == 0)
    }

    @Test("Each part counts in its own category, and as a use of it")
    func totalsAndUses() async throws {
        try context.decideSplit(entry, kind: .expense, sign: 1, parts: [(10000, groceries, ""), (5000, household, "")])
        // Added up off the main thread, from its own context on the store.
        let overview = try await LedgerReader(modelContainer: context.container).overview()
        let totals = try #require(overview.totals[overview.months.first ?? ""])
        #expect(totals.expenses == 15000)
        #expect(totals.expenseLines.map(\.name) == ["Groceries", "Household"])
        #expect(household.uses == 1)
        #expect(throws: LedgerError.categoryInUse("Household")) { try context.remove(household) }
    }

    @Test("A category lists each transaction once, with its share of a split")
    func categoryLines() throws {
        let source = try #require(entry.file?.source)
        try context.importFile(named: "b.csv", contents: Data("""
        Date,Description,Amount
        10/02/2026,GROCER,-20.00
        10/09/2026,GROCER REFUND,5.00
        """.utf8), into: source)
        let queue = try context.reviewQueue()
        let grocer = try #require(queue.first { $0.text == "GROCER" })
        let refund = try #require(queue.first { $0.text == "GROCER REFUND" })
        try context.decide(grocer, kind: .expense, sign: 1, category: groceries)
        try context.decide(refund, kind: .expense, sign: -1, category: groceries)
        // Two receipt lines in groceries make one line of 120, not two.
        try context.decideSplit(entry, kind: .expense, sign: 1,
                                parts: [(10000, groceries, "Milk"), (3000, household, "Soap"), (2000, groceries, "Eggs")])

        let lines = groceries.lines
        #expect(lines.map(\.entry.text) == ["GROCER REFUND", "TARGET", "GROCER"])
        #expect(lines.map(\.cents) == [500, 12000, 2000])
        #expect(lines.map(\.isPartial) == [false, true, false])
        #expect(lines.map(\.bankCents) == [500, -12000, -2000])
        #expect(lines.reduce(0) { $0 + $1.counted } == 13500)
        #expect(household.lines.map(\.cents) == [3000])
    }

    @Test("A split row is still one bank row to the merge")
    func merge() throws {
        try context.decideSplit(entry, kind: .expense, sign: 1, parts: [(10000, groceries, ""), (5000, household, "")])
        let source = try #require(entry.file?.source)
        let again = try context.importFile(named: "b.csv", contents: Data("Date,Description,Amount\n10/04/2026,TARGET,-150.00".utf8), into: source)
        #expect(again.new == 0)
    }

    @Test("Dragging the line between two parts moves money between those two only, a percent at a time")
    func shares() {
        var drafts = [SplitDraft(cents: 7500, category: groceries), SplitDraft(cents: 2500, category: household), SplitDraft()]
        // 150.00 split 75 / 25 / 50. Move the first line to 40%: the second part pays for it.
        drafts.moveBoundary(after: 0, toPercent: 40, total: 15000)
        #expect(drafts.cents(total: 15000) == [6000, 4000, 5000])
        // The last line trades with the last part, which takes what's left.
        drafts.moveBoundary(after: 1, toPercent: 90, total: 15000)
        #expect(drafts.cents(total: 15000) == [6000, 7500, 1500])
        // Dragged past a neighbour, each part keeps a cent.
        drafts.moveBoundary(after: 1, toPercent: 0, total: 15000)
        #expect(drafts.cents(total: 15000) == [6000, 1, 8999])
        #expect(drafts.resolved(total: 15000) == nil)  // the last part has no category yet
    }

    @Test("A year adds up its months; periods step across year ends; a trend keeps empty months")
    func periods() {
        var a = MonthTotals(); a.income = 100; a.expenses = 40; a.incomeLines = [.init(name: "Pay", cents: 100)]
        a.expenseLines = [.init(name: "Food", cents: 30), .init(name: "Gas", cents: 10)]
        var b = MonthTotals(); b.expenses = 25; b.expenseLines = [.init(name: "Gas", cents: 25)]; b.unreviewed = 2
        let overview = Overview(months: ["2026-02", "2025-12"], totals: ["2026-02": a, "2025-12": b])
        let year = overview.totals(for: .year(2026))
        #expect(year.income == 100 && year.expenses == 40)
        #expect(overview.totals(for: .year(2025)).expenseLines.map(\.name) == ["Gas"])
        #expect(MonthTotals(adding: [a, b]).expenseLines.map(\.cents) == [35, 30])
        #expect(MonthTotals(adding: [a, b]).unreviewed == 2)
        #expect(Period.month("2026-01").previous == .month("2025-12"))
        #expect(Period.month("2025-12").next == .month("2026-01"))
        #expect(overview.years == [2026, 2025])
        let trend = overview.trend(endingAt: .month("2026-02"))
        #expect(trend.count == 12 && trend.first == .month("2025-03") && trend.last == .month("2026-02"))
        #expect(overview.totals(for: .month("2026-01")) == MonthTotals())
        #expect(overview.trend(endingAt: .year(2026)) == [.year(2025), .year(2026)])
    }

    @Test("A Sankey balances: saved or from savings makes both sides the middle; small categories fold")
    func sankey() {
        var t = MonthTotals()
        t.incomeLines = [.init(name: "Pay", cents: 1000)]
        t.expenseLines = (1...10).map { .init(name: "C\($0)", cents: 100 - $0) } + [.init(name: "Refunded", cents: -20)]
        let s = Sankey(totals: t, maxLeft: 4, maxRight: 7)
        #expect(s.right.map(\.name) == ["C1", "C2", "C3", "C4", "C5", "C6", "C7", "Everything else", "Saved"])
        #expect(s.right.first { $0.name == "Everything else" }?.cents == 92 + 91 + 90)
        #expect(s.middle == 1000 && s.right.reduce(0) { $0 + $1.cents } == 1000)
        t.incomeLines = [.init(name: "Pay", cents: 500)]
        let over = Sankey(totals: t)
        #expect(over.left.map(\.name) == ["Pay", "From savings"])
        #expect(over.left.reduce(0) { $0 + $1.cents } == over.middle && over.middle == 945)
        // Eight lines where seven fit: no fold just to hide one.
        t.expenseLines = Array(t.expenseLines.prefix(8))
        #expect(!Sankey(totals: t).right.contains { $0.role == .rest })
    }

    @Test("Net over a rolling window, day by day, across a month end")
    func rolling() {
        let overview = Overview(dailyNet: ["2026-09-29": 100, "2026-09-30": -40, "2026-10-01": 10, "2026-10-03": 5])
        let points = overview.rollingNet(window: 2, from: Day(year: 2026, month: 9, day: 30), to: Day(year: 2026, month: 10, day: 3))
        #expect(points.map(\.day.key) == ["2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03"])
        #expect(points.map(\.cents) == [60, -30, 10, 5])
        let sparse = overview.rollingNet(window: 3, from: Day(year: 2026, month: 9, day: 30), to: Day(year: 2026, month: 10, day: 3), step: 2)
        #expect(sparse.map(\.day.key) == ["2026-09-30", "2026-10-02", "2026-10-03"])
        #expect(Day(year: 2026, month: 3, day: 1).adding(days: -1).key == "2026-02-28")
    }

    @Test("Category search: start of the name, then start of a word, then anywhere; most used first within each")
    func categorySearch() {
        let names = ["Go Out to Eat", "Isthmus Eats", "Coffee", "Gas", "Household Items", "Café Lunch", "Groceries"]
        #expect(CategorySearch.rank(names, for: "ea").map { names[$0] } == ["Go Out to Eat", "Isthmus Eats"])
        #expect(CategorySearch.rank(names, for: "g").map { names[$0] } == ["Go Out to Eat", "Gas", "Groceries"])
        #expect(CategorySearch.rank(names, for: "ITEM").map { names[$0] } == ["Household Items"])
        #expect(CategorySearch.rank(names, for: "cafe").map { names[$0] } == ["Café Lunch"])
        #expect(CategorySearch.rank(names, for: "ff").map { names[$0] } == ["Coffee"])
        #expect(CategorySearch.rank(names, for: "  ").count == names.count)
        #expect(CategorySearch.rank(names, for: "zzz").isEmpty)
    }

    @Test("While typing, the last part takes what's left")
    func remainder() {
        var drafts = [SplitDraft(text: "100", category: groceries), SplitDraft(category: household)]
        #expect(drafts.cents(total: 15000) == [10000, 5000])
        #expect(drafts.resolved(total: 15000)?.map(\.cents) == [10000, 5000])
        drafts[0].text = "150"
        #expect(drafts.resolved(total: 15000) == nil)
    }
}
