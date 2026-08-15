import Foundation

public struct PullRequest: Equatable, Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public var repositoryName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
    public var rowByline: String {
        "by \(author)"
    }
    public var hasReviewMetadata: Bool {
        reviewSummary != nil
    }

    public let title: String
    public let url: URL
    public let repository: String
    public let author: String
    public let updatedAt: Date
    public let isDraft: Bool
    public let latestCommitCommittedAt: Date?
    public let reviewSummary: PullRequestReviewSummary?

    public init(
        title: String,
        url: URL,
        repository: String,
        author: String,
        updatedAt: Date,
        isDraft: Bool,
        latestCommitCommittedAt: Date? = nil,
        reviewSummary: PullRequestReviewSummary? = nil
    ) {
        self.title = title
        self.url = url
        self.repository = repository
        self.author = author
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.latestCommitCommittedAt = latestCommitCommittedAt
        self.reviewSummary = reviewSummary
    }

    public func needsReview(from login: String?) -> Bool {
        guard let normalizedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedLogin.isEmpty
        else {
            return true
        }

        guard author.lowercased() != normalizedLogin else {
            return false
        }

        guard let reviewSummary else {
            return true
        }

        if reviewSummary.isReviewRequested(for: normalizedLogin) {
            return true
        }

        // Approval is the user's completion signal; later PR activity belongs
        // to the author and other reviewers.
        if reviewSummary.hasApproved(for: normalizedLogin) {
            return false
        }

        guard let lastReviewSubmittedAt = reviewSummary.latestReviewSubmittedAt(for: normalizedLogin) else {
            return true
        }

        guard let latestCommitCommittedAt else {
            return false
        }

        return latestCommitCommittedAt > lastReviewSubmittedAt
    }
}

public struct PullRequestReviewSummary: Equatable, Sendable {
    public let approvalCount: Int
    public let hasChangesRequested: Bool
    public let requestedReviewerLogins: [String]
    public let approvedReviewerLogins: [String]
    public let ciState: PullRequestCIState
    public let reviewSubmittedAtByAuthor: [String: Date]

    public init(
        approvalCount: Int,
        hasChangesRequested: Bool,
        requestedReviewerLogins: [String],
        ciState: PullRequestCIState,
        reviewSubmittedAtByAuthor: [String: Date] = [:],
        approvedReviewerLogins: [String] = []
    ) {
        self.approvalCount = approvalCount
        self.hasChangesRequested = hasChangesRequested
        self.requestedReviewerLogins = requestedReviewerLogins
        self.approvedReviewerLogins = approvedReviewerLogins.map { $0.lowercased() }
        self.ciState = ciState
        self.reviewSubmittedAtByAuthor = Dictionary(
            uniqueKeysWithValues: reviewSubmittedAtByAuthor.map { key, value in
                (key.lowercased(), value)
            }
        )
    }

    public func isReviewRequested(for login: String?) -> Bool {
        guard let login = login?.lowercased(), !login.isEmpty else { return false }
        return requestedReviewerLogins.contains { $0.lowercased() == login }
    }

    public func hasApproved(for login: String?) -> Bool {
        guard let login = login?.lowercased(), !login.isEmpty else { return false }
        return approvedReviewerLogins.contains(login)
    }

    public func latestReviewSubmittedAt(for login: String?) -> Date? {
        guard let login = login?.lowercased(), !login.isEmpty else { return nil }
        return reviewSubmittedAtByAuthor[login]
    }
}

public enum PullRequestCIState: Equatable, Sendable {
    case none
    case pending
    case passing
    case failing
}

struct GitHubPullRequestDTO: Decodable {
    let title: String
    let url: URL
    let repository: Repository?
    let author: Author
    let updatedAt: Date
    let isDraft: Bool
    let reviewDecision: String?
    let reviewRequests: [ReviewRequest]?
    let latestReviews: [Review]?
    let statusCheckRollup: [StatusCheck]?
    let commits: [Commit]?

    struct Repository: Decodable {
        let nameWithOwner: String
    }

    struct Author: Decodable {
        let login: String
    }

    struct ReviewRequest: Decodable {
        let login: String?
    }

    struct Review: Decodable {
        let author: Author?
        let state: String
        let submittedAt: Date?
    }

    struct StatusCheck: Decodable {
        let status: String?
        let conclusion: String?
        let state: String?
    }

    struct Commit: Decodable {
        let committedDate: Date?
    }

    func model(repositoryOverride: String? = nil) -> PullRequest {
        PullRequest(
            title: title,
            url: url,
            repository: repositoryOverride ?? repository?.nameWithOwner ?? "",
            author: author.login,
            updatedAt: updatedAt,
            isDraft: isDraft,
            latestCommitCommittedAt: latestCommitCommittedAt,
            reviewSummary: reviewSummary
        )
    }

    var isDependabotAuthored: Bool {
        let normalizedLogin = author.login.lowercased()
        return normalizedLogin == "app/dependabot" || normalizedLogin == "dependabot[bot]"
    }

    private var latestCommitCommittedAt: Date? {
        commits?.compactMap(\.committedDate).max()
    }

    private var reviewSummary: PullRequestReviewSummary? {
        guard reviewDecision != nil ||
              reviewRequests != nil ||
              latestReviews != nil ||
              statusCheckRollup != nil ||
              commits != nil
        else {
            return nil
        }

        let reviews = latestReviews ?? []
        let approvedReviewerLogins = Set(reviews.compactMap { review in
            review.state.uppercased() == "APPROVED" ? review.author?.login : nil
        })
        let hasChangesRequested = reviewDecision?.uppercased() == "CHANGES_REQUESTED" ||
            reviews.contains { $0.state.uppercased() == "CHANGES_REQUESTED" }

        return PullRequestReviewSummary(
            approvalCount: approvedReviewerLogins.count,
            hasChangesRequested: hasChangesRequested,
            requestedReviewerLogins: reviewRequests?.compactMap(\.login) ?? [],
            ciState: Self.ciState(from: statusCheckRollup),
            reviewSubmittedAtByAuthor: Self.reviewSubmittedAtByAuthor(from: reviews),
            approvedReviewerLogins: Array(approvedReviewerLogins)
        )
    }

    private static func reviewSubmittedAtByAuthor(from reviews: [Review]) -> [String: Date] {
        reviews.reduce(into: [String: Date]()) { latestReviewsByAuthor, review in
            guard let login = review.author?.login.lowercased(),
                  let submittedAt = review.submittedAt
            else {
                return
            }

            if let existingSubmittedAt = latestReviewsByAuthor[login],
               existingSubmittedAt >= submittedAt {
                return
            }

            latestReviewsByAuthor[login] = submittedAt
        }
    }

    private static func ciState(from checks: [StatusCheck]?) -> PullRequestCIState {
        guard let checks, !checks.isEmpty else {
            return .none
        }

        var hasPendingCheck = false

        for check in checks {
            let state = check.state?.uppercased()
            let status = check.status?.uppercased()
            let conclusion = check.conclusion?.uppercased()

            if let state, !state.isEmpty {
                switch state {
                case "SUCCESS":
                    continue
                case "FAILURE", "ERROR":
                    return .failing
                case "PENDING", "EXPECTED":
                    hasPendingCheck = true
                    continue
                default:
                    hasPendingCheck = true
                    continue
                }
            }

            guard status == "COMPLETED" else {
                hasPendingCheck = true
                continue
            }

            switch conclusion {
            case "SUCCESS", "SKIPPED", "NEUTRAL":
                continue
            case nil, "":
                hasPendingCheck = true
            default:
                return .failing
            }
        }

        return hasPendingCheck ? .pending : .passing
    }
}
