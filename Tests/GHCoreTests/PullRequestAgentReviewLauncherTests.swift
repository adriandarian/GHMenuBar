import Foundation
import XCTest
@testable import GHCore

final class PullRequestAgentReviewLauncherTests: XCTestCase {
    func testConfiguredSettingsControlSupportedRepository() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "acme/frontend",
            workspacePath: "/Users/example/acme"
        ))

        XCTAssertTrue(launcher.isSupported(pullRequest: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        )))

        XCTAssertFalse(launcher.isSupported(pullRequest: samplePullRequest(
            repository: "acme/backend",
            number: 43
        )))
    }

    func testEmptySupportedRepositoryAllowsAnyRepositoryWhenEnabled() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/acme"
        ))

        XCTAssertTrue(launcher.isSupported(pullRequest: samplePullRequest(
            repository: "acme/backend",
            number: 43
        )))
    }

    func testDisabledAgentReviewDoesNotSupportAnyRepository() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: false,
            supportedRepository: "acme/frontend",
            workspacePath: "/Users/example/acme"
        ))

        XCTAssertFalse(launcher.isSupported(pullRequest: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        )))
    }

    func testConfiguredWorkspacePathIsUsedInTerminalScript() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "acme/frontend",
            workspacePath: "/Users/example/acme"
        ))
        let pullRequest = samplePullRequest(
            repository: "acme/frontend",
            number: 42,
            title: "Add settings"
        )

        let script = launcher.terminalCommandScript(for: pullRequest)

        XCTAssertTrue(script.contains("cd '/Users/example/acme'"))
        XCTAssertTrue(script.contains("https://github.com/acme/frontend/pull/42"))
    }

    func testDefaultClaudeCodeAgentToolIsUsedInTerminalScript() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "acme/frontend",
            workspacePath: "/Users/example/acme"
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("claude "))
        XCTAssertFalse(script.contains("copilot "))
    }

    func testExplicitCopilotAgentToolIsUsedInTerminalScript() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "acme/frontend",
            workspacePath: "/Users/example/acme",
            agentTool: .copilot
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("copilot --add-dir '/Users/example/acme' "))
        XCTAssertTrue(script.contains("--disable-builtin-mcps --allow-all-tools"))
        XCTAssertTrue(script.contains("--deny-tool 'write'"))
        XCTAssertTrue(script.contains("--deny-tool 'shell(gh pr review)'"))
        XCTAssertTrue(script.contains("--prompt "))
        XCTAssertTrue(script.contains("copilot --add-dir '/Users/example/acme' --continue"))
        XCTAssertFalse(script.contains("exec copilot"))
    }

    func testReviewProfileControlsWorkspaceToolAndCommand() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/fallback",
            reviewProfiles: [
                AgentReviewProfile(
                    pathPattern: "/Users/example/work/frontend",
                    agentTool: .claudeCode,
                    reviewCommand: "/frontend-code-review"
                ),
                AgentReviewProfile(
                    pathPattern: "*",
                    agentTool: .codexCLI,
                    reviewCommand: "/review"
                )
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("cd '/Users/example/work/frontend'"))
        XCTAssertTrue(script.contains("claude "))
        XCTAssertTrue(script.contains("/frontend-code-review PR #42."))
    }

    func testScopedLocalWorkflowUsesFullPromptTemplate() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "acme/frontend",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .claudeCode,
                        workspacePathTemplate: "/Users/example/acme/{repoName}",
                        promptTemplate: "/frontend-code-review {pr}\nRepo: {repo}\nTitle: {title}\nURL: {url}"
                    )),
                    cloudReview: .disabled
                )
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42,
            title: "Add settings"
        ))

        XCTAssertTrue(script.contains("cd '/Users/example/acme/frontend'"))
        XCTAssertTrue(script.contains("/frontend-code-review PR #42"))
        XCTAssertTrue(script.contains("Repo: acme/frontend"))
        XCTAssertTrue(script.contains("Title: Add settings"))
        XCTAssertTrue(script.contains("URL: https://github.com/acme/frontend/pull/42"))
        XCTAssertFalse(script.contains("Do not submit the GitHub review until I explicitly approve the draft."))
    }

    func testScopedClaudeWorkflowCanLaunchFromPromptRootAndAddRepoWorkspace() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "acme/frontend",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .claudeCode,
                        workspacePathTemplate: "/Users/example/work/{repoName}",
                        promptRootPathTemplate: "/Users/example/work",
                        promptTemplate: "/frontend-pr-review {pr} {workspacePath}"
                    )),
                    cloudReview: .disabled
                )
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("cd '/Users/example/work'"))
        XCTAssertTrue(script.contains("claude --add-dir '/Users/example/work/frontend' "))
        XCTAssertTrue(script.contains("/frontend-pr-review PR #42 /Users/example/work/frontend"))
    }

    func testFallbackReviewProfileCanUseCodexCLI() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/fallback",
            reviewProfiles: [
                AgentReviewProfile(
                    pathPattern: "*",
                    agentTool: .codexCLI,
                    reviewCommand: "/review"
                )
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/backend",
            number: 42
        ))

        XCTAssertTrue(script.contains("cd '/Users/example/fallback'"))
        XCTAssertTrue(script.contains("codex "))
        XCTAssertTrue(script.contains("/review PR #42."))
    }

    func testRepositoryAgentToolOverrideWinsOverGlobalTool() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/acme",
            agentTool: .claudeCode,
            agentToolOverrides: ["acme/frontend": .copilot]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("copilot --add-dir '/Users/example/acme' "))
        XCTAssertFalse(script.contains("claude "))
    }

    func testOrganizationAgentToolOverrideIsUsedWhenRepositoryOverrideIsAbsent() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/acme",
            agentTool: .claudeCode,
            agentToolOverrides: ["acme/*": .copilot]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("copilot --add-dir '/Users/example/acme' "))
        XCTAssertFalse(script.contains("claude "))
    }

    func testRepositoryAgentToolOverrideWinsOverOrganizationOverride() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/acme",
            agentTool: .claudeCode,
            agentToolOverrides: [
                "acme/*": .copilot,
                "acme/frontend": .claudeCode
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("claude "))
        XCTAssertFalse(script.contains("copilot "))
    }

    func testDefaultSettingsDoNotSupportAgentReview() {
        XCTAssertFalse(PullRequestAgentReviewLauncher.isSupported(pullRequest: samplePullRequest(
            repository: "acme/frontend",
            number: 4264
        )))
    }

    func testLaunchesClaudeInTerminalWithCodeReviewPromptForSupportedPullRequest() async throws {
        let runner = CapturingProcessRunner()
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarTests-\(UUID().uuidString)", isDirectory: true)
        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme",
                globalPrompt: "Review this pull request",
                repositoryPromptOverrides: [:]
            ),
            runner: runner,
            scriptDirectory: scriptDirectory
        )
        let pullRequest = samplePullRequest(
            repository: "acme/frontend",
            number: 4264,
            title: "Fix custom ROI ghost labels"
        )

        defer { try? FileManager.default.removeItem(at: scriptDirectory) }

        try await launcher.launchReview(for: pullRequest)

        XCTAssertEqual(runner.invocations.map(\.executable), ["/bin/zsh", "open"])
        let arguments = try XCTUnwrap(runner.invocations.last?.arguments)
        XCTAssertEqual(Array(arguments.prefix(2)), ["-a", "Terminal"])
        let scriptPath = try XCTUnwrap(arguments.last)
        XCTAssertTrue(scriptPath.hasSuffix(".command"))

        let attributes = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertNotEqual(permissions.intValue & 0o111, 0)

        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertTrue(script.contains("#!/bin/zsh"))
        XCTAssertFalse(script.contains("set the clipboard to"))
        XCTAssertTrue(script.contains("cd '/Users/example/acme'"))
        XCTAssertTrue(script.contains("claude "))
        XCTAssertTrue(script.contains("Claude Code exited before completing the review"))
        XCTAssertFalse(script.contains("keystroke \"v\" using command down"))
        XCTAssertTrue(script.contains("Review this pull request PR #4264."))
        XCTAssertTrue(script.contains("Fix custom ROI ghost labels"))
        XCTAssertTrue(script.contains("https://github.com/acme/frontend/pull/4264"))
        XCTAssertFalse(script.contains("key code 36"))
    }

    func testPerLaunchClaudeOverrideUsesConfiguredProfileWorkspaceAndPrompt() async throws {
        try await assertPerLaunchOverride(
            .claudeCode,
            commandName: "claude",
            expectedCommand: "claude --add-dir '/Users/example/acme/frontend' "
        )
    }

    func testPerLaunchCopilotOverrideUsesConfiguredProfileWorkspaceAndPrompt() async throws {
        try await assertPerLaunchOverride(
            .copilot,
            commandName: "copilot",
            expectedCommand: "copilot --add-dir '/Users/example/acme/frontend' "
        )
    }

    func testPerLaunchCodexOverrideUsesConfiguredProfileWorkspaceAndPrompt() async throws {
        try await assertPerLaunchOverride(
            .codexCLI,
            commandName: "codex",
            expectedCommand: "codex --add-dir '/Users/example/acme/frontend' "
        )
    }

    func testConfiguredDefaultLaunchStillUsesProfileAgentTool() async throws {
        let runner = CapturingProcessRunner()
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarTests-\(UUID().uuidString)", isDirectory: true)
        let launcher = profileLauncher(
            configuredAgentTool: .codexCLI,
            runner: runner,
            scriptDirectory: scriptDirectory
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }

        try await launcher.launchReview(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42,
            title: "Keep configured defaults"
        ))

        XCTAssertEqual(
            runner.invocations.first?.arguments,
            ["-lc", "command -v -- codex >/dev/null"]
        )
        let script = try launchedScript(from: runner)
        XCTAssertTrue(script.contains("codex --add-dir '/Users/example/acme/frontend' "))
        XCTAssertTrue(script.contains("/frontend-code-review PR #42 /Users/example/acme/frontend"))
        XCTAssertFalse(script.contains("claude "))
        XCTAssertFalse(script.contains("copilot "))
    }

    func testPerLaunchOverrideDoesNotBypassRepositorySupport() async {
        let runner = CapturingProcessRunner()
        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme"
            ),
            runner: runner
        )

        do {
            try await launcher.launchReview(
                for: samplePullRequest(repository: "acme/backend", number: 42),
                using: .copilot
            )
            XCTFail("Expected unsupported repository to throw")
        } catch let error as PullRequestAgentReviewLauncher.Error {
            XCTAssertEqual(error, .unsupportedRepository("acme/backend"))
            XCTAssertTrue(runner.invocations.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRepositoryPromptOverrideIsUsedInTerminalScript() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/acme",
            globalPrompt: "Use the global prompt",
            repositoryPromptOverrides: ["acme/frontend": "Use frontend-specific review rules"]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("Use frontend-specific review rules PR #42."))
        XCTAssertFalse(script.contains("Use the global prompt PR #42."))
    }

    func testRejectsUnsupportedRepositoryWithoutLaunchingTerminal() async {
        let runner = CapturingProcessRunner()
        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme"
            ),
            runner: runner
        )
        let pullRequest = samplePullRequest(
            repository: "acme/backend",
            number: 1355
        )

        do {
            try await launcher.launchReview(for: pullRequest)
            XCTFail("Expected unsupported repository to throw")
        } catch let error as PullRequestAgentReviewLauncher.Error {
            XCTAssertEqual(error, .unsupportedRepository("acme/backend"))
            XCTAssertTrue(runner.invocations.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnavailableCopilotReturnsActionableErrorWithoutOpeningTerminal() async {
        let runner = CapturingProcessRunner(results: [
            ProcessResult(stdout: "", stderr: "copilot: command not found", exitCode: 127)
        ])
        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme",
                agentTool: .copilot
            ),
            runner: runner
        )

        do {
            try await launcher.launchReview(for: samplePullRequest(
                repository: "acme/frontend",
                number: 42
            ))
            XCTFail("Expected missing Copilot CLI to throw")
        } catch let error as PullRequestAgentReviewLauncher.Error {
            XCTAssertEqual(
                error,
                .agentToolUnavailable(
                    tool: "GitHub Copilot",
                    command: "copilot",
                    details: "copilot: command not found"
                )
            )
            XCTAssertEqual(
                error.errorDescription,
                """
                GitHub Copilot is not available in the shell used by GHMenuBar. copilot: command not found \
                Install `copilot` or update your shell PATH, then try again.
                """
            )
            XCTAssertEqual(runner.invocations.map(\.executable), ["/bin/zsh"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTerminalLaunchFailureIncludesStderrContext() async {
        let runner = CapturingProcessRunner(results: [
            ProcessResult(stdout: "", stderr: "", exitCode: 0),
            ProcessResult(stdout: "", stderr: "Application isn't running", exitCode: 1)
        ])
        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme"
            ),
            runner: runner
        )

        do {
            try await launcher.launchReview(for: samplePullRequest(
                repository: "acme/frontend",
                number: 42
            ))
            XCTFail("Expected Terminal launch to throw")
        } catch let error as PullRequestAgentReviewLauncher.Error {
            XCTAssertEqual(
                error,
                .commandFailed(
                    message: "Could not open Terminal for the Claude Code review: Application isn't running",
                    exitCode: 1
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGeneratedAgentScriptsHaveValidZshSyntax() async throws {
        for agentTool in AgentReviewTool.allCases {
            let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme",
                agentTool: agentTool
            ))
            let script = launcher.terminalCommandScript(for: samplePullRequest(
                repository: "acme/frontend",
                number: 42,
                title: "Handle apostrophe's quoting"
            ))
            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("GHMenuBar-\(agentTool.rawValue)-\(UUID().uuidString).zsh")
            defer { try? FileManager.default.removeItem(at: scriptURL) }
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            let result = try await DefaultProcessRunner().run(
                executable: "/bin/zsh",
                arguments: ["-n", scriptURL.path]
            )

            XCTAssertEqual(
                result.exitCode,
                0,
                "\(agentTool.displayName) script failed zsh syntax validation: \(result.stderr)"
            )
        }
    }

    private func assertPerLaunchOverride(
        _ agentTool: AgentReviewTool,
        commandName: String,
        expectedCommand: String
    ) async throws {
        let runner = CapturingProcessRunner()
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarTests-\(UUID().uuidString)", isDirectory: true)
        let launcher = profileLauncher(
            configuredAgentTool: .copilot,
            runner: runner,
            scriptDirectory: scriptDirectory
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }

        try await launcher.launchReview(
            for: samplePullRequest(
                repository: "acme/frontend",
                number: 42,
                title: "Preserve profile context"
            ),
            using: agentTool
        )

        XCTAssertEqual(
            runner.invocations.first?.arguments,
            ["-lc", "command -v -- \(commandName) >/dev/null"]
        )
        let script = try launchedScript(from: runner)
        XCTAssertTrue(script.contains("cd '/Users/example/acme'"))
        XCTAssertTrue(script.contains(expectedCommand))
        XCTAssertTrue(script.contains("/frontend-code-review PR #42 /Users/example/acme/frontend"))
        XCTAssertTrue(script.contains("Repo: acme/frontend"))
        XCTAssertTrue(script.contains("Title: Preserve profile context"))
    }

    private func profileLauncher(
        configuredAgentTool: AgentReviewTool,
        runner: ProcessRunning,
        scriptDirectory: URL
    ) -> PullRequestAgentReviewLauncher {
        PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "",
                workspacePath: "",
                reviewScopes: [
                    AgentReviewScope(
                        pattern: "acme/frontend",
                        localReview: .override(AgentReviewLocalWorkflow(
                            agentTool: configuredAgentTool,
                            workspacePathTemplate: "/Users/example/acme/{repoName}",
                            promptRootPathTemplate: "/Users/example/acme",
                            promptTemplate: """
                            /frontend-code-review {pr} {workspacePath}
                            Repo: {repo}
                            Title: {title}
                            """
                        )),
                        cloudReview: .disabled
                    )
                ]
            ),
            runner: runner,
            scriptDirectory: scriptDirectory
        )
    }

    private func launchedScript(from runner: CapturingProcessRunner) throws -> String {
        let arguments = try XCTUnwrap(runner.invocations.last?.arguments)
        XCTAssertEqual(Array(arguments.prefix(2)), ["-a", "Terminal"])
        return try String(
            contentsOfFile: XCTUnwrap(arguments.last),
            encoding: .utf8
        )
    }

    private func samplePullRequest(
        repository: String,
        number: Int,
        title: String = "Sample PR"
    ) -> PullRequest {
        PullRequest(
            title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            repository: repository,
            author: "octocat",
            updatedAt: Date(timeIntervalSince1970: 1_779_000_000),
            isDraft: false
        )
    }
}

private final class CapturingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation {
        let executable: String
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private var results: [ProcessResult]

    init(results: [ProcessResult] = []) {
        self.results = results
    }

    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        invocations.append(Invocation(executable: executable, arguments: arguments))
        if results.isEmpty {
            return ProcessResult(stdout: "", stderr: "", exitCode: 0)
        }
        return results.removeFirst()
    }
}
