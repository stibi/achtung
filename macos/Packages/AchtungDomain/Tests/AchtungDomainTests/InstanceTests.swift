import AchtungDomain
import Testing

@Test func groupsChannelsByInstanceInTheServersOrder() {
    let instances = Instance.grouping([
        Fixture.channel("crm-prod", instance: "default", firing: 0, lastEventAt: nil),
        Fixture.channel("devops", instance: "default", firing: 2, lastEventAt: nil),
        Fixture.channel("devops", instance: "onprem", firing: 3, lastEventAt: nil),
    ])

    #expect(instances.map(\.name) == ["default", "onprem"])
    #expect(instances.map { $0.channels.map(\.id.slug) } == [["crm-prod", "devops"], ["devops"]])
    #expect(instances.map(\.firing) == [2, 3])
}

@Test func noChannelsMeansNoInstances() {
    #expect(Instance.grouping([]).isEmpty)
}
