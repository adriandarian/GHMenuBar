import XCTest
@testable import GHCore

final class GitHubRequestCoordinatorTests: XCTestCase {
    func testTraceCountsPagesAndNeverRetainsCredentialsOrBodies() throws {
        let trace = GitHubHTTPTrace.parse("""
        * Request at now
        * Request to https://api.github.com/user/orgs?page=1
        > GET /user/orgs?page=1 HTTP/1.1
        > Authorization: Bearer secret-token
        < HTTP/2.0 200 OK
        < X-Ratelimit-Resource: core
        < X-Ratelimit-Limit: 5000
        < X-Ratelimit-Remaining: 4000
        < X-Ratelimit-Reset: 1900000000

        [{"login":"private-organization"}]
        * Request took 20ms
        * Request at now
        * Request to https://api.github.com/graphql
        > POST /graphql HTTP/1.1
        < HTTP/2.0 200 OK
        < X-Ratelimit-Resource: graphql
        < X-Ratelimit-Remaining: 3000

        {"data":{"rateLimit":{"cost":7}}}
        * Request took 20ms
        gh: useful error
        """)
        XCTAssertEqual(trace.observations.count, 2)
        XCTAssertEqual(trace.observations.map(\.resource), ["core", "graphql"])
        XCTAssertEqual(trace.observations.map(\.status), [200, 200])
        XCTAssertEqual(trace.observations.last?.graphQLCost, 7)
        XCTAssertEqual(trace.stderr, "gh: useful error")
        let saved = String(decoding: try JSONEncoder().encode(trace.observations), as: UTF8.self)
        XCTAssertFalse(saved.contains("secret-token"))
        XCTAssertFalse(saved.contains("private-organization"))
        XCTAssertFalse(saved.contains("api.github.com"))
    }

    func testPrimaryCooldownBlocksOnlyExhaustedBucketAndExpires() async throws {
        let coordinator = GitHubRequestCoordinator()
        let runner = QuotaRunner(result: ProcessResult(stdout: "", stderr: "gh: API rate limit exceeded", exitCode: 1,
            httpObservations: [.init(resource: "core", status: 403, limit: 5000, remaining: 0,
                                     resetAt: Date().addingTimeInterval(300))]))
        do {
            _ = try await coordinator.run(arguments: ["api", "user"], runner: runner)
            XCTFail("Expected rate limit")
        } catch GitHubCLIError.rateLimited(let resource, _) {
            XCTAssertEqual(resource, "core")
        }
        await runner.setResult(ProcessResult(stdout: "[]", stderr: "", exitCode: 0))
        do {
            _ = try await coordinator.run(arguments: ["api", "user"], runner: runner)
            XCTFail("Expected cooldown without another request")
        } catch GitHubCLIError.rateLimited { }
        _ = try await coordinator.run(arguments: ["api", "graphql"], runner: runner)
        let count = await runner.count
        XCTAssertEqual(count, 2)
        let usage = await coordinator.usage(now: Date().addingTimeInterval(3_601))
        XCTAssertEqual(usage.restRequests, 0)
    }

    func testAccountSwitchDoesNotInheritPreviousAccountsCooldown() async throws {
        let coordinator = GitHubRequestCoordinator()
        let runner = QuotaRunner(result: ProcessResult(stdout: "[]", stderr: "", exitCode: 0,
            httpObservations: [.init(resource: "graphql", status: 200, remaining: 50,
                                     resetAt: Date().addingTimeInterval(300))]))
        await coordinator.useAccount("first")
        _ = try await coordinator.run(arguments: ["api", "graphql"], runner: runner)
        await coordinator.useAccount("second")
        await runner.setResult(ProcessResult(stdout: "[]", stderr: "", exitCode: 0))
        _ = try await coordinator.run(arguments: ["api", "graphql"], runner: runner)
        await coordinator.useAccount("first")
        do {
            _ = try await coordinator.run(arguments: ["api", "graphql"], runner: runner)
            XCTFail("Expected first account's reserve to remain protected")
        } catch GitHubCLIError.rateLimited { }
        let count = await runner.count
        XCTAssertEqual(count, 2)
    }

    func testSecondaryLimitHonorsRetryAfterAcrossBuckets() async throws {
        let coordinator = GitHubRequestCoordinator()
        let runner = QuotaRunner(result: ProcessResult(stdout: "", stderr: "secondary rate limit", exitCode: 1,
            httpObservations: [.init(resource: "graphql", status: 429, remaining: 2000, retryAfter: 120)]))
        let start = Date()
        do {
            _ = try await coordinator.run(arguments: ["api", "graphql"], runner: runner)
            XCTFail("Expected cooldown")
        } catch GitHubCLIError.rateLimited(let resource, let retryAt) {
            XCTAssertEqual(resource, "all")
            XCTAssertGreaterThanOrEqual(retryAt.timeIntervalSince(start), 120)
        }
        do {
            _ = try await coordinator.run(arguments: ["api", "user"], runner: runner)
            XCTFail("Expected shared secondary cooldown")
        } catch GitHubCLIError.rateLimited { }
        let count = await runner.count
        XCTAssertEqual(count, 1)
    }

    func testSuccessfulPRTitleMentioningRateLimitIsNotAnError() async throws {
        let coordinator = GitHubRequestCoordinator()
        let runner = QuotaRunner(result: ProcessResult(stdout: "[{\"title\":\"Fix rate limit\"}]", stderr: "", exitCode: 0))
        _ = try await coordinator.run(arguments: ["pr", "list"], runner: runner)
    }

    func testNetworkFailureDoesNotMeanUnauthenticated() async {
        let runner = QuotaRunner(result: ProcessResult(stdout: "", stderr: "error connecting to api.github.com", exitCode: 1))
        let client = GitHubCLI(runner: runner, coordinator: GitHubRequestCoordinator())
        let status = await client.authenticationStatus()
        XCTAssertEqual(status, .unavailable(message: "error connecting to api.github.com"))
    }

    func testConcurrentCommandsAreSerialized() async throws {
        let coordinator = GitHubRequestCoordinator()
        let runner = QuotaRunner(result: ProcessResult(stdout: "[]", stderr: "", exitCode: 0))
        async let a = coordinator.run(arguments: ["pr", "list"], runner: runner)
        async let b = coordinator.run(arguments: ["repo", "list"], runner: runner)
        _ = try await (a, b)
        let maximum = await runner.maximumConcurrent
        XCTAssertEqual(maximum, 1)
    }

    func testIdleIntervalNeverShortensConfiguredInterval() {
        XCTAssertEqual(GitHubRefreshPolicy.interval(configured: 300, isActive: true), 300)
        XCTAssertEqual(GitHubRefreshPolicy.interval(configured: 300, isActive: false), 900)
        XCTAssertEqual(GitHubRefreshPolicy.interval(configured: 1800, isActive: false), 1800)
    }
}

private actor QuotaRunner: ProcessRunning {
    var result: ProcessResult
    var count = 0
    var concurrent = 0
    var maximumConcurrent = 0
    init(result: ProcessResult) { self.result = result }
    func setResult(_ result: ProcessResult) { self.result = result }
    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        count += 1
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        await Task.yield()
        return result
    }
}
