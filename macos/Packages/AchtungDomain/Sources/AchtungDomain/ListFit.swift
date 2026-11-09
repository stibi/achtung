import Foundation

/// How much of a list fits a height, so a screen like Home can show what fits without a
/// scroll bar and offer the rest behind "Show more". Heights are in points, measured from
/// the list as it's drawn.
public struct ListFit: Sendable, Equatable {
    /// Rows shown even when they don't fit: a section cut to one or two rows says little.
    public static let minimumRows = 3

    /// Everything but the rows: the title and padding.
    public var chrome: Double
    public var rowHeight: Double
    /// The gap between rows, and between the last row and the "Show N more" line.
    public var spacing: Double
    /// The "Show N more" line, which needs room only when rows are left out.
    public var moreLine: Double

    public init(chrome: Double, rowHeight: Double, spacing: Double, moreLine: Double) {
        self.chrome = chrome
        self.rowHeight = rowHeight
        self.spacing = spacing
        self.moreLine = moreLine
    }

    /// How many of `total` rows fit `available`: never fewer than `minimum`, and all of
    /// them when that's all there is.
    public func visibleRows(total: Int, available: Double, minimum: Int = minimumRows) -> Int {
        guard total > 0 else { return 0 }
        if height(rows: total) <= available {
            return total
        }
        // n rows, then the "more" line: n rows, n gaps (the last before the line), the line.
        let room = available - chrome - moreLine
        let fitting = room > 0 ? Int((room / (rowHeight + spacing)).rounded(.down)) : 0
        let shown = max(fitting, minimum)
        // A button that would reveal nothing isn't worth showing.
        return shown >= total ? total : shown
    }

    /// The height of the list showing `rows` rows and no "more" line.
    public func height(rows: Int) -> Double {
        chrome + Double(rows) * rowHeight + Double(max(rows - 1, 0)) * spacing
    }

    /// Shares `available` among lists stacked one above the other, each needing `needs` to
    /// show all its rows. Each gets an equal share; one that needs less keeps only what it
    /// needs, and the rest goes to the others, so a short list doesn't hold space a long
    /// one could use. When everything fits, each gets what it needs.
    public static func share(_ available: Double, among needs: [Double]) -> [Double] {
        var shares = needs.map { _ in 0.0 }
        var open = Set(needs.indices)
        var left = max(available, 0)
        while !open.isEmpty {
            let equal = left / Double(open.count)
            let satisfied = open.filter { needs[$0] <= equal }
            guard !satisfied.isEmpty else {
                for index in open {
                    shares[index] = equal
                }
                break
            }
            for index in satisfied {
                shares[index] = needs[index]
                left -= needs[index]
                open.remove(index)
            }
        }
        return shares
    }
}
