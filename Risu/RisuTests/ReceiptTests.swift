import Testing
import UIKit
@testable import Risu

/// Invented receipts, laid out the way real ones are.
struct ReceiptTests {
    /// A department store's: headings, item codes, a tax column, a savings
    /// note under a marked-down item, and the payment after the total.
    let store = [
        "CORNER STORE", "Springfield", "10/16/2026 09:32 AM",
        "KITCHEN",
        "204110012  Bread Knife  T  $12.00",
        "204110013  Tea Towels  T  $6.00",
        "GROCERY",
        "330200001  Oat Milk  N  $4.50",
        "TOYS",
        "445500210  Kite  T  $8.00",
        "Regular Price $20.00",
        "SUBTOTAL  $30.50",
        "T = ST TAX 5.5000 on $26.00  $1.43",
        "TOTAL  $31.93",
        "*1234 CARD CHARGE  $31.93",
        "AUTH CODE 123456",
    ]

    @Test func readsItemsTaxAndTotal() {
        let reading = ReceiptReading(lines: store)
        #expect(reading.items.map(\.name) == ["Bread Knife", "Tea Towels", "Oat Milk", "Kite"])
        #expect(reading.items.map(\.cents) == [1200, 600, 450, 800])
        #expect(reading.items.map(\.taxed) == [true, true, false, true])
        #expect(reading.subtotal == 3050)
        #expect(reading.tax == 143)
        #expect(reading.total == 3193)
    }

    @Test func taxGoesOnTaxedItemsToTheCent() throws {
        let parts = try ReceiptReading(lines: store).parts(matching: 3193).get()
        // 143 over 2600: 66.0, 33.0, 44.0 → 66 + 33 + 44 = 143.
        #expect(parts.map(\.cents) == [1266, 633, 450, 844])
        #expect(parts.map(\.cents).reduce(0, +) == 3193)
    }

    @Test func leftoverCentsGoWhereRoundingLostMost() {
        // 100 over three equal items: 33 each, and the first gets the cent.
        #expect(ReceiptReading.spread(100, by: [1, 1, 1]) == [34, 33, 33])
        // 561 over 2400, 4499, 699, 2600 (a real-looking basket).
        let shares = ReceiptReading.spread(561, by: [2400, 4499, 699, 2600])
        #expect(shares.reduce(0, +) == 561)
        #expect(shares == [132, 248, 38, 143])
        #expect(ReceiptReading.spread(5, by: [0, 0]) == [0, 0])
    }

    @Test func aMarkThatDidntReadStillTakesTax() throws {
        var lines = store
        lines[9] = "445500210  Kite  $8.00"
        let parts = try ReceiptReading(lines: lines).parts(matching: 3193).get()
        #expect(parts.map(\.cents) == [1266, 633, 450, 844])
    }

    @Test func unmarkedReceiptsTaxEverything() throws {
        let lines = ["Soap  $3.00", "Sponge  $1.00", "Tax  $0.40", "Total  $4.40"]
        let parts = try ReceiptReading(lines: lines).parts(matching: 440).get()
        #expect(parts.map(\.cents) == [330, 110])
    }

    @Test func refusesWhatDoesntAddUp() {
        // A line misread: the items no longer match the subtotal.
        var lines = store
        lines[4] = "204110012  Bread Knife  T  $17.00"
        #expect(ReceiptReading(lines: lines).parts(matching: 3193).problem == (.itemsDontAddUp(items: 3550, subtotal: 3050)))
        #expect(ReceiptReading(lines: store).parts(matching: 5000).problem == (.otherAmount(receipt: 3193, bank: 5000)))
        #expect(ReceiptReading(lines: ["Thanks for shopping"]).parts(matching: 100).problem == (.noItems))
        #expect(ReceiptReading(lines: ["Soap  $3.00"]).parts(matching: 300).problem == (.noTotal))
    }

    @Test func couponsComeOffTheirItem() {
        let reading = ReceiptReading(lines: ["Coffee  $9.00", "Coupon  -$2.00", "Total  $7.00"])
        #expect(reading.items == [.init(name: "Coffee", cents: 700, taxed: nil)])
    }

    @Test func fragmentsOnOneRowJoin() {
        let lines = ReceiptReader.lines([
            .init(text: "$12.00", minX: 0.8, midY: 0.700, height: 0.02),
            .init(text: "Bread Knife", minX: 0.1, midY: 0.705, height: 0.02),
            .init(text: "TOTAL", minX: 0.1, midY: 0.60, height: 0.02),
            .init(text: "$12.00", minX: 0.8, midY: 0.598, height: 0.02),
        ])
        #expect(lines == ["Bread Knife  $12.00", "TOTAL  $12.00"])
    }

    @Test func longReceiptsAreReadInOverlappingTiles() {
        #expect(ReceiptReader.tiles(width: 600, height: 700).map(\.keeps) == [0..<700])
        let tiles = ReceiptReader.tiles(width: 600, height: 2000)
        #expect(tiles.map(\.rect.minY) == [0, 450, 900, 1350, 1800])
        // Every row belongs to exactly one tile.
        #expect(tiles.map(\.keeps) == [0..<525, 525..<975, 975..<1425, 1425..<1875, 1875..<2000])
    }

    /// The whole path, Vision included: draw a long receipt, read it back.
    @Test func readsADrawnReceipt() async throws {
        let notes = (1...20).map { ("Thank you for shopping, visit \($0)", "") }
        let rows: [(String, String)] = notes + [
            ("CORNER STORE", ""), ("Bread Knife  T", "$12.00"), ("Tea Towels  T", "$6.00"),
            ("Oat Milk  N", "$4.50"), ("SUBTOTAL", "$22.50"), ("TAX", "$0.99"), ("TOTAL", "$23.49"),
        ]
        let size = CGSize(width: 600, height: 60 + rows.count * 50)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let font = UIFont.monospacedSystemFont(ofSize: 26, weight: .regular)
            for (index, row) in rows.enumerated() {
                let y = 30 + CGFloat(index) * 50
                (row.0 as NSString).draw(at: CGPoint(x: 30, y: y), withAttributes: [.font: font])
                let width = (row.1 as NSString).size(withAttributes: [.font: font]).width
                (row.1 as NSString).draw(at: CGPoint(x: size.width - 30 - width, y: y), withAttributes: [.font: font])
            }
        }
        let reading = try await ReceiptReader.read(ReceiptFile(data: image.pngData()!, isPDF: false))
        #expect(reading.items.map(\.cents) == [1200, 600, 450])
        #expect(reading.total == 2349)
        let parts = try reading.parts(matching: 2349).get()
        #expect(parts.map(\.cents).reduce(0, +) == 2349)
    }
}

private extension Result {
    var problem: Failure? {
        if case .failure(let why) = self { return why }
        return nil
    }
}
