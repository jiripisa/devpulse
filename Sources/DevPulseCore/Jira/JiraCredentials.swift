import Foundation

public struct JiraCredentials: Sendable, Equatable {
    /// Keychain service of the API token; the account is the Jira e-mail.
    public static let keychainService = "io.jp4.devpulse.jira"

    public var site: URL
    public var email: String
    public var token: String

    public init(site: URL, email: String, token: String) {
        self.site = site
        self.email = email
        self.token = token
    }

    /// Site and e-mail from the settings, the token from `token(email)`; nil when any is missing.
    public static func resolve(settings: AppSettings, token: (String) -> String?) -> JiraCredentials? {
        guard let site = settings.jiraSite, let email = settings.jiraEmail, !email.isEmpty,
              let token = token(email), !token.isEmpty
        else { return nil }
        return JiraCredentials(site: site, email: email, token: token)
    }

    /// The site as typed in Settings, reduced to scheme, host and port: `acme.atlassian.net`
    /// and a pasted `https://acme.atlassian.net/jira/your-work` both become
    /// `https://acme.atlassian.net`. An `http://` site becomes `https://`, so the API token never
    /// goes out in clear text. Nil when there is no usable host.
    public static func site(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let parsed = URLComponents(string: withScheme),
              let scheme = parsed.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parsed.host, !host.isEmpty
        else { return nil }
        var site = URLComponents()
        site.scheme = "https"
        site.host = host
        site.port = parsed.port
        return site.url
    }

    /// Saves the token entered in Settings under `email`. An empty `token` keeps the stored
    /// one; when the e-mail changed, the stored token moves to the new account.
    public static func storeToken(_ token: String, email: String, previousEmail: String?, in store: SecretStore) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let moved = previousEmail.flatMap { $0 != email ? $0 : nil }
        if !token.isEmpty {
            try store.write(token, email)
        } else if let moved, let old = store.read(moved) {
            try store.write(old, email)
        }
        if let moved { store.delete(moved) }
    }
}

/// Read, write and delete of one Keychain service, by account; replaceable in tests.
public struct SecretStore {
    public var read: (String) -> String?
    public var write: (String, String) throws -> Void
    public var delete: (String) -> Void

    /// `write` takes the value first, then the account.
    public init(
        read: @escaping (String) -> String?, write: @escaping (String, String) throws -> Void,
        delete: @escaping (String) -> Void
    ) {
        self.read = read
        self.write = write
        self.delete = delete
    }

    public static func keychain(service: String) -> SecretStore {
        SecretStore(
            read: { Keychain.read(service: service, account: $0) },
            write: { try Keychain.write($0, service: service, account: $1) },
            delete: { Keychain.delete(service: service, account: $0) })
    }
}
