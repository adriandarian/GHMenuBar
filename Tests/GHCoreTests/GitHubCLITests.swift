import Foundation
import XCTest
@testable import GHCore

final class GitHubCLITests: XCTestCase {
    func testRepositoryListCommandCanUseAuthenticatedDefaultScope() {
        XCTAssertEqual(
            GitHubCLI.repositoryListCommand(owner: "", limit: 100),
            [
                "repo", "list",
                "--limit", "100",
                "--json", "nameWithOwner"
            ]
        )
    }

    func testOpenPullRequestCommandCanUseAuthenticatedDefaultScope() {
        XCTAssertEqual(
            GitHubCLI.openPullRequestsCommand(owner: "", limit: 20),
            [
                "search", "prs",
                "--state", "open",
                "--draft=false",
                "--limit", "20",
                "--sort", "updated",
                "--order", "desc",
                "--json", "number,title,url,repository,author,updatedAt,isDraft"
            ]
        )
    }

    func testFetchRepositoriesUsesAuthenticatedDefaultScopeWhenOwnerIsBlank() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "[]", stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "", runner: runner)

        _ = try await client.fetchRepositories(limit: 100)

        XCTAssertEqual(runner.lastArguments, GitHubCLI.repositoryListCommand(owner: "", limit: 100))
    }

    func testFetchRepositoriesSurfacesStderrWhenGhExitsZeroWithoutJson() async {
        let runner = StubProcessRunner(result: .success(ProcessResult(
            stdout: "",
            stderr: "error connecting to api.github.com",
            exitCode: 0
        )))
        let client = GitHubCLI(owner: "", runner: runner)

        do {
            _ = try await client.fetchRepositories(limit: 100)
            XCTFail("Expected gh stderr to be surfaced")
        } catch let error as GitHubCLIError {
            XCTAssertEqual(
                error,
                .commandFailed(message: "error connecting to api.github.com", exitCode: 0)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchOpenPullRequestsUsesAuthenticatedDefaultScopeWhenOwnerIsBlank() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "[]", stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "", runner: runner)

        _ = try await client.fetchOpenPullRequests(limit: 20)

        XCTAssertEqual(runner.lastArguments, GitHubCLI.openPullRequestsCommand(owner: "", limit: 20))
    }

    func testSettingsInitializerUsesAuthenticatedDefaultScopeInsteadOfStoredOwner() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "[]", stderr: "", exitCode: 0)))
        let client = GitHubCLI(
            settings: GHMenuBarSettings(
                githubOwner: "acme",
                refreshIntervalSeconds: 300,
                agentReview: GHMenuBarSettings.default.agentReview
            ),
            runner: runner
        )

        _ = try await client.fetchRepositories(limit: 100)

        XCTAssertEqual(runner.lastArguments, GitHubCLI.repositoryListCommand(owner: "", limit: 100))
    }

    func testRepositoryListCommandUsesConfiguredGitHubOwner() {
        XCTAssertEqual(
            GitHubCLI.repositoryListCommand(owner: "acme", limit: 100),
            [
                "repo", "list",
                "acme",
                "--limit", "100",
                "--json", "nameWithOwner"
            ]
        )
    }

    func testOpenPullRequestCommandUsesConfiguredGitHubOwner() {
        XCTAssertEqual(
            GitHubCLI.openPullRequestsCommand(owner: "acme", limit: 20),
            [
                "search", "prs",
                "--state", "open",
                "--draft=false",
                "--owner", "acme",
                "--limit", "20",
                "--sort", "updated",
                "--order", "desc",
                "--json", "number,title,url,repository,author,updatedAt,isDraft"
            ]
        )
    }

    func testFetchRepositoriesUsesConfiguredGitHubOwner() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "[]", stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        _ = try await client.fetchRepositories(limit: 100)

        XCTAssertEqual(runner.lastArguments, GitHubCLI.repositoryListCommand(owner: "acme", limit: 100))
    }

    func testFetchOpenPullRequestsUsesConfiguredGitHubOwner() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "[]", stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        _ = try await client.fetchOpenPullRequests(limit: 20)

        XCTAssertEqual(runner.lastArguments, GitHubCLI.openPullRequestsCommand(owner: "acme", limit: 20))
    }

    func testRepositoryListCommandUsesGitHubRepoJSONFields() {
        XCTAssertEqual(
            GitHubCLI.repositoryListCommand(owner: "acme", limit: 100),
            [
                "repo", "list",
                "acme",
                "--limit", "100",
                "--json", "nameWithOwner"
            ]
        )
    }

    func testOpenPullRequestCommandUsesGitHubSearchJSONFields() {
        XCTAssertEqual(
            GitHubCLI.openPullRequestsCommand(owner: "acme", limit: 20),
            [
                "search", "prs",
                "--state", "open",
                "--draft=false",
                "--owner", "acme",
                "--limit", "20",
                "--sort", "updated",
                "--order", "desc",
                "--json", "number,title,url,repository,author,updatedAt,isDraft"
            ]
        )
    }

    func testOpenPullRequestCommandExcludesDraftPullRequests() {
        XCTAssertTrue(GitHubCLI.openPullRequestsCommand(owner: "acme", limit: 20).contains("--draft=false"))
    }

    func testRepositoryOpenPullRequestCommandUsesRepoQualifier() {
        XCTAssertEqual(
            GitHubCLI.openPullRequestsCommand(repository: "acme/frontend", limit: 100),
            [
                "pr", "list",
                "--repo", "acme/frontend",
                "--state", "open",
                "--search", "draft:false",
                "--limit", "100",
                "--json", "number,title,url,author,updatedAt,isDraft,baseRefName,reviewDecision,reviewRequests,latestReviews,statusCheckRollup,commits"
            ]
        )
    }

    func testFetchOpenPullRequestsForRepositoryUsesSafeDefaultLimit() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "[]", stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        _ = try await client.fetchOpenPullRequests(repository: "acme/frontend")

        XCTAssertEqual(
            runner.lastArguments,
            GitHubCLI.openPullRequestsCommand(repository: "acme/frontend", limit: 48)
        )
    }

    func testFetchRepositoriesMapsGitHubJSON() async throws {
        let json = """
        [
          {"nameWithOwner": "acme/bravo"},
          {"nameWithOwner": "acme/alpha"}
        ]
        """
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: json, stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        let repositories = try await client.fetchRepositories(limit: 100)

        XCTAssertEqual(repositories, ["acme/alpha", "acme/bravo"])
        XCTAssertEqual(runner.lastExecutable, "gh")
        XCTAssertEqual(runner.lastArguments, GitHubCLI.repositoryListCommand(owner: "acme", limit: 100))
    }

    func testFetchOpenPullRequestsMapsGitHubJSON() async throws {
        let json = """
        [
          {
            "title": "Add menu bar sync",
            "url": "https://github.com/acme/widget/pull/42",
            "repository": {"nameWithOwner": "acme/widget"},
            "author": {"login": "dariana"},
            "updatedAt": "2026-06-16T05:12:00Z",
            "isDraft": false
          },
          {
            "title": "Draft settings panel",
            "url": "https://github.com/acme/widget/pull/43",
            "repository": {"nameWithOwner": "acme/widget"},
            "author": {"login": "octocat"},
            "updatedAt": "2026-06-15T20:00:00Z",
            "isDraft": true
          }
        ]
        """
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: json, stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        let pullRequests = try await client.fetchOpenPullRequests(limit: 20)

        XCTAssertEqual(pullRequests.count, 2)
        XCTAssertEqual(pullRequests[0].title, "Add menu bar sync")
        XCTAssertEqual(pullRequests[0].url.absoluteString, "https://github.com/acme/widget/pull/42")
        XCTAssertEqual(pullRequests[0].repository, "acme/widget")
        XCTAssertEqual(pullRequests[0].author, "dariana")
        XCTAssertEqual(pullRequests[0].isDraft, false)
        XCTAssertEqual(pullRequests[1].title, "Draft settings panel")
        XCTAssertEqual(pullRequests[1].isDraft, true)
        XCTAssertEqual(runner.lastExecutable, "gh")
        XCTAssertEqual(runner.lastArguments, GitHubCLI.openPullRequestsCommand(owner: "acme", limit: 20))
    }

    func testFetchOpenPullRequestsFiltersDependabotAuthors() async throws {
        let json = """
        [
          {
            "title": "Add menu bar sync",
            "url": "https://github.com/acme/widget/pull/42",
            "repository": {"nameWithOwner": "acme/widget"},
            "author": {"login": "dariana"},
            "updatedAt": "2026-06-16T05:12:00Z",
            "isDraft": false
          },
          {
            "title": "chore(deps): bump stylelint",
            "url": "https://github.com/acme/widget/pull/43",
            "repository": {"nameWithOwner": "acme/widget"},
            "author": {"login": "app/dependabot"},
            "updatedAt": "2026-06-15T20:00:00Z",
            "isDraft": false
          },
          {
            "title": "chore(deps): bump swift-format",
            "url": "https://github.com/acme/widget/pull/44",
            "repository": {"nameWithOwner": "acme/widget"},
            "author": {"login": "dependabot[bot]"},
            "updatedAt": "2026-06-15T21:00:00Z",
            "isDraft": false
          }
        ]
        """
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: json, stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        let pullRequests = try await client.fetchOpenPullRequests(limit: 20)

        XCTAssertEqual(pullRequests.map(\.title), ["Add menu bar sync"])
    }

    func testFetchOpenPullRequestsForRepositoryUsesRepositoryCommand() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "[]", stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        _ = try await client.fetchOpenPullRequests(
            repository: "acme/frontend",
            limit: 100
        )

        XCTAssertEqual(
            runner.lastArguments,
            GitHubCLI.openPullRequestsCommand(repository: "acme/frontend", limit: 100)
        )
    }

    func testFetchOpenPullRequestsForRepositoryMapsReviewAndCIJSON() async throws {
        let json = """
        [
          {
            "title": "Add richer PR status",
            "url": "https://github.com/acme/widget/pull/44",
            "author": {"login": "octocat"},
            "updatedAt": "2026-06-16T07:00:00Z",
            "isDraft": false,
            "reviewDecision": "CHANGES_REQUESTED",
            "reviewRequests": [
              {"__typename": "User", "login": "dariana"}
            ],
            "latestReviews": [
              {"author": {"login": "ada"}, "state": "APPROVED", "submittedAt": "2026-06-16T07:10:00Z"},
              {"author": {"login": "bea"}, "state": "CHANGES_REQUESTED", "submittedAt": "2026-06-16T07:20:00Z"}
            ],
            "statusCheckRollup": [
              {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
              {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"}
            ],
            "commits": [
              {"committedDate": "2026-06-16T07:05:00Z"},
              {"committedDate": "2026-06-16T07:30:00Z"}
            ]
          }
        ]
        """
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: json, stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        let pullRequests = try await client.fetchOpenPullRequests(repository: "acme/widget", limit: 20)

        XCTAssertEqual(pullRequests.count, 1)
        XCTAssertEqual(pullRequests[0].repository, "acme/widget")
        XCTAssertEqual(pullRequests[0].reviewSummary?.approvalCount, 1)
        XCTAssertEqual(pullRequests[0].reviewSummary?.hasChangesRequested, true)
        XCTAssertEqual(pullRequests[0].reviewSummary?.ciState, .failing)
        XCTAssertEqual(pullRequests[0].reviewSummary?.isReviewRequested(for: "dariana"), true)
        XCTAssertEqual(pullRequests[0].reviewSummary?.isReviewRequested(for: "octocat"), false)
        XCTAssertEqual(
            pullRequests[0].reviewSummary?.latestReviewSubmittedAt(for: "ada"),
            try githubDate("2026-06-16T07:10:00Z")
        )
        XCTAssertEqual(
            pullRequests[0].latestCommitCommittedAt,
            try githubDate("2026-06-16T07:30:00Z")
        )
    }

    func testFetchOpenPullRequestsIgnoresBaseBranchUpdateAfterReview() async throws {
        let json = """
        [
          {
            "title": "Update tile routing",
            "url": "https://github.com/acme/widget/pull/45",
            "author": {"login": "octocat"},
            "updatedAt": "2026-06-16T08:00:00Z",
            "isDraft": false,
            "baseRefName": "main",
            "reviewDecision": "CHANGES_REQUESTED",
            "reviewRequests": [],
            "latestReviews": [
              {"author": {"login": "dariana"}, "state": "CHANGES_REQUESTED", "submittedAt": "2026-06-16T07:45:00Z"}
            ],
            "statusCheckRollup": [],
            "commits": [
              {"committedDate": "2026-06-16T07:30:00Z", "messageHeadline": "feat: update tile routing"},
              {"committedDate": "2026-06-16T08:00:00Z", "messageHeadline": "Merge branch 'main' into UPP-93733"}
            ]
          }
        ]
        """
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: json, stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        let pullRequests = try await client.fetchOpenPullRequests(repository: "acme/widget", limit: 20)
        let pullRequest = try XCTUnwrap(pullRequests.first)

        XCTAssertEqual(pullRequest.latestCommitCommittedAt, try githubDate("2026-06-16T07:30:00Z"))
        XCTAssertFalse(pullRequest.needsReview(from: "dariana"))
    }

    func testFetchViewerLoginUsesGitHubAPI() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "dariana\n", stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        let login = try await client.fetchViewerLogin()

        XCTAssertEqual(login, "dariana")
        XCTAssertEqual(runner.lastExecutable, "gh")
        XCTAssertEqual(runner.lastArguments, GitHubCLI.viewerLoginCommand())
    }

    func testOrganizationListCommandUsesGitHubAPI() {
        XCTAssertEqual(
            GitHubCLI.organizationListCommand(),
            ["api", "user/orgs", "--paginate", "--jq", ".[].login"]
        )
    }

    func testFetchAccountsIncludesViewerAndOrganizations() async throws {
        let runner = SequencedProcessRunner(results: [
                ProcessResult(stdout: "dariana\n", stderr: "", exitCode: 0),
                ProcessResult(stdout: "acme\nother-org\n", stderr: "", exitCode: 0)
        ])
        let client = GitHubCLI(runner: runner)

        let accounts = try await client.fetchAccounts()

        XCTAssertEqual(accounts, ["dariana", "acme", "other-org"])
        XCTAssertEqual(runner.commands.map(\.arguments), [
            GitHubCLI.viewerLoginCommand(),
            GitHubCLI.organizationListCommand()
        ])
    }

    func testAuthenticationStatusReportsAuthenticatedViewer() async {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "dariana\n", stderr: "", exitCode: 0)))
        let client = GitHubCLI(runner: runner)

        let status = await client.authenticationStatus()

        XCTAssertEqual(status, .authenticated(login: "dariana"))
        XCTAssertEqual(runner.lastExecutable, "gh")
        XCTAssertEqual(runner.lastArguments, GitHubCLI.viewerLoginCommand())
    }

    func testAuthenticationStatusReportsUnauthenticatedFailure() async {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "", stderr: "gh auth login required", exitCode: 1)))
        let client = GitHubCLI(runner: runner)

        let status = await client.authenticationStatus()

        XCTAssertEqual(status, .unauthenticated(message: "gh auth login required"))
    }

    func testFetchOpenPullRequestsUsesExpandedDefaultLimit() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "[]", stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        _ = try await client.fetchOpenPullRequests()

        XCTAssertEqual(
            runner.lastArguments,
            GitHubCLI.openPullRequestsCommand(owner: "acme", limit: 1_000)
        )
    }

    func testFetchOpenPullRequestsReturnsEmptyList() async throws {
        let runner = StubProcessRunner(result: .success(ProcessResult(stdout: "[]", stderr: "", exitCode: 0)))
        let client = GitHubCLI(owner: "acme", runner: runner)

        let pullRequests = try await client.fetchOpenPullRequests(limit: 20)

        XCTAssertTrue(pullRequests.isEmpty)
    }

    func testFetchOpenPullRequestsSurfacesCLIStderrOnFailure() async {
        let result = ProcessResult(
            stdout: "",
            stderr: "the token in default is invalid",
            exitCode: 1
        )
        let runner = StubProcessRunner(result: .success(result))
        let client = GitHubCLI(owner: "acme", runner: runner)

        do {
            _ = try await client.fetchOpenPullRequests(limit: 20)
            XCTFail("Expected fetchOpenPullRequests to throw")
        } catch let error as GitHubCLIError {
            XCTAssertEqual(error.errorDescription, "the token in default is invalid")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchOpenPullRequestsRetriesTransientGatewayTimeout() async throws {
        let runner = SequencedProcessRunner(results: [
            ProcessResult(stdout: "", stderr: "HTTP 504: 504 Gateway Timeout (https://api.github.com/graphql)", exitCode: 1),
            ProcessResult(stdout: "[]", stderr: "", exitCode: 0)
        ])
        let client = GitHubCLI(owner: "acme", runner: runner)

        let pullRequests = try await client.fetchOpenPullRequests(limit: 20)
        XCTAssertTrue(pullRequests.isEmpty)
        XCTAssertEqual(runner.commands.count, 2)
    }

    func testFetchOpenPullRequestsDoesNotRetryUnrelatedFailure() async {
        let runner = SequencedProcessRunner(results: [
            ProcessResult(stdout: "", stderr: "permission denied", exitCode: 1)
        ])
        let client = GitHubCLI(owner: "acme", runner: runner)

        do {
            _ = try await client.fetchOpenPullRequests(limit: 20)
            XCTFail("Expected fetchOpenPullRequests to throw")
        } catch {
            XCTAssertEqual(runner.commands.count, 1)
        }
    }

    func testFetchOpenPullRequestsShowsActionableMessageForBadCredentials() async {
        let result = ProcessResult(
            stdout: "",
            stderr: """
            non-200 OK status code: 401 Unauthorized body: "{\\r\\n  \\"message\\":\\"Bad credentials\\",\\r\\n  \\"documentation_url\\":\\"https://docs.github.com/rest\\",\\r\\n  \\"status\\":\\"401\\"\\r\\n}"
            """,
            exitCode: 1
        )
        let runner = StubProcessRunner(result: .success(result))
        let client = GitHubCLI(owner: "acme", runner: runner)

        do {
            _ = try await client.fetchOpenPullRequests(limit: 20)
            XCTFail("Expected fetchOpenPullRequests to throw")
        } catch let error as GitHubCLIError {
            XCTAssertEqual(
                error.errorDescription,
                "GitHub credentials were rejected. Run `gh auth login -h github.com` or `gh auth refresh -h github.com`."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchOpenPullRequestsClearsGitHubCLICacheAndRetriesBadCredentials() async throws {
        let badCredentials = ProcessResult(
            stdout: "",
            stderr: """
            non-200 OK status code: 401 Unauthorized body: "{\\r\\n  \\"message\\":\\"Bad credentials\\",\\r\\n  \\"documentation_url\\":\\"https://docs.github.com/rest\\",\\r\\n  \\"status\\":\\"401\\"\\r\\n}"
            """,
            exitCode: 1
        )
        let successfulPullRequests = ProcessResult(
            stdout: """
            [
              {
                "title": "Repair sync",
                "url": "https://github.com/acme/widget/pull/44",
                "author": {"login": "octocat"},
                "updatedAt": "2026-06-16T07:00:00Z",
                "isDraft": false,
                "reviewDecision": "REVIEW_REQUIRED",
                "reviewRequests": [],
                "latestReviews": [],
                "statusCheckRollup": [],
                "commits": []
              }
            ]
            """,
            stderr: "",
            exitCode: 0
        )
        let runner = SequencedProcessRunner(results: [
            badCredentials,
            ProcessResult(stdout: "", stderr: "", exitCode: 0),
            successfulPullRequests
        ])
        let client = GitHubCLI(owner: "acme", runner: runner)

        let pullRequests = try await client.fetchOpenPullRequests(repository: "acme/widget", limit: 20)

        XCTAssertEqual(pullRequests.map(\.title), ["Repair sync"])
        XCTAssertEqual(
            runner.commands,
            [
                SequencedProcessRunner.Command(
                    executable: "gh",
                    arguments: GitHubCLI.openPullRequestsCommand(repository: "acme/widget", limit: 20)
                ),
                SequencedProcessRunner.Command(
                    executable: "gh",
                    arguments: ["config", "clear-cache"]
                ),
                SequencedProcessRunner.Command(
                    executable: "gh",
                    arguments: GitHubCLI.openPullRequestsCommand(repository: "acme/widget", limit: 20)
                )
            ]
        )
    }

    func testDefaultRunnerSearchPathIncludesCommonGitHubCLILocations() {
        let searchPath = DefaultProcessRunner.searchPath(existingPath: "/usr/bin:/bin")

        XCTAssertTrue(searchPath.contains("/opt/homebrew/bin"))
        XCTAssertTrue(searchPath.contains("/usr/local/bin"))
        XCTAssertTrue(searchPath.contains("/usr/bin"))
        XCTAssertTrue(searchPath.contains("/bin"))
    }

    func testDefaultRunnerResolvesExecutableFromFallbackSearchPath() {
        let searchPath = DefaultProcessRunner.searchPath(existingPath: "/usr/bin:/bin")

        let executablePath = DefaultProcessRunner.executablePath(
            executable: "gh",
            searchPath: searchPath,
            fileExists: { $0 == "/opt/homebrew/bin/gh" }
        )

        XCTAssertEqual(executablePath, "/opt/homebrew/bin/gh")
    }

    func testDefaultRunnerCapturesLargeOutputWithoutBlockingChildProcess() async throws {
        let runner = DefaultProcessRunner()
        let payloadSize = 1_048_576
        let script = """
        use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
        my $flags = fcntl(STDOUT, F_GETFL, 0);
        fcntl(STDOUT, F_SETFL, $flags | O_NONBLOCK);
        my $remaining = \(payloadSize);
        my $chunk = "x" x 8192;
        my $blocked = 0;
        while ($remaining > 0) {
            my $length = $remaining < length($chunk) ? $remaining : length($chunk);
            my $written = syswrite(STDOUT, $chunk, $length);
            if (!defined $written) {
                if ($!{EAGAIN} || $!{EWOULDBLOCK}) {
                    select undef, undef, undef, 0.001;
                    $blocked += 1;
                    exit 42 if $blocked > 500;
                    next;
                }
                die $!;
            }
            $blocked = 0;
            $remaining -= $written;
        }
        """

        let result = try await runner.run(executable: "/usr/bin/perl", arguments: ["-e", script])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, payloadSize)
    }

    func testRepositorySelectionStartsAtFirstSortedRepositoryAndFiltersPullRequests() {
        let selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "B", repository: "acme/bravo"),
            samplePullRequest(title: "A", repository: "acme/alpha")
        ])

        XCTAssertEqual(selection.repositories, ["acme/alpha", "acme/bravo"])
        XCTAssertEqual(selection.selectedRepository, "acme/alpha")
        XCTAssertEqual(selection.visiblePullRequests.map(\.title), ["A"])
    }

    func testRepositorySelectionCanUseExplicitRepositoryCatalog() {
        let selection = PullRequestRepositorySelection(
            pullRequests: [
                samplePullRequest(title: "A", repository: "acme/alpha")
            ],
            repositories: ["acme/charlie", "acme/bravo", "acme/alpha"]
        )

        XCTAssertEqual(selection.repositories, ["acme/alpha", "acme/bravo", "acme/charlie"])
        XCTAssertEqual(selection.selectedRepository, "acme/alpha")
    }

    func testRepositorySelectionWrapsForwardAndBackward() {
        var selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "A", repository: "acme/alpha"),
            samplePullRequest(title: "B", repository: "acme/bravo")
        ])

        selection.selectPreviousRepository()
        XCTAssertEqual(selection.selectedRepository, "acme/bravo")

        selection.selectNextRepository()
        XCTAssertEqual(selection.selectedRepository, "acme/alpha")
    }

    func testRepositorySelectionPreservesRepositoryAcrossRefresh() {
        var selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "A", repository: "acme/alpha"),
            samplePullRequest(title: "B", repository: "acme/bravo")
        ])
        selection.selectNextRepository()

        selection.update(pullRequests: [
            samplePullRequest(title: "B2", repository: "acme/bravo"),
            samplePullRequest(title: "C", repository: "acme/charlie")
        ])

        XCTAssertEqual(selection.selectedRepository, "acme/bravo")
        XCTAssertEqual(selection.visiblePullRequests.map(\.title), ["B2"])
    }

    func testRepositorySelectionFallsBackWhenSelectedRepositoryDisappears() {
        var selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "A", repository: "acme/alpha"),
            samplePullRequest(title: "B", repository: "acme/bravo")
        ])
        selection.selectNextRepository()

        selection.update(pullRequests: [
            samplePullRequest(title: "C", repository: "acme/charlie")
        ])

        XCTAssertEqual(selection.selectedRepository, "acme/charlie")
        XCTAssertEqual(selection.visiblePullRequests.map(\.title), ["C"])
    }

    func testRepositorySelectionClearsWhenNoPullRequestsRemain() {
        var selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "A", repository: "acme/alpha")
        ])

        selection.update(pullRequests: [])

        XCTAssertEqual(selection.repositories, [])
        XCTAssertNil(selection.selectedRepository)
        XCTAssertEqual(selection.visiblePullRequests, [])
    }

    func testRepositorySelectionSearchesRepositoriesCaseInsensitively() {
        let selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "A", repository: "acme/AlphaApp"),
            samplePullRequest(title: "B", repository: "acme/bravo-service"),
            samplePullRequest(title: "C", repository: "acme/charlie")
        ])

        XCTAssertEqual(
            selection.repositories(matching: "APP"),
            ["acme/AlphaApp"]
        )
        XCTAssertEqual(
            selection.repositories(matching: "acme/"),
            ["acme/AlphaApp", "acme/bravo-service", "acme/charlie"]
        )
    }

    func testRepositorySelectionSearchReturnsAllRepositoriesForEmptyQuery() {
        let selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "B", repository: "acme/bravo"),
            samplePullRequest(title: "A", repository: "acme/alpha")
        ])

        XCTAssertEqual(
            selection.repositories(matching: "   "),
            ["acme/alpha", "acme/bravo"]
        )
    }

    func testRepositorySelectionSelectsRepositoryByName() {
        var selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "A", repository: "acme/alpha"),
            samplePullRequest(title: "B", repository: "acme/bravo")
        ])

        XCTAssertTrue(selection.selectRepository("acme/bravo"))
        XCTAssertEqual(selection.selectedRepository, "acme/bravo")
        XCTAssertEqual(selection.visiblePullRequests.map(\.title), ["B"])
    }

    func testRepositorySelectionDoesNotSelectUnknownRepository() {
        var selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "A", repository: "acme/alpha")
        ])

        XCTAssertFalse(selection.selectRepository("acme/missing"))
        XCTAssertEqual(selection.selectedRepository, "acme/alpha")
    }

    func testSelectedRepositoryMemoryPersistsSelectedRepository() throws {
        let suiteName = "GHMenuBarTests.SelectedRepositoryMemory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let memory = SelectedRepositoryMemory(defaults: defaults)

        memory.saveSelectedRepository("acme/bravo")

        XCTAssertEqual(memory.selectedRepository, "acme/bravo")
    }

    func testRepositoryFilterProvidesExplicitCatalogWithoutDiscovery() {
        let filter = RepositoryFilterSettings(
            organizations: ["acme"],
            includedRepositories: ["acme/alpha", "other/bravo", "acme/charlie"],
            excludedRepositories: ["acme/charlie"]
        )

        XCTAssertEqual(filter.explicitRepositoryCatalog, ["acme/alpha"])
        XCTAssertNil(RepositoryFilterSettings().explicitRepositoryCatalog)
    }

    func testPullRequestCachePersistsFullMetadataForMatchingAccount() throws {
        let suiteName = "GHMenuBarTests.PullRequestCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = PullRequestCache(defaults: defaults)
        let fetchedAt = Date(timeIntervalSince1970: 1_779_000_300)
        let pullRequest = samplePullRequest(
            title: "Cached",
            repository: "acme/alpha",
            author: "octocat",
            latestCommitCommittedAt: Date(timeIntervalSince1970: 1_779_000_200),
            reviewSummary: PullRequestReviewSummary(
                approvalCount: 1,
                hasChangesRequested: false,
                requestedReviewerLogins: ["dariana"],
                ciState: .passing,
                reviewSubmittedAtByAuthor: ["dariana": Date(timeIntervalSince1970: 1_779_000_100)],
                approvedReviewerLogins: ["reviewer"]
            )
        )

        cache.save(
            entries: [
                "acme/alpha": PullRequestCacheEntry(
                    fetchedAt: fetchedAt,
                    pullRequests: [pullRequest]
                )
            ],
            for: "dariana"
        )

        XCTAssertEqual(
            cache.entries(for: "DARIANA")["acme/alpha"],
            PullRequestCacheEntry(fetchedAt: fetchedAt, pullRequests: [pullRequest])
        )
        XCTAssertTrue(cache.entries(for: "someone-else").isEmpty)
    }

    func testRepositorySelectionFiltersVisiblePullRequestsRequiringReview() {
        let selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(
                title: "NeedsReview",
                repository: "acme/alpha",
                author: "octocat",
                latestCommitCommittedAt: Date(timeIntervalSince1970: 1_779_000_200),
                reviewSummary: PullRequestReviewSummary(
                    approvalCount: 1,
                    hasChangesRequested: false,
                    requestedReviewerLogins: [],
                    ciState: .passing,
                    reviewSubmittedAtByAuthor: ["dariana": Date(timeIntervalSince1970: 1_779_000_100)]
                )
            ),
            samplePullRequest(
                title: "AlreadyReviewed",
                repository: "acme/alpha",
                author: "octocat",
                latestCommitCommittedAt: Date(timeIntervalSince1970: 1_779_000_100),
                reviewSummary: PullRequestReviewSummary(
                    approvalCount: 1,
                    hasChangesRequested: false,
                    requestedReviewerLogins: [],
                    ciState: .passing,
                    reviewSubmittedAtByAuthor: ["dariana": Date(timeIntervalSince1970: 1_779_000_200)]
                )
            )
        ])

        XCTAssertEqual(
            selection.visiblePullRequestsRequiringReview(from: "dariana").map(\.title),
            ["NeedsReview"]
        )
    }

    func testRepositorySelectionReportsWhenSelectedRepositoryHasPullRequestsRequiringReview() {
        var selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(
                title: "AlreadyReviewed",
                repository: "acme/alpha",
                author: "octocat",
                latestCommitCommittedAt: Date(timeIntervalSince1970: 1_779_000_100),
                reviewSummary: PullRequestReviewSummary(
                    approvalCount: 1,
                    hasChangesRequested: false,
                    requestedReviewerLogins: [],
                    ciState: .passing,
                    reviewSubmittedAtByAuthor: ["dariana": Date(timeIntervalSince1970: 1_779_000_200)]
                )
            ),
            samplePullRequest(
                title: "NeedsReview",
                repository: "acme/bravo",
                author: "octocat",
                reviewSummary: PullRequestReviewSummary(
                    approvalCount: 0,
                    hasChangesRequested: false,
                    requestedReviewerLogins: ["dariana"],
                    ciState: .passing,
                    reviewSubmittedAtByAuthor: [:]
                )
            )
        ])

        XCTAssertFalse(selection.hasVisiblePullRequestsRequiringReview(from: "dariana"))

        selection.selectRepository("acme/bravo")

        XCTAssertTrue(selection.hasVisiblePullRequestsRequiringReview(from: "dariana"))
    }

    func testMenuBarNotificationShowsNoIndicatorWhenCountIsZero() {
        XCTAssertEqual(
            PullRequestMenuBarNotification(count: 0),
            PullRequestMenuBarNotification(label: nil, showsDot: false)
        )
    }

    func testMenuBarNotificationShowsDotWithoutCountForPositiveCounts() {
        XCTAssertEqual(
            PullRequestMenuBarNotification(count: 16),
            PullRequestMenuBarNotification(label: nil, showsDot: true)
        )
    }

    func testMenuBarNotificationShowsDotWithoutCountForThreeDigitCounts() {
        XCTAssertEqual(
            PullRequestMenuBarNotification(count: 100),
            PullRequestMenuBarNotification(label: nil, showsDot: true)
        )
    }

    func testPullRequestExposesRepositoryNameWithoutOwner() {
        let pullRequest = samplePullRequest(title: "A", repository: "acme/alpha")

        XCTAssertEqual(pullRequest.repositoryName, "alpha")
    }

    func testPullRequestRowBylineOmitsRepositoryName() {
        let pullRequest = samplePullRequest(title: "A", repository: "acme/alpha", author: "octocat")

        XCTAssertEqual(pullRequest.rowByline, "by octocat")
    }

    func testPullRequestNeedsReviewWhenRequestedFromCurrentUser() {
        let pullRequest = samplePullRequest(
            title: "A",
            repository: "acme/alpha",
            author: "octocat",
            reviewSummary: PullRequestReviewSummary(
                approvalCount: 0,
                hasChangesRequested: false,
                requestedReviewerLogins: ["dariana"],
                ciState: .passing,
                reviewSubmittedAtByAuthor: [:]
            )
        )

        XCTAssertTrue(pullRequest.needsReview(from: "dariana"))
    }

    func testPullRequestNeedsReviewWhenCurrentUserHasNotReviewed() {
        let pullRequest = samplePullRequest(
            title: "A",
            repository: "acme/alpha",
            author: "octocat",
            reviewSummary: PullRequestReviewSummary(
                approvalCount: 1,
                hasChangesRequested: false,
                requestedReviewerLogins: [],
                ciState: .passing,
                reviewSubmittedAtByAuthor: ["ada": Date(timeIntervalSince1970: 1_779_000_000)]
            )
        )

        XCTAssertTrue(pullRequest.needsReview(from: "dariana"))
    }

    func testPullRequestNeedsReviewWhenCommitIsNewerThanCurrentUsersLastReview() {
        let pullRequest = samplePullRequest(
            title: "A",
            repository: "acme/alpha",
            author: "octocat",
            latestCommitCommittedAt: Date(timeIntervalSince1970: 1_779_000_200),
            reviewSummary: PullRequestReviewSummary(
                approvalCount: 1,
                hasChangesRequested: false,
                requestedReviewerLogins: [],
                ciState: .passing,
                reviewSubmittedAtByAuthor: ["dariana": Date(timeIntervalSince1970: 1_779_000_100)]
            )
        )

        XCTAssertTrue(pullRequest.needsReview(from: "dariana"))
    }

    func testPullRequestDoesNotNeedReviewAfterCurrentUserApprovesEvenWhenCommitIsNewer() {
        let pullRequest = samplePullRequest(
            title: "A",
            repository: "acme/alpha",
            author: "octocat",
            latestCommitCommittedAt: Date(timeIntervalSince1970: 1_779_000_200),
            reviewSummary: PullRequestReviewSummary(
                approvalCount: 1,
                hasChangesRequested: false,
                requestedReviewerLogins: [],
                ciState: .failing,
                reviewSubmittedAtByAuthor: ["dariana": Date(timeIntervalSince1970: 1_779_000_100)],
                approvedReviewerLogins: ["dariana"]
            )
        )

        XCTAssertFalse(pullRequest.needsReview(from: "dariana"))
    }

    func testPullRequestDoesNotNeedReviewWhenCurrentUserReviewedLatestCommit() {
        let pullRequest = samplePullRequest(
            title: "A",
            repository: "acme/alpha",
            author: "octocat",
            latestCommitCommittedAt: Date(timeIntervalSince1970: 1_779_000_100),
            reviewSummary: PullRequestReviewSummary(
                approvalCount: 1,
                hasChangesRequested: false,
                requestedReviewerLogins: [],
                ciState: .passing,
                reviewSubmittedAtByAuthor: ["dariana": Date(timeIntervalSince1970: 1_779_000_200)]
            )
        )

        XCTAssertFalse(pullRequest.needsReview(from: "dariana"))
    }

    func testPullRequestDoesNotNeedReviewForCurrentUserAuthor() {
        let pullRequest = samplePullRequest(
            title: "A",
            repository: "acme/alpha",
            author: "dariana",
            reviewSummary: PullRequestReviewSummary(
                approvalCount: 0,
                hasChangesRequested: false,
                requestedReviewerLogins: [],
                ciState: .passing,
                reviewSubmittedAtByAuthor: [:]
            )
        )

        XCTAssertFalse(pullRequest.needsReview(from: "dariana"))
    }

    func testRepositorySelectionSearchesRepositoryDisplayNames() {
        let selection = PullRequestRepositorySelection(pullRequests: [
            samplePullRequest(title: "A", repository: "acme/AlphaApp"),
            samplePullRequest(title: "B", repository: "acme/bravo-service")
        ])

        XCTAssertEqual(
            selection.repositoryMatches(matching: "app"),
            [
                PullRequestRepositoryMatch(repository: "acme/AlphaApp", displayName: "AlphaApp")
            ]
        )
    }

    func testRepositorySelectionUsesFullDisplayNamesForDuplicateRepositoryNames() {
        let selection = PullRequestRepositorySelection(
            pullRequests: [],
            selectedRepository: "acme-one/frontend",
            repositories: [
                "acme-one/frontend",
                "acme-two/frontend"
            ]
        )

        XCTAssertEqual(selection.selectedRepositoryName, "acme-one/frontend")
        XCTAssertEqual(
            selection.repositoryMatches(matching: "front"),
            [
                PullRequestRepositoryMatch(
                    repository: "acme-one/frontend",
                    displayName: "acme-one/frontend"
                ),
                PullRequestRepositoryMatch(
                    repository: "acme-two/frontend",
                    displayName: "acme-two/frontend"
                )
            ]
        )
    }

    func testRepositorySearchNavigationStartsAtFirstMatch() {
        let navigation = PullRequestRepositorySearchNavigation(matchCount: 3)

        XCTAssertEqual(navigation.highlightedIndex, 0)
    }

    func testRepositorySearchNavigationMovesDownAndWraps() {
        var navigation = PullRequestRepositorySearchNavigation(matchCount: 3)

        navigation.moveDown()
        XCTAssertEqual(navigation.highlightedIndex, 1)

        navigation.moveDown()
        navigation.moveDown()
        XCTAssertEqual(navigation.highlightedIndex, 0)
    }

    func testRepositorySearchNavigationMovesUpAndWraps() {
        var navigation = PullRequestRepositorySearchNavigation(matchCount: 3)

        navigation.moveUp()

        XCTAssertEqual(navigation.highlightedIndex, 2)
    }

    func testRepositorySearchNavigationClearsHighlightWhenNoMatchesExist() {
        var navigation = PullRequestRepositorySearchNavigation(matchCount: 3)

        navigation.update(matchCount: 0)

        XCTAssertNil(navigation.highlightedIndex)
    }

    func testRepositorySearchNavigationClampsWhenMatchesShrink() {
        var navigation = PullRequestRepositorySearchNavigation(matchCount: 3)
        navigation.moveUp()

        navigation.update(matchCount: 2)

        XCTAssertEqual(navigation.highlightedIndex, 1)
    }

    private func samplePullRequest(
        title: String,
        repository: String,
        author: String = "dariana",
        latestCommitCommittedAt: Date? = nil,
        reviewSummary: PullRequestReviewSummary? = nil
    ) -> PullRequest {
        PullRequest(
            title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(title)")!,
            repository: repository,
            author: author,
            updatedAt: Date(timeIntervalSince1970: 1_779_000_000),
            isDraft: false,
            latestCommitCommittedAt: latestCommitCommittedAt,
            reviewSummary: reviewSummary
        )
    }

    private func githubDate(_ string: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: string))
    }

}

private final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    let result: Result<ProcessResult, Error>
    private(set) var lastExecutable: String?
    private(set) var lastArguments: [String]?

    init(result: Result<ProcessResult, Error>) {
        self.result = result
    }

    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        lastExecutable = executable
        lastArguments = arguments
        return try result.get()
    }
}

private final class SequencedProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Command: Equatable {
        let executable: String
        let arguments: [String]
    }

    private var results: [ProcessResult]
    private(set) var commands: [Command] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        commands.append(Command(executable: executable, arguments: arguments))
        guard !results.isEmpty else {
            return ProcessResult(stdout: "", stderr: "unexpected command", exitCode: 1)
        }

        return results.removeFirst()
    }
}
