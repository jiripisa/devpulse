import Testing
@testable import DevPulseCore

@Suite("DownloadProgress")
struct DownloadProgressTests {

    @Test("An unknown length reports nothing")
    func unknownLength() {
        var progress = DownloadProgress()
        #expect(progress.receive(4096) == nil)
        #expect(progress.expect(0) == nil)
        #expect(progress.receive(4096) == nil)
    }

    @Test("The expected length reports 0, then each new whole percent once")
    func wholePercentSteps() {
        var progress = DownloadProgress()
        #expect(progress.expect(1000) == 0)
        #expect(progress.receive(5) == nil)  // 0.5 %
        #expect(progress.receive(5) == 0.01)
        #expect(progress.receive(4) == nil)  // 1.4 %
        #expect(progress.receive(406) == 0.42)
    }

    @Test("Many small chunks report at most once per percent")
    func manyChunks() {
        var progress = DownloadProgress()
        _ = progress.expect(100_000)
        let reports = (0..<1000).compactMap { _ in progress.receive(100) }
        #expect(reports.count == 100)
        #expect(reports.last == 1)
    }

    @Test("More data than expected stays at 100 % and reports it once")
    func overDelivery() {
        var progress = DownloadProgress()
        _ = progress.expect(100)
        #expect(progress.receive(150) == 1)
        #expect(progress.receive(50) == nil)
    }

    @Test("A length announced again replaces the first one")
    func lengthAnnouncedAgain() {
        var progress = DownloadProgress()
        _ = progress.expect(1000)
        #expect(progress.receive(500) == 0.5)
        #expect(progress.expect(2000) == 0.25)
    }
}
