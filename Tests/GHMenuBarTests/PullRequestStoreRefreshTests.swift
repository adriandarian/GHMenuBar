import XCTest
import GHCore
@testable import GHMenuBar

@MainActor
final class PullRequestStoreRefreshTests: XCTestCase {
    func testBulkRefreshUsesOnlyWatchedRepositoriesAndPreservesRowsAfterPartialFailure() async throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.store.loadRepositories()
        await fixture.store.refreshManually()
        let before = try XCTUnwrap(fixture.store.selection).pullRequests
        XCTAssertFalse(before.isEmpty)
        await fixture.runner.fail("acme/beta")
        await fixture.store.refreshManually()
        let after = try XCTUnwrap(fixture.store.selection).pullRequests
        XCTAssertEqual(Set(after.map(\.repository)), Set(before.map(\.repository)))
        XCTAssertTrue(after.allSatisfy(\.hasReviewMetadata))
        XCTAssertEqual(fixture.store.currentUserLogin, "dariana")
        XCTAssertNotNil(fixture.store.repositoryRefreshErrorMessage)
        XCTAssertEqual(fixture.store.repositoryRefreshErrorRepository, "acme/beta")
        let commands = await fixture.runner.commands
        XCTAssertFalse(commands.contains { $0.first == "search" || $0.first == "repo" })
        XCTAssertEqual(commands.filter { $0 == GitHubCLI.viewerLoginCommand() }.count, 1)
        XCTAssertEqual(Set(commands.filter { $0.first == "pr" }.map { $0[3] }), ["acme/alpha", "acme/beta"])
    }

    func testRateLimitOnStartupRestoresKnownAccountCache() async throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let pr = PullRequest(title: "Cached", url: URL(string: "https://github.com/acme/alpha/pull/1")!,
            repository: "acme/alpha", author: "someone", updatedAt: Date(), isDraft: false,
            reviewSummary: .init(approvalCount: 0, hasChangesRequested: false, requestedReviewerLogins: [], ciState: .none))
        PullRequestCache(defaults: fixture.defaults).save(entries: ["acme/alpha": .init(fetchedAt: Date(), pullRequests: [pr])], for: "dariana")
        await fixture.runner.limitIdentity()
        await fixture.store.loadRepositories()
        XCTAssertEqual(fixture.store.currentUserLogin, "dariana")
        XCTAssertEqual(fixture.store.selection?.pullRequests.map(\.title), ["Cached"])
        guard case .unavailable = fixture.store.authenticationStatus else { return XCTFail("Expected temporary failure") }
    }

    func testOverlappingBulkRefreshesShareOneOperation() async throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.store.loadRepositories()
        await fixture.store.refreshManually()
        await fixture.runner.pauseNextAlpha()
        let first = Task { await fixture.store.refreshManually() }
        await fixture.runner.waitForPause()
        let countBefore = await fixture.runner.commands.count
        await fixture.store.refreshManually()
        let countAfter = await fixture.runner.commands.count
        XCTAssertEqual(countBefore, countAfter)
        await fixture.runner.resume()
        await first.value
        XCTAssertFalse(fixture.store.isBatchRefreshing)
    }

    func testSwitchToAnUnverifiedAccountHidesPreviousAccountsRows() async throws {
        let fixture = makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.store.loadRepositories()
        await fixture.store.refreshManually()
        XCTAssertFalse(try XCTUnwrap(fixture.store.selection).pullRequests.isEmpty)
        await fixture.runner.switchAccount(to: "another-account")
        await fixture.runner.limitIdentity()
        await fixture.store.refreshManually()
        XCTAssertNil(fixture.store.currentUserLogin)
        XCTAssertTrue(try XCTUnwrap(fixture.store.selection).pullRequests.isEmpty)
        XCTAssertEqual(PullRequestCache(defaults: fixture.defaults).savedLogin, "dariana")
    }

    private func makeStore() -> (store: PullRequestStore, runner: RepositoryRunner, defaults: UserDefaults, suite: String) {
        let suite = "GHMenuBarTests.Refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = GHMenuBarSettings(githubOwner: "", refreshIntervalSeconds: 300,
            repositoryFilter: .init(organizations: ["acme"], includedRepositories: ["acme/alpha", "acme/beta"]),
            agentReview: GHMenuBarSettings.default.agentReview)
        let storage = GHMenuBarSettingsStorage(defaults: defaults)
        storage.save(settings)
        let runner = RepositoryRunner()
        let store = PullRequestStore(settingsStorage: storage,
            selectedRepositoryMemory: .init(defaults: defaults), pullRequestCache: .init(defaults: defaults),
            pullRequestReadStateMemory: .init(defaults: defaults),
            client: GitHubCLI(settings: settings, runner: runner, coordinator: GitHubRequestCoordinator()))
        return (store, runner, defaults, suite)
    }
}

private actor RepositoryRunner: ProcessRunning {
    var commands: [[String]] = []
    var failures: Set<String> = []
    var identityLimited = false
    var login = "dariana"
    var shouldPauseAlpha = false
    var paused: CheckedContinuation<Void, Never>?
    var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    func fail(_ repository: String) { failures.insert(repository) }
    func limitIdentity() { identityLimited = true }
    func switchAccount(to login: String) { self.login = login }
    func pauseNextAlpha() { shouldPauseAlpha = true }
    func waitForPause() async {
        if paused != nil { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }
    func resume() { paused?.resume(); paused = nil }
    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        commands.append(arguments)
        if arguments.first == "config" { return .init(stdout: login, stderr: "", exitCode: 0) }
        if arguments == GitHubCLI.viewerLoginCommand() {
            if identityLimited {
                return .init(stdout: "", stderr: "gh: API rate limit exceeded", exitCode: 1,
                    httpObservations: [.init(resource: "graphql", status: 403, remaining: 0, resetAt: Date().addingTimeInterval(600))])
            }
            return .init(stdout: login, stderr: "", exitCode: 0)
        }
        guard arguments.first == "pr" else { return .init(stdout: "[]", stderr: "", exitCode: 0) }
        let repository = arguments[3]
        if repository == "acme/alpha", shouldPauseAlpha {
            shouldPauseAlpha = false
            await withCheckedContinuation { continuation in
                paused = continuation
                pauseWaiters.forEach { $0.resume() }
                pauseWaiters = []
            }
        }
        if failures.contains(repository) { return .init(stdout: "", stderr: "permission denied", exitCode: 1) }
        return .init(stdout: """
        [{"number":1,"title":"\(repository)","url":"https://github.com/\(repository)/pull/1",
          "author":{"login":"someone"},"updatedAt":"2026-09-13T04:00:00Z","isDraft":false,
          "reviewDecision":"REVIEW_REQUIRED","reviewRequests":[],"latestReviews":[],"statusCheckRollup":[],"commits":[]}]
        """, stderr: "", exitCode: 0)
    }
}
