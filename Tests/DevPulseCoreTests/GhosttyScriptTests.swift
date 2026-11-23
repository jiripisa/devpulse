import Testing
@testable import DevPulseCore

@Suite struct GhosttyScriptTests {
    @Test func selectsTheWindowAndTabBeforeFocusingTheTerminal() throws {
        let script = GhosttyScript.focus(terminalID: "T-1")
        let activateWindow = try #require(script.range(of: "activate window w"))
        let selectTab = try #require(script.range(of: "select tab t"))
        let focus = try #require(script.range(of: #"focus (first terminal of t whose id is "T-1")"#))
        #expect(activateWindow.lowerBound < selectTab.lowerBound)
        #expect(selectTab.lowerBound < focus.lowerBound)
        #expect(script.contains(#"tell application id "com.mitchellh.ghostty""#))
        #expect(script.contains("with timeout of 5 seconds"))
    }

    @Test func theFallbackOnlyFocusesTheTerminal() {
        let script = GhosttyScript.focusTerminalOnly(terminalID: "T-1")
        #expect(script.contains(#"focus (first terminal whose id is "T-1")"#))
        #expect(!script.contains("select tab"))
    }

    @Test func escapesTheTerminalID() {
        let script = GhosttyScript.focus(terminalID: #"a"b\c"#)
        #expect(script.contains(#"whose id is "a\"b\\c""#))
        #expect(!script.contains(#"is "a"b"#))
    }
}
