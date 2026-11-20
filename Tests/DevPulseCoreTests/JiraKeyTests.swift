import Testing
@testable import DevPulseCore

@Suite("JiraKey")
struct JiraKeyTests {

    @Test("Finds the first key in text", arguments: [
        ("STORE-2474 Replace invoice", "STORE-2474"),
        ("feature/STORE-2290-prehled", "STORE-2290"),
        ("[STORE-12] fix", "STORE-12"),
        ("feat_STORE-12", "STORE-12"),
    ])
    func findsKey(input: String, expected: String) {
        #expect(JiraKey.find(in: input) == expected)
    }

    @Test("Finds nothing without a valid key", arguments: [
        "store-2290-x",  // case-sensitive
        "no key",
        "A-1",  // the project key needs at least 2 characters
        "XSTORE-12a",  // glued to other letters or digits on either side
        "aSTORE-12",
        "STORE-12b",
    ])
    func findsNothing(input: String) {
        #expect(JiraKey.find(in: input) == nil)
    }

    @Test("Skips standard names that look like keys", arguments: [
        ("Fix UTF-8 export (STORE-2474)", "STORE-2474"),
        ("SHA-256 checksums for STORE-1", "STORE-1"),
        ("ISO-8601 dates", nil),
        ("RFC-3339 and HTTP-2", nil),
    ])
    func skipsDenylisted(input: String, expected: String?) {
        #expect(JiraKey.find(in: input) == expected)
    }

    @Test("Prefers a key of a known project when there are several")
    func prefersKnownProjects() {
        let title = "Bump AB-12 for STORE-7"
        #expect(JiraKey.find(in: title) == "AB-12")
        #expect(JiraKey.find(in: title, knownProjects: ["STORE"]) == "STORE-7")
        // Unknown projects only: the first candidate still wins.
        #expect(JiraKey.find(in: title, knownProjects: ["OTHER"]) == "AB-12")
        // A known project may even be on the denylist.
        #expect(JiraKey.find(in: "ISO-5 for UTF-8", knownProjects: ["ISO"]) == "ISO-5")
    }
}
