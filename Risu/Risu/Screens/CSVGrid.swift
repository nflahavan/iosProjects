import SwiftUI

/// The file itself, as a table: its real header and first rows.
///
/// Until this existed, everything between exporting from the bank and mapping
/// columns was a file name; there was no way to see what a column held before
/// choosing it. Columns in use are tinted and labelled with their role. When
/// `assign` is given, tapping a header offers the roles it could take.
struct CSVGrid: View {
    let table: CSVTable
    var roles: [Int: String] = [:]
    var choices: [String] = []
    var assign: ((Int, String) -> Void)?
    var rows = 30

    private let width: CGFloat = 132

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { header($0) }
                }
                ForEach(Array(table.rows.prefix(rows).enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .font(.caption.monospacedDigit())
                                .lineLimit(1)
                                .frame(width: width, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                                .background(tint(column, odd: index.isMultiple(of: 2)))
                        }
                    }
                }
            }
        }
        .scrollIndicators(.visible)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func header(_ column: Int) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(roles[column] ?? (assign == nil ? " " : "Not used"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(roles[column] == nil ? Color.secondary : Color.accentColor)
            HStack(spacing: 3) {
                Text(table.header[column].isEmpty ? "Column \(column + 1)" : table.header[column])
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if assign != nil {
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(roles[column] == nil ? Color(.secondarySystemBackground) : Color.accentColor.opacity(0.22))

        if let assign {
            Menu {
                ForEach(choices, id: \.self) { role in
                    Button(role) { assign(column, role) }
                }
            } label: { label }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private func tint(_ column: Int, odd: Bool) -> Color {
        if roles[column] != nil { return Color.accentColor.opacity(odd ? 0.10 : 0.06) }
        return odd ? Color(.secondarySystemBackground).opacity(0.5) : .clear
    }
}
