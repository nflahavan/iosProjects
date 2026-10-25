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
        try context.decide(entry, kind: .transfer, sign: 1, category: salary)
        #expect(entry.kind == .transfer)
        #expect(entry.category == nil)
        #expect(try context.reviewQueue().isEmpty)
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

    @Test("While typing, the last part takes what's left")
    func remainder() {
        var drafts = [SplitDraft(text: "100", category: groceries), SplitDraft(category: household)]
        #expect(drafts.cents(total: 15000) == [10000, 5000])
        #expect(drafts.resolved(total: 15000)?.map(\.cents) == [10000, 5000])
        drafts[0].text = "150"
        #expect(drafts.resolved(total: 15000) == nil)
    }
}
