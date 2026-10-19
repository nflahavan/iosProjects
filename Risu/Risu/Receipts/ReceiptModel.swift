import Foundation
import FoundationModels

/// The on-device model, for receipts the rules can't read: items over
/// several lines, prices printed apart from their names, a store's web page.
/// It only proposes; the same adds-up check decides.
nonisolated enum ReceiptModel {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Why it can't run, for the log.
    static var unavailableReason: String {
        switch SystemLanguageModel.default.availability {
        case .available: "available"
        case .unavailable(.deviceNotEligible): "device"
        case .unavailable(.appleIntelligenceNotEnabled): "not-enabled"
        case .unavailable(.modelNotReady): "not-ready"
        case .unavailable: "other"
        }
    }

    @Generable
    struct Reading {
        @Guide(description: "Every item bought, once each, in the order listed")
        var items: [Line]
        @Guide(description: "The subtotal before tax, like 51.25, or empty if none is printed")
        var subtotal: String
        @Guide(description: "The sales tax, like 2.83, or empty if none is printed")
        var tax: String
        @Guide(description: "The total charged, like 54.07")
        var total: String
    }

    @Generable
    struct Line {
        @Guide(description: "The item's name as printed, on one line")
        var name: String
        @Guide(description: "What was paid for this item, quantity included, like 4.49")
        var price: String
    }

    /// Asks the model for the receipt's items and totals. Amounts it leaves
    /// out or garbles come from the rules' reading where they have one.
    /// Greedy is its single most likely answer, the same every time; without
    /// it, a second try can come out differently.
    static func read(_ lines: [String], fallback rules: ReceiptReading, greedy: Bool = true) async throws -> ReceiptReading {
        let session = LanguageModelSession(instructions: """
            You read the text of a shopping receipt or an online order page and list what was bought. \
            Each purchased item appears once, with the price paid for it. If an item's only price is a \
            unit price or a "return value", multiply it by the quantity. Leave out savings, rewards, \
            coupons already taken off, payments, card details, totals and anything that isn't an item.
            """)
        let options = GenerationOptions(samplingMode: greedy ? .greedy : nil)
        let reading = try await session.respond(to: lines.joined(separator: "\n"), generating: Reading.self, options: options).content
        func cents(_ text: String) -> Int? { Money.cents(from: text).map(abs) }
        return ReceiptReading(
            items: reading.items.compactMap { line in
                cents(line.price).map { ReceiptReading.Item(name: line.name, cents: $0, taxed: nil) }
            },
            subtotal: rules.subtotal ?? cents(reading.subtotal),
            tax: rules.tax > 0 ? rules.tax : (cents(reading.tax) ?? 0),
            total: rules.total ?? cents(reading.total))
    }
}
