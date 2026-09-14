import Foundation

public struct PullRequestCacheEntry: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let pullRequests: [PullRequest]

    public init(fetchedAt: Date, pullRequests: [PullRequest]) {
        self.fetchedAt = fetchedAt
        self.pullRequests = pullRequests
    }
}

public struct PullRequestCache {
    public static let defaultKey = "GHMenuBar.pullRequestCache.v1"

    private struct Snapshot: Codable {
        let login: String
        let entries: [String: PullRequestCacheEntry]
    }

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = Self.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public var savedLogin: String? {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        return snapshot.login
    }

    public func entries(for login: String) -> [String: PullRequestCacheEntry] {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.login.caseInsensitiveCompare(login) == .orderedSame
        else {
            return [:]
        }

        return snapshot.entries
    }

    public func save(entries: [String: PullRequestCacheEntry], for login: String) {
        let snapshot = Snapshot(login: login, entries: entries)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}
