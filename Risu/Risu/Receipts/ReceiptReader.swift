import CoreGraphics
import Foundation
import PDFKit
import UIKit
import Vision

/// A receipt as it came in: a photo, a screenshot or a PDF.
nonisolated struct ReceiptFile: Equatable, Sendable {
    var data: Data
    var isPDF: Bool

    /// Its pages as images, for reading and for showing.
    func pages() -> [CGImage] {
        if !isPDF { return UIImage(data: data)?.uprightCGImage().map { [$0] } ?? [] }
        guard let document = PDFDocument(data: data) else { return [] }
        return (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            // Small print needs pixels: render at three times the page size.
            let size = CGSize(width: bounds.width * 3, height: bounds.height * 3)
            return page.thumbnail(of: size, for: .mediaBox).cgImage
        }
    }
}

/// Reading a receipt's text on the phone, with Vision. Nothing leaves it.
nonisolated enum ReceiptReader {
    /// How a receipt was made sense of, for the log.
    enum Method: String { case rules, model }

    /// The split for a receipt, by its own rules first: instant, and exact
    /// to test. When they can't make it add up (a store or web page laid out
    /// some other way), the on-device model reads the same text. Either way
    /// the result passes the same check before it reaches the split. The
    /// model gets a second try, since it sometimes skips a line.
    static func parts(for file: ReceiptFile, matching bankTotal: Int) async throws
        -> (result: Result<[(name: String, cents: Int)], ReceiptProblem>, method: Method, items: Int) {
        let lines = try await lines(of: file)
        let rules = ReceiptReading(lines: lines)
        var best = (result: rules.parts(matching: bankTotal), method: Method.rules, items: rules.items.count)
        guard case .failure = best.result, ReceiptModel.isAvailable else { return best }
        for greedy in [true, false] {
            guard let reading = try? await ReceiptModel.read(lines, fallback: rules, greedy: greedy) else { continue }
            best = (reading.parts(matching: bankTotal), .model, reading.items.count)
            if case .success = best.result { break }
        }
        return best
    }

    /// The receipt's text, a row at a time, top to bottom. A PDF that holds
    /// real text (most emailed or saved receipts) gives it exactly; anything
    /// else is read off the image.
    static func lines(of file: ReceiptFile) async throws -> [String] {
        if file.isPDF, let document = PDFDocument(data: file.data) {
            let lines = (0..<document.pageCount).compactMap(document.page(at:)).flatMap(textLines).map(unraisingCents)
            if lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { return lines }
        }
        let pages = file.pages()
        guard !pages.isEmpty else { throw ReceiptProblem.unreadable }
        var lines: [String] = []
        for page in pages {
            var fragments: [Fragment] = []
            for tile in tiles(width: page.width, height: page.height) {
                guard let image = page.cropping(to: tile.rect) else { continue }
                fragments += try await read(image).compactMap { fragment in
                    // Back into the page's coordinates, keeping only the rows
                    // in this tile's middle; the overlap belongs to the next.
                    let y = tile.rect.minY + (1 - fragment.midY) * tile.rect.height
                    guard tile.keeps.contains(y) else { return nil }
                    let scale = tile.rect.height / Double(page.height)
                    return Fragment(text: fragment.text,
                                    minX: fragment.minX * tile.rect.width / Double(page.width),
                                    midY: 1 - y / Double(page.height),
                                    height: fragment.height * scale)
                }
            }
            lines += self.lines(fragments)
        }
        return lines
    }

    /// Prices with raised cents ($4⁵⁰, common on stores' order pages) come
    /// out of a PDF as "$ 50  4": the dollar sign and cents on the raised
    /// line first, the dollars after. Put back as "$4.50".
    static func unraisingCents(_ line: String) -> String {
        line.replacing(#/\$ ?(\d{2})\s+(\d{1,5})(?![\d.])/#) { "$\($0.output.2).\($0.output.1)" }
    }

    /// A PDF page's own text, put back into rows the same way as Vision's.
    private static func textLines(_ page: PDFPage) -> [String] {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0,
              let selections = page.selection(for: box)?.selectionsByLine() else { return [] }
        return lines(selections.compactMap { selection in
            guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let rect = selection.bounds(for: page)
            return Fragment(text: text, minX: (rect.minX - box.minX) / box.width,
                            midY: (rect.midY - box.minY) / box.height, height: rect.height / box.height)
        })
    }

    /// A long receipt read whole is shrunk to Vision's input size until its
    /// small print is unreadable, so it's read in square tiles down the page.
    /// Neighbouring tiles overlap by a quarter, and each keeps the rows whose
    /// middles fall in its own stretch, so a row cut by one tile's edge is
    /// read whole by the next.
    static func tiles(width: Int, height: Int) -> [(rect: CGRect, keeps: Range<Double>)] {
        let side = Double(width), whole = Double(height)
        guard whole > side * 1.25 else { return [(CGRect(x: 0, y: 0, width: side, height: whole), 0..<whole)] }
        let step = side * 0.75
        var tiles: [(rect: CGRect, keeps: Range<Double>)] = []
        var top = 0.0
        while true {
            let bottom = min(top + side, whole)
            let last = bottom >= whole
            let start = top == 0 ? 0 : top + (side - step) / 2
            let end = last ? whole : top + side - (side - step) / 2
            tiles.append((CGRect(x: 0, y: top, width: side, height: bottom - top), start..<end))
            if last { return tiles }
            top += step
        }
    }

    private static func read(_ image: CGImage) async throws -> [Fragment] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Item names are abbreviations; "correcting" them makes them worse.
        request.usesLanguageCorrection = false
        return try await request.perform(on: image).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let ys = [observation.topLeft.y, observation.topRight.y, observation.bottomLeft.y, observation.bottomRight.y]
            return Fragment(text: text, minX: min(observation.topLeft.x, observation.bottomLeft.x),
                            midY: ys.reduce(0, +) / 4, height: ys.max()! - ys.min()!)
        }
    }

    /// One piece of recognised text and where it sat, in Vision's
    /// coordinates: 0 to 1, with y counting up from the bottom.
    struct Fragment {
        var text: String
        var minX: Double
        var midY: Double
        var height: Double
    }

    /// Puts fragments back into lines. Vision often reads an item's name and
    /// its price, far apart on the same row, as separate pieces; ones whose
    /// middles sit within half a line of each other are the same row.
    static func lines(_ fragments: [Fragment]) -> [String] {
        let heights = fragments.map(\.height).sorted()
        guard !heights.isEmpty else { return [] }
        let tolerance = heights[heights.count / 2] / 2
        var rows: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.midY > $1.midY }) {
            if let last = rows.last, let anchor = last.first, abs(anchor.midY - fragment.midY) <= tolerance {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { $0.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: "  ") }
    }
}

private extension UIImage {
    /// The pixels the way the photo is seen, so a sideways phone photo
    /// reads in rows rather than columns.
    nonisolated func uprightCGImage() -> CGImage? {
        guard imageOrientation != .up else { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale), format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))) }
            .cgImage
    }
}
