import Foundation

/// Keeps a secret (the Jira API token) in memory after the first successful Keychain read, so a
/// refresh does not read the Keychain every time. A miss (no item, a locked Keychain) is not
/// kept: the next call reads again. `invalidate()` after a change.
@MainActor
public final class TokenCache {
    private let read: (String) -> String?
    private var cached: (account: String, token: String)?

    public init(read: @escaping (String) -> String?) {
        self.read = read
    }

    public func token(for account: String) -> String? {
        if let cached, cached.account == account { return cached.token }
        guard let token = read(account) else { return nil }
        cached = (account, token)
        return token
    }

    public func invalidate() {
        cached = nil
    }
}
