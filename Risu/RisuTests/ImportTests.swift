import Foundation
import Testing
@testable import Risu

/// Every row here is invented. Real bank exports never go in the repo.
@Suite("Reading CSVs")
struct CSVTableTests {

    @Test("Quotes may hold commas, doubled quotes and line breaks")
    func quotes() {
        let table = CSVTable(text: "Date,Description,Amount\r\n10/03/2026,\"Joe's \"\"Best\"\" Coffee, Inc.\",-4.50\r\n10/04/2026,\"Two\nlines\",12\r\n")
        #expect(table.header == ["Date", "Description", "Amount"])
        #expect(table.rows == [["10/03/2026", "Joe's \"Best\" Coffee, Inc.", "-4.50"],
                               ["10/04/2026", "Two\nlines", "12"]])
    }

    @Test("A byte-order mark and a missing final newline don't matter")
    func bomAndEnding() {
        let table = CSVTable(text: "\u{FEFF}Date,Amount\n10/03/2026,1")
        #expect(table.header == ["Date", "Amount"])
        #expect(table.rows == [["10/03/2026", "1"]])
    }

    @Test("A summary block above the table is skipped")
    func preamble() {
        let text = """
        Description,,Summary Amt.
        Beginning balance as of 10/01/2026,,"1,000.00"
        Ending balance as of 10/31/2026,,"900.00"

        Date,Description,Amount,Running Bal.
        10/02/2026,COFFEE SHOP,-4.50,995.50
        10/03/2026,PAYCHECK,100.00,1095.50
        10/04/2026,GROCER,-20.00,1075.50
        10/05/2026,GROCER,-20.00,1055.50
        """
        let table = CSVTable(text: text)
        #expect(table.header == ["Date", "Description", "Amount", "Running Bal."])
        #expect(table.rows.count == 4)
    }
}

@Suite("Money")
struct MoneyTests {

    @Test("Amounts the way banks write them", arguments: [
        ("1234.56", 123456), ("$1,234.56", 123456), ("-12.34", -1234), ("12.34-", -1234),
        ("(12.34)", -1234), ("+5", 500), ("5.5", 550), (".75", 75), ("-$3.00", -300), ("0", 0),
    ])
    func reads(text: String, cents: Int) {
        #expect(Money.cents(from: text) == cents)
    }

    @Test("Things that aren't money", arguments: ["", "abc", "1.234", "12.3.4", "10/03/2026", "1e5"])
    func rejects(text: String) {
        #expect(Money.cents(from: text) == nil)
    }
}

@Suite("Dates")
struct DayTests {

    @Test("Each layout reads its own order")
    func layouts() {
        #expect(Day("10/03/2026", format: .monthDayYear) == Day(year: 2026, month: 10, day: 3))
        #expect(Day("03/10/2026", format: .dayMonthYear) == Day(year: 2026, month: 10, day: 3))
        #expect(Day("2026-10-03", format: .yearMonthDay) == Day(year: 2026, month: 10, day: 3))
        #expect(Day("10/3/26", format: .monthDayYear) == Day(year: 2026, month: 10, day: 3))
    }

    @Test("Impossible dates are refused")
    func impossible() {
        #expect(Day("02/30/2026", format: .monthDayYear) == nil)
        #expect(Day("13/01/2026", format: .monthDayYear) == nil)
    }

    @Test("A column that fits both orders leads with month first; a 13th settles it")
    func fitting() {
        #expect(DateLayout.fitting(["10/03/2026", "10/04/2026"]) == [.monthDayYear, .dayMonthYear])
        #expect(DateLayout.fitting(["10/03/2026", "10/13/2026"]) == [.monthDayYear])
        #expect(DateLayout.fitting(["13/10/2026"]) == [.dayMonthYear])
        #expect(DateLayout.fitting(["COFFEE"]).isEmpty)
    }
}

@Suite("Mapping columns")
struct MappingTests {

    let card = CSVTable(text: """
    Transaction Date,Post Date,Description,Category,Type,Amount,Memo
    10/02/2026,10/03/2026,COFFEE SHOP,Food & Drink,Sale,-4.50,
    10/03/2026,10/04/2026,AMAZON MKTPL,Shopping,Sale,-23.99,
    10/05/2026,10/05/2026,Payment Thank You,,Payment,500.00,
    """)

    @Test("A card export: transaction date, description, one signed amount")
    func guessesCard() throws {
        let mapping = try #require(MappingGuess.guess(card))
        #expect(mapping.date == 0)
        #expect(mapping.description == 2)
        #expect(mapping.amount == .single(column: 5, moneyInIsPositive: true))
        #expect(mapping.dateLayout == .monthDayYear)
    }

    @Test("Debit and credit columns become one amount, money in positive")
    func split() throws {
        let table = CSVTable(text: """
        Date,Payee,Debit,Credit,Balance
        2026-10-02,COFFEE SHOP,4.50,,995.50
        2026-10-03,PAYCHECK,,"1,200.00",2195.50
        """)
        let mapping = try #require(MappingGuess.guess(table))
        #expect(mapping.amount == .split(moneyOut: 2, moneyIn: 3))
        #expect(try mapping.read(table.rows[0]).get().amountCents == -450)
        #expect(try mapping.read(table.rows[1]).get().amountCents == 120000)
    }

    @Test("A card that shows purchases as positive is flipped")
    func positivePurchases() throws {
        let mapping = ColumnMapping(date: 0, description: 1, amount: .single(column: 2, moneyInIsPositive: false),
                                    dateLayout: .monthDayYear)
        let row = try mapping.read(["10/02/2026", "COFFEE SHOP", "4.50"]).get()
        #expect(row.amountCents == -450)
    }

    @Test("A bad cell says which and why")
    func problems() {
        let mapping = ColumnMapping(date: 0, description: 1, amount: .single(column: 2, moneyInIsPositive: true),
                                    dateLayout: .monthDayYear)
        #expect(mapping.read(["soon", "X", "1"]) == .failure(.date("soon")))
        #expect(mapping.read(["10/02/2026", "X", "lots"]) == .failure(.amount("lots")))
    }
}

@Suite("Merging a source's files")
struct MergeTests {

    func row(_ d: Int, _ text: String, _ cents: Int) -> ParsedRow {
        ParsedRow(day: Day(year: 2026, month: 10, day: d), text: text, amountCents: cents)
    }

    @Test("Rows already held are skipped; new ones kept, in file order")
    func overlap() {
        let existing = [row(1, "COFFEE", -450), row(2, "GROCER", -2000)].map(\.mergeKey)
        let incoming = [row(2, "GROCER", -2000), row(3, "GAS", -3000), row(4, "COFFEE", -450)]
        let fresh = SourceMerge.newRows(Array(zip(0..., incoming)).map { ($0.0, $0.1) }, existing: existing)
        #expect(fresh.map(\.row) == [1, 2])
    }

    @Test("Identical rows are counted: two coffees held, three in the file, one is new")
    func counted() {
        let coffee = row(1, "COFFEE", -450)
        let fresh = SourceMerge.newRows([(0, coffee), (1, coffee), (2, coffee)],
                                        existing: [coffee.mergeKey, coffee.mergeKey])
        #expect(fresh.count == 1)
        #expect(fresh.first?.row == 2)
    }

    @Test("Case and spacing in the description don't make a row new")
    func spacing() {
        #expect(row(1, "Coffee  Shop", -450).mergeKey == row(1, "COFFEE SHOP ", -450).mergeKey)
        #expect(row(1, "COFFEE", -450).mergeKey != row(1, "COFFEE", -451).mergeKey)
    }

    @Test("Importing the same file twice adds nothing the second time")
    func idempotent() {
        let rows = [row(1, "A", -1), row(1, "A", -1), row(2, "B", 5)]
        let items = Array(zip(0..., rows)).map { ($0.0, $0.1) }
        let first = SourceMerge.newRows(items, existing: [])
        #expect(first.count == 3)
        #expect(SourceMerge.newRows(items, existing: first.map(\.parsed.mergeKey)).isEmpty)
    }

    @Test("A held row the file covers but doesn't list is gone; rows outside its days aren't judged")
    func gone() {
        let held = [row(1, "OLD", -100), row(3, "PENDING DINER", -2000), row(4, "GROCER", -500), row(9, "LATER", -1)]
            .map { ($0.mergeKey, $0.day) }
        let incoming = [row(2, "GAS", -3000), row(4, "GROCER", -500), row(5, "DINER", -2400)]
        #expect(SourceMerge.goneRows(held, incoming: incoming) == [1])
    }

    @Test("Gone rows are counted: two coffees held and one listed, the later one is gone")
    func goneCounted() {
        let coffee = row(2, "COFFEE", -450)
        let held = [coffee, coffee].map { ($0.mergeKey, $0.day) }
        #expect(SourceMerge.goneRows(held, incoming: [coffee]) == [1])
        #expect(SourceMerge.goneRows(held, incoming: [coffee, coffee]).isEmpty)
        #expect(SourceMerge.goneRows(held, incoming: []).isEmpty)
    }
}
