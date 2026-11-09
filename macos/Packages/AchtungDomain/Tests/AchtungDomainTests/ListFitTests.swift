import AchtungDomain
import Testing

/// Rows 40 high with 6 between, under 50 of title and padding; the "more" line is 20.
private let fit = ListFit(chrome: 50, rowHeight: 40, spacing: 6, moreLine: 20)

private func visible(_ total: Int, in available: Double) -> Int {
    fit.visibleRows(total: total, available: available)
}

@Test func everythingShowsWhenItFits() {
    // 50 + 5 × 40 + 4 × 6 = 274.
    #expect(visible(5, in: 274) == 5)
    #expect(visible(5, in: 1000) == 5)
    #expect(visible(0, in: 10) == 0)
}

@Test func rowsThatDoNotFitMakeRoomForTheMoreLine() {
    // 273 leaves 273 − 50 − 20 = 203 for rows of 46: 4 of them.
    #expect(visible(5, in: 273) == 4)
    #expect(visible(56, in: 500) == 9)
}

@Test func atLeastThreeRowsShowOnASmallWindow() {
    #expect(visible(56, in: 100) == 3)
    #expect(visible(56, in: 0) == 3)
    #expect(visible(56, in: -40) == 3)
}

@Test func aListOfFewRowsShowsAllRatherThanHidingSome() {
    // Three is the minimum anyway: no button to reveal nothing.
    #expect(visible(3, in: 50) == 3)
    #expect(visible(2, in: 0) == 2)
}

@Test func theHeightOfAListIsItsChromeRowsAndGaps() {
    #expect(fit.height(rows: 3) == 182)
    #expect(fit.height(rows: 0) == 50)
}

@Test func stackedListsShareTheHeightEqually() {
    #expect(ListFit.share(600, among: [1000, 1000, 1000]) == [200, 200, 200])
}

@Test func aShortListKeepsOnlyWhatItNeedsAndTheRestGoesToTheOthers() {
    // 600 in three is 200 each; the first needs 100, so the others share 500.
    #expect(ListFit.share(600, among: [100, 1000, 1000]) == [100, 250, 250])
    // Then the second needs 240 of its 250, and the third gets the rest.
    #expect(ListFit.share(600, among: [100, 240, 1000]) == [100, 240, 260])
}

@Test func whenEverythingFitsEachListGetsWhatItNeeds() {
    #expect(ListFit.share(1000, among: [100, 200, 300]) == [100, 200, 300])
}

@Test func noRoomSharesNothing() {
    #expect(ListFit.share(-50, among: [100, 200]) == [0, 0])
    #expect(ListFit.share(100, among: []).isEmpty)
}

@Test func listsNotMeasuredYetShareWhatTheMeasuredOnesLeave() {
    // Before a list's rows are drawn, its need is unknown: as much as there is.
    #expect(ListFit.share(600, among: [100, .infinity, .infinity]) == [100, 250, 250])
    #expect(ListFit.share(600, among: [.infinity, .infinity, .infinity]) == [200, 200, 200])
}
