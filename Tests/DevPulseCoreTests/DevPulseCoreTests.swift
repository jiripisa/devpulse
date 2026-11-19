import Testing
@testable import DevPulseCore

@Suite("DevPulseCore")
struct DevPulseCoreTests {

    @Test("Greeting names the app")
    func greetingNamesTheApp() {
        #expect(DevPulseCore.greeting(appName: "DevPulse") == "Welcome to DevPulse")
    }
}
