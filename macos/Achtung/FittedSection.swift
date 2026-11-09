import AchtungDomain
import SwiftUI

/// A titled card of rows that shows as many as fit `available`, measured from its own
/// title and rows as drawn (`ListFit`), and a "Show N more" line that reveals the rest,
/// after which the page may scroll. It never shows fewer than `ListFit.minimumRows`. It
/// collapses again when everything fits, e.g. once the window has grown, when it appears
/// anew, and when `collapseRequest` changes (the user reloading the page). Hidden rows
/// aren't drawn, so VoiceOver doesn't read them. Home's sections use it; any list that
/// should fit a screen can.
struct FittedSection<Item: Identifiable, Row: View>: View {
    private static var padding: CGFloat { 16 }
    private static var titleSpacing: CGFloat { 8 }
    private static var rowSpacing: CGFloat { 6 }

    let title: String
    let empty: String
    let items: [Item]
    let available: CGFloat
    /// Changes when the page asks its sections to collapse.
    let collapseRequest: Int
    @ViewBuilder let row: (Item) -> Row

    @State private var expanded = false
    @State private var titleHeight: CGFloat = 0
    /// The tallest row drawn so far; rows of one list are alike.
    @State private var rowHeight: CGFloat = 0
    @State private var moreHeight: CGFloat = 0
    @State private var emptyHeight: CGFloat = 0

    private var fit: ListFit {
        ListFit(
            chrome: Double(2 * Self.padding + titleHeight + Self.titleSpacing),
            rowHeight: Double(rowHeight), spacing: Double(Self.rowSpacing),
            // Until the line is drawn, a row's height stands in for it: a little more room.
            moreLine: Double(moreHeight > 0 ? moreHeight : rowHeight))
    }

    /// What fits; until a row has been measured, the minimum.
    private var fitting: Int {
        guard rowHeight > 0 else { return min(items.count, ListFit.minimumRows) }
        return fit.visibleRows(total: items.count, available: Double(available))
    }

    var body: some View {
        let fitting = fitting
        let hidden = items.count - fitting
        VStack(alignment: .leading, spacing: Self.titleSpacing) {
            Text(title)
                .font(.headline)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    titleHeight = $0
                }
            if items.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        emptyHeight = $0
                    }
            } else {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(items.prefix(expanded ? items.count : fitting)) { item in
                        row(item)
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.height
                            } action: {
                                rowHeight = max(rowHeight, $0)
                            }
                    }
                    if hidden > 0 {
                        moreButton(hidden: hidden)
                    }
                }
            }
        }
        .padding(Self.padding)
        .frame(minWidth: 260, idealWidth: 260, maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        // What it needs to show everything, for stacked sections to share the height.
        .preference(
            key: FittedSectionNeeds.self,
            value: [title: need]
        )
        .onChange(of: collapseRequest) { expanded = false }
        .onChange(of: hidden == 0) { _, fitsAll in
            if fitsAll {
                expanded = false
            }
        }
    }

    /// Its height with all its rows; until a row has been measured, as much as there is.
    private var need: CGFloat {
        if items.isEmpty {
            return CGFloat(fit.chrome) + emptyHeight
        }
        return rowHeight > 0 ? CGFloat(fit.height(rows: items.count)) : .infinity
    }

    private func moreButton(hidden: Int) -> some View {
        Button(expanded ? "Show less" : "Show \(hidden) more") {
            withAnimation(.snappy) { expanded.toggle() }
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.top, 2)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            moreHeight = $0
        }
        .accessibilityLabel(
            expanded ? "Show less of \(title)" : "Show \(hidden) more in \(title)")
    }
}

/// Each `FittedSection`'s height with all its rows, by title.
struct FittedSectionNeeds: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}
