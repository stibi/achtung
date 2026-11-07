import AchtungDomain
import Testing

@Test(
    arguments: [
        ("critical", Severity.critical),
        (" Warning ", .warning),
        ("INFO", .info),
        ("page", .unknown),
        (nil, .unknown),
    ] as [(String?, Severity)])
func severityParsing(input: String?, expected: Severity) {
    #expect(Severity(parsing: input) == expected)
}
