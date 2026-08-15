import Foundation

public struct PullRequestRepositoryMatch: Equatable, Sendable {
    public let repository: String
    public let displayName: String

    public init(repository: String, displayName: String) {
        self.repository = repository
        self.displayName = displayName
    }
}

public struct PullRequestRepositorySearchNavigation: Equatable, Sendable {
    public private(set) var highlightedIndex: Int?
    private var matchCount: Int

    public init(matchCount: Int) {
        self.matchCount = max(0, matchCount)
        highlightedIndex = self.matchCount > 0 ? 0 : nil
    }

    public mutating func update(matchCount: Int) {
        self.matchCount = max(0, matchCount)
        guard self.matchCount > 0 else {
            highlightedIndex = nil
            return
        }

        let currentIndex = highlightedIndex ?? 0
        highlightedIndex = min(currentIndex, self.matchCount - 1)
    }

    public mutating func moveDown() {
        move(offset: 1)
    }

    public mutating func moveUp() {
        move(offset: -1)
    }

    private mutating func move(offset: Int) {
        guard matchCount > 0 else {
            highlightedIndex = nil
            return
        }

        let currentIndex = highlightedIndex ?? 0
        highlightedIndex = (currentIndex + offset + matchCount) % matchCount
    }
}

public struct PullRequestMenuBarNotification: Equatable, Sendable {
    public let label: String?
    public let showsDot: Bool

    public init(label: String?, showsDot: Bool) {
        self.label = label
        self.showsDot = showsDot
    }

    public init(count: Int) {
        if count <= 0 {
            label = nil
            showsDot = false
        } else {
            label = nil
            showsDot = true
        }
    }
}

public struct PullRequestRepositorySelection: Equatable, Sendable {
    public private(set) var pullRequests: [PullRequest]
    public private(set) var selectedRepository: String?
    private var repositoryCatalog: [String]?

    public init(
        pullRequests: [PullRequest] = [],
        selectedRepository: String? = nil,
        repositories: [String]? = nil
    ) {
        self.pullRequests = pullRequests
        self.selectedRepository = selectedRepository
        repositoryCatalog = repositories
        normalizeSelection()
    }

    public var repositories: [String] {
        if let repositoryCatalog {
            return Array(Set(repositoryCatalog)).sorted()
        }

        return Array(Set(pullRequests.map(\.repository))).sorted()
    }

    public var visiblePullRequests: [PullRequest] {
        guard let selectedRepository else { return [] }
        return pullRequests.filter { $0.repository == selectedRepository }
    }

    public func visiblePullRequestsRequiringReview(from login: String?) -> [PullRequest] {
        visiblePullRequests.filter { $0.needsReview(from: login) }
    }

    public func hasVisiblePullRequestsRequiringReview(from login: String?) -> Bool {
        visiblePullRequests.contains { $0.needsReview(from: login) }
    }

    public var hasMultipleRepositories: Bool {
        repositories.count > 1
    }

    public var selectedRepositoryName: String? {
        selectedRepository.map { displayName(for: $0) }
    }

    public func repositories(matching query: String) -> [String] {
        repositoryMatches(matching: query).map(\.repository)
    }

    public func repositoryMatches(matching query: String) -> [PullRequestRepositoryMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = repositories.map {
            PullRequestRepositoryMatch(repository: $0, displayName: displayName(for: $0))
        }
        guard !trimmedQuery.isEmpty else { return matches }

        return matches.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmedQuery) ||
                $0.repository.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    public mutating func update(pullRequests: [PullRequest]) {
        self.pullRequests = pullRequests
        normalizeSelection()
    }

    public mutating func update(repositories: [String]) {
        repositoryCatalog = repositories
        normalizeSelection()
    }

    @discardableResult
    public mutating func selectRepository(_ repository: String) -> Bool {
        guard repositories.contains(repository) else { return false }
        selectedRepository = repository
        return true
    }

    public mutating func selectNextRepository() {
        selectRepository(offset: 1)
    }

    public mutating func selectPreviousRepository() {
        selectRepository(offset: -1)
    }

    private mutating func selectRepository(offset: Int) {
        let repositories = repositories
        guard !repositories.isEmpty else {
            selectedRepository = nil
            return
        }

        guard let selectedRepository,
              let currentIndex = repositories.firstIndex(of: selectedRepository)
        else {
            self.selectedRepository = repositories[0]
            return
        }

        let nextIndex = (currentIndex + offset + repositories.count) % repositories.count
        self.selectedRepository = repositories[nextIndex]
    }

    private mutating func normalizeSelection() {
        let repositories = repositories
        guard !repositories.isEmpty else {
            selectedRepository = nil
            return
        }

        if let selectedRepository, repositories.contains(selectedRepository) {
            return
        }

        selectedRepository = repositories[0]
    }

    private func displayName(for repository: String) -> String {
        let repositoryName = Self.repositoryName(for: repository)
        let matchingShortNameCount = repositories.filter {
            Self.repositoryName(for: $0).caseInsensitiveCompare(repositoryName) == .orderedSame
        }.count

        return matchingShortNameCount > 1 ? repository : repositoryName
    }

    private static func repositoryName(for repository: String) -> String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
}
