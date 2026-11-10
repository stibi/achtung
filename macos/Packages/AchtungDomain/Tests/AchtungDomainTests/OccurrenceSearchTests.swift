import AchtungDomain
import Foundation
import Testing

@Test(arguments: [
    ("namespace=payments", SearchToken.label(name: "namespace", value: "payments")),
    ("url=https://x.example/?a=b", .label(name: "url", value: "https://x.example/?a=b")),
    ("severity:critical", .severity(.critical)),
    ("Severity:Warning", .severity(.warning)),
    ("instance:cdx", .instance("cdx")),
])
func aWordIsATokenWhenItSaysWhatItFilters(word: String, token: SearchToken) {
    #expect(SearchToken(word: word) == token)
}

@Test(arguments: [
    "disk", "=payments", "namespace=", "9ns=x", "a-b=c", "severity:urgent", "instance:",
])
func otherWordsArePlainText(word: String) {
    #expect(SearchToken(word: word) == nil)
}

@Test func finishedWordsBecomeTokensAndTheWordBeingTypedStays() {
    let typing = SearchToken.extract(from: "namespace=payments disk sev")

    #expect(typing.tokens == [.label(name: "namespace", value: "payments")])
    #expect(typing.text == "disk sev")
    // The last word is a token too once a space follows it, or on Return.
    #expect(SearchToken.extract(from: "instance:cdx ").tokens == [.instance("cdx")])
    #expect(
        SearchToken.extract(from: "severity:critical", all: true).tokens == [.severity(.critical)])
    #expect(SearchToken.extract(from: "severity:critical").tokens.isEmpty)
}

@Test func textWithoutTokensStaysAsTyped() {
    #expect(SearchToken.extract(from: "disk full ").text == "disk full ")
}

@Test func aSearchSplitsItsTokensIntoTheServersParameters() {
    let search = OccurrenceSearch(
        text: "  disk ",
        tokens: [
            .label(name: "namespace", value: "payments"), .severity(.critical),
            .severity(.warning), .instance("cdx"), .instance("onprem"),
            .label(name: "job", value: "api"),
        ])

    #expect(search.text == "disk")
    #expect(search.labels == ["namespace=payments", "job=api"])
    #expect(search.severities == [.critical, .warning])
    #expect(search.instance == "onprem")
    #expect(!search.isEmpty)
    #expect(OccurrenceSearch(text: " ", tokens: []).isEmpty)
}

@Test func searchResultsShowReadAlertsToo() {
    var state = ReadState()
    let scope = OccurrenceScope.search(OccurrenceSearch(text: "disk", tokens: []))

    state.setHidesRead(true, in: scope)

    #expect(!state.hidesRead(in: scope))
    #expect(!scope.contains(Fixture.occurrence(id: 1, lastEventAt: Fixture.start)))
}

@Test func aSpaceAfterTheLastWordStays() {
    #expect(SearchToken.extract(from: "disk a=b ").text == "disk ")
    #expect(SearchToken.extract(from: "a=b ").text == "")
}

@Test func eachTokenIsAddedOnceAndANewInstanceReplacesTheOld() {
    let pasted = SearchToken.tokenize(
        text: "a=b a=b severity:critical Severity:Critical instance:cdx disk ",
        tokens: [.instance("onprem"), .label(name: "a", value: "b")])

    #expect(
        pasted.tokens == [
            .label(name: "a", value: "b"), .severity(.critical), .instance("cdx"),
        ])
    #expect(pasted.text == "disk ")
    #expect(SearchToken.tokenize(text: "disk", tokens: []).tokens.isEmpty)
}
