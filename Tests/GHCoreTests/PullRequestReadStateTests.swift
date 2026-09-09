import Foundation
import XCTest
@testable import GHCore

final class PullRequestReadStateTests: XCTestCase {
    func testMarkingPullRequestReadAcknowledgesCurrentActivity() {
        let pullRequest = samplePullRequest(updatedAt: Date(timeIntervalSince1970: 100))
        var state = PullRequestReadState()

        XCTAssertFalse(state.isRead(pullRequest))

        state.markRead(pullRequest)

        XCTAssertTrue(state.isRead(pullRequest))
    }

    func testNewPullRequestActivityMakesReadPullRequestUnreadAgain() {
        let pullRequest = samplePullRequest(updatedAt: Date(timeIntervalSince1970: 100))
        var state = PullRequestReadState()
        state.markRead(pullRequest)

        let updatedPullRequest = samplePullRequest(updatedAt: Date(timeIntervalSince1970: 101))

        XCTAssertFalse(state.isRead(updatedPullRequest))
    }

    func testMarkingPullRequestUnreadRemovesAcknowledgement() {
        let pullRequest = samplePullRequest(updatedAt: Date(timeIntervalSince1970: 100))
        var state = PullRequestReadState()
        state.markRead(pullRequest)

        state.markUnread(pullRequest)

        XCTAssertFalse(state.isRead(pullRequest))
    }

    func testReadStateMemoryPersistsStatePerGitHubAccount() throws {
        let suiteName = "GHMenuBarTests.PullRequestReadState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pullRequest = samplePullRequest(updatedAt: Date(timeIntervalSince1970: 100))
        let memory = PullRequestReadStateMemory(defaults: defaults)
        var state = PullRequestReadState()
        state.markRead(pullRequest)

        memory.save(state, for: "Dariana")

        XCTAssertTrue(memory.state(for: "dariana").isRead(pullRequest))
        XCTAssertFalse(memory.state(for: "someone-else").isRead(pullRequest))
    }

    func testRepositoryIndicatorIgnoresReadReviewWork() {
        let pullRequest = samplePullRequest(
            updatedAt: Date(timeIntervalSince1970: 100),
            requestedReviewerLogins: ["dariana"]
        )
        let selection = PullRequestRepositorySelection(pullRequests: [pullRequest])
        var state = PullRequestReadState()

        XCTAssertTrue(
            selection.hasUnreadPullRequestsRequiringReviewAcrossRepositories(
                from: "dariana",
                readState: state
            )
        )

        state.markRead(pullRequest)

        XCTAssertFalse(
            selection.hasUnreadPullRequestsRequiringReviewAcrossRepositories(
                from: "dariana",
                readState: state
            )
        )
        XCTAssertEqual(selection.visiblePullRequestsRequiringReview(from: "dariana"), [pullRequest])
    }

    private func samplePullRequest(
        updatedAt: Date,
        requestedReviewerLogins: [String] = []
    ) -> PullRequest {
        PullRequest(
            number: 42,
            title: "Review me",
            url: URL(string: "https://github.com/acme/widgets/pull/42")!,
            repository: "acme/widgets",
            author: "octocat",
            updatedAt: updatedAt,
            isDraft: false,
            reviewSummary: PullRequestReviewSummary(
                approvalCount: 0,
                hasChangesRequested: false,
                requestedReviewerLogins: requestedReviewerLogins,
                ciState: .passing
            )
        )
    }
}
