import Foundation

public struct PullRequestReadState: Codable, Equatable, Sendable {
    public private(set) var readAtByPullRequestID: [String: Date]

    public init(readAtByPullRequestID: [String: Date] = [:]) {
        self.readAtByPullRequestID = readAtByPullRequestID
    }

    public func isRead(_ pullRequest: PullRequest) -> Bool {
        guard let readAt = readAtByPullRequestID[pullRequest.id] else {
            return false
        }

        return readAt >= pullRequest.updatedAt
    }

    public mutating func markRead(_ pullRequest: PullRequest) {
        readAtByPullRequestID[pullRequest.id] = pullRequest.updatedAt
    }

    public mutating func markUnread(_ pullRequest: PullRequest) {
        readAtByPullRequestID[pullRequest.id] = nil
    }
}

public struct PullRequestReadStateMemory {
    public static let defaultKey = "GHMenuBar.pullRequestReadState.v1"

    private struct Snapshot: Codable {
        var statesByLogin: [String: PullRequestReadState]
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

    public func state(for login: String) -> PullRequestReadState {
        snapshot.statesByLogin[normalized(login)] ?? PullRequestReadState()
    }

    public func save(_ state: PullRequestReadState, for login: String) {
        var updatedSnapshot = snapshot
        updatedSnapshot.statesByLogin[normalized(login)] = state

        guard let data = try? JSONEncoder().encode(updatedSnapshot) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    private var snapshot: Snapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            return Snapshot(statesByLogin: [:])
        }

        return snapshot
    }

    private func normalized(_ login: String) -> String {
        login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
