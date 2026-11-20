import Foundation

/// The download of an update as Sparkle's user driver reports it: an expected length (0 when
/// unknown, possibly wrong, possibly announced again) and chunks of received bytes. Progress is
/// reported only when it reaches a new whole percent, so a download in many small chunks does
/// not flood the socket.
public struct DownloadProgress: Sendable, Equatable {
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var reportedPercent: Int?

    public init() {}

    /// A newly announced length replaces the previous one. Returns the fraction (0...1) to
    /// report, or `nil` when the length is unknown or the whole percent has not changed.
    public mutating func expect(_ length: UInt64) -> Double? {
        expected = length
        return report()
    }

    /// Adds a received chunk; returns what `expect` returns.
    public mutating func receive(_ length: UInt64) -> Double? {
        received += length
        return report()
    }

    private mutating func report() -> Double? {
        guard expected > 0 else { return nil }
        let done = min(received, expected)
        let percent = Int(done * 100 / expected)
        guard percent != reportedPercent else { return nil }
        reportedPercent = percent
        return Double(done) / Double(expected)
    }
}
