import AchtungDomain
import Foundation
import Testing

@Test(arguments: [
    (AlertState.firing, true),
    (.resolved(endsAt: Date(timeIntervalSince1970: 1_800_000_000)), false),
])
func isFiring(state: AlertState, expected: Bool) {
    let alert = IncomingAlert(
        sourceKey: "a", severity: .critical, title: "a", summary: nil, labels: [:],
        annotations: [:], startsAt: Date(timeIntervalSince1970: 1_700_000_000), links: [],
        state: state)
    #expect(alert.isFiring == expected)
}
