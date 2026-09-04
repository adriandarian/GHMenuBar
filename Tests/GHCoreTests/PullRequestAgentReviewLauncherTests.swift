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
        XCTAssertTrue(script.contains("--deny-tool 'shell(gh api)'"))
        XCTAssertTrue(script.contains("--deny-tool 'shell(.agent/scripts/gh-pr-review-post.sh)'"))
        XCTAssertTrue(script.contains("--prompt "))
        XCTAssertTrue(script.contains("copilot --add-dir '/Users/example/acme' --disable-builtin-mcps"))
        XCTAssertTrue(script.contains("--continue"))
        XCTAssertTrue(script.contains("REVIEW READY — NOTHING SUBMITTED"))
        XCTAssertTrue(script.contains("[e] Edit the draft with Copilot"))
        XCTAssertTrue(script.contains("[s] Submit the draft as shown"))
        XCTAssertTrue(script.contains("[c] Cancel without submitting"))
        XCTAssertFalse(script.contains("Exact review payload:"))
        XCTAssertFalse(script.contains("python3 -m json.tool"))
        XCTAssertFalse(script.contains("Continuing interactively"))
        XCTAssertFalse(script.contains("exec copilot"))
        XCTAssertTrue(script.contains("never add a separate `suggestion` JSON field"))
    }

    func testCopilotCancelGateDoesNotContinueOrWriteToGitHub() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        try writeValidReviewPayload(to: reviewPayloadURL(from: script))

        let result = try runGeneratedScript(
            script,
            input: "c\n",
            fixture: fixture
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("REVIEW READY — NOTHING SUBMITTED"))
        XCTAssertTrue(result.output.contains("Review cancelled. Nothing was submitted."))
        XCTAssertFalse(result.output.contains("\"commit_id\""))
        XCTAssertEqual(try invocationCount(at: fixture.copilotLog), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.githubLog.path))
    }

    func testCopilotApprovalAddsOneHostSelectedAllowlistedCelebration() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        let payloadURL = try reviewPayloadURL(from: script)
        try writeValidReviewPayload(to: payloadURL)

        let result = try runGeneratedScript(script, input: "c\n", fixture: fixture)

        XCTAssertEqual(result.exitCode, 0, result.output)
        let payload = try reviewPayload(at: payloadURL)
        let body = try XCTUnwrap(payload["body"] as? String)
        let selectedCelebrations = ApprovalCelebration.allowedMarkdownValues.filter(body.contains)
        XCTAssertEqual(selectedCelebrations.count, 1, body)
        XCTAssertEqual(body.components(separatedBy: "<!-- ghmenubar-approval-celebration:start -->").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: "<!-- ghmenubar-approval-celebration:end -->").count - 1, 1)
        XCTAssertTrue(result.output.contains("Approval celebration selected from the reviewed allowlist:"))
        XCTAssertTrue(result.output.contains(selectedCelebrations[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.githubLog.path))
    }

    func testCopilotApprovalCelebrationIsIdempotentAcrossEditValidation() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        let payloadURL = try reviewPayloadURL(from: script)
        try writeValidReviewPayload(to: payloadURL)

        let result = try runGeneratedScript(script, input: "e\nc\n", fixture: fixture)

        XCTAssertEqual(result.exitCode, 0, result.output)
        let body = try XCTUnwrap(try reviewPayload(at: payloadURL)["body"] as? String)
        XCTAssertEqual(body.components(separatedBy: "<!-- ghmenubar-approval-celebration:start -->").count - 1, 1)
        XCTAssertEqual(ApprovalCelebration.allowedMarkdownValues.filter(body.contains).count, 1)
    }

    func testCopilotNonApprovalDoesNotReceiveCelebration() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        let payloadURL = try reviewPayloadURL(from: script)
        try """
        {
          "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "body": "One non-blocking observation.",
          "event": "COMMENT",
          "comments": []
        }
        """.write(to: payloadURL, atomically: true, encoding: .utf8)

        let result = try runGeneratedScript(script, input: "c\n", fixture: fixture)

        XCTAssertEqual(result.exitCode, 0, result.output)
        let body = try XCTUnwrap(try reviewPayload(at: payloadURL)["body"] as? String)
        XCTAssertEqual(body, "One non-blocking observation.")
        XCTAssertFalse(result.output.contains("Approval celebration selected from the reviewed allowlist:"))
    }

    func testCopilotEditRunsOnlyAfterExplicitEditChoiceAndReturnsToGate() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        try writeValidReviewPayload(to: reviewPayloadURL(from: script))

        let result = try runGeneratedScript(
            script,
            input: "e\nc\n",
            fixture: fixture
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("Opening the draft session for editing. Posting remains blocked."))
        XCTAssertTrue(result.output.contains("Review cancelled. Nothing was submitted."))
        XCTAssertEqual(try invocationCount(at: fixture.copilotLog), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.githubLog.path))
    }

    func testCopilotSubmitChoiceValidatesHeadThenPostsExactPayload() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        let payloadURL = try reviewPayloadURL(from: script)
        try writeValidReviewPayload(to: payloadURL)

        let result = try runGeneratedScript(
            script,
            input: "s\n",
            fixture: fixture
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("Rechecking the PR head before submission..."))
        XCTAssertTrue(result.output.contains("Review submitted."))
        XCTAssertFalse(result.output.contains("12345"))
        XCTAssertFalse(result.output.contains("\"commit_id\""))
        XCTAssertEqual(try invocationCount(at: fixture.copilotLog), 1)
        let githubInvocation = try String(contentsOf: fixture.githubLog, encoding: .utf8)
        XCTAssertTrue(githubInvocation.contains(
            "api repos/acme/frontend/pulls/42/reviews --method POST --input \(payloadURL.path)"
        ))
    }

    func testCopilotSubmitExitsWhenHeadChangedInsteadOfRedisplayingStaleGate() throws {
        let fixture = try makeCopilotGateFixture(currentHead: String(repeating: "b", count: 40))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        try writeValidReviewPayload(to: reviewPayloadURL(from: script))

        let result = try runGeneratedScript(script, input: "s\n", fixture: fixture)

        XCTAssertEqual(result.exitCode, 75, result.output)
        XCTAssertTrue(result.output.contains("PR head changed from"))
        XCTAssertFalse(result.output.contains("Submission failed. Nothing was posted"))
        XCTAssertEqual(try invocationCount(at: fixture.copilotLog), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.githubLog.path))
    }

    func testCopilotSubmitCanonicalizesLegacySuggestionField() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        let payloadURL = try reviewPayloadURL(from: script)
        try """
        {
          "commit_id": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "body": "LGTM",
          "event": "APPROVE",
          "comments": [
            {
              "path": "Sources/Feature.swift",
              "line": 12,
              "side": "RIGHT",
              "body": "Use the clearer name.",
              "suggestion": "let clearerName = value"
            }
          ]
        }
        """.write(to: payloadURL, atomically: true, encoding: .utf8)

        let result = try runGeneratedScript(
            script,
            input: "s\n",
            fixture: fixture
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("Review submitted."))

        let payloadData = try Data(contentsOf: payloadURL)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        XCTAssertEqual(payload["commit_id"] as? String, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let comments = try XCTUnwrap(payload["comments"] as? [[String: Any]])
        let comment = try XCTUnwrap(comments.first)
        XCTAssertNil(comment["suggestion"])
        XCTAssertEqual(
            comment["body"] as? String,
            "Use the clearer name.\n\n```suggestion\nlet clearerName = value\n```"
        )
    }

    func testCopilotSubmitCanonicalizesMissingStartSideUsingCommentSide() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        let payloadURL = try reviewPayloadURL(from: script)
        try """
        {
          "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "body": "Two findings inline.",
          "event": "COMMENT",
          "comments": [
            {
              "path": "Sources/Feature.swift",
              "start_line": 11,
              "line": 12,
              "side": "RIGHT",
              "body": "This range needs attention."
            }
          ]
        }
        """.write(to: payloadURL, atomically: true, encoding: .utf8)

        let result = try runGeneratedScript(
            script,
            input: "s\n",
            fixture: fixture
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("Review submitted."))

        let payloadData = try Data(contentsOf: payloadURL)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        let comments = try XCTUnwrap(payload["comments"] as? [[String: Any]])
        let comment = try XCTUnwrap(comments.first)
        XCTAssertEqual(comment["start_line"] as? Int, 11)
        XCTAssertEqual(comment["line"] as? Int, 12)
        XCTAssertEqual(comment["side"] as? String, "RIGHT")
        XCTAssertEqual(comment["start_side"] as? String, "RIGHT")
    }

    func testCopilotSubmitRejectsUnsupportedCommentFieldBeforeGitHub() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        let payloadURL = try reviewPayloadURL(from: script)
        try """
        {
          "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "body": "LGTM",
          "event": "APPROVE",
          "comments": [
            {
              "path": "Sources/Feature.swift",
              "line": 12,
              "side": "RIGHT",
              "body": "Check this.",
              "unsupported": true
            }
          ]
        }
        """.write(to: payloadURL, atomically: true, encoding: .utf8)

        let result = try runGeneratedScript(
            script,
            input: "s\nc\n",
            fixture: fixture
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("comment 1 contains unsupported fields: unsupported"))
        XCTAssertTrue(result.output.contains("not valid for GitHub submission"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.githubLog.path))
    }

    func testCopilotSubmitPreservesGitHubFailureDetails() throws {
        let fixture = try makeCopilotGateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try writeExecutable(
            """
            #!/bin/zsh
            if [[ "$1" == "pr" && "$2" == "view" ]]; then
              print -r -- 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
              exit 0
            fi
            print -u2 -- 'gh: Validation Failed (HTTP 422)'
            print -u2 -- 'comments[0].line is not part of the diff'
            exit 1
            """,
            to: fixture.bin.appendingPathComponent("gh", isDirectory: false)
        )

        let script = fixture.launcher.terminalCommandScript(for: fixture.pullRequest)
        try writeValidReviewPayload(to: reviewPayloadURL(from: script))

        let result = try runGeneratedScript(
            script,
            input: "s\nc\n",
            fixture: fixture
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("gh: Validation Failed (HTTP 422)"))
        XCTAssertTrue(result.output.contains("comments[0].line is not part of the diff"))
        XCTAssertTrue(result.output.contains("Retry Submit only after a transient GitHub error."))
    }

    func testCodexModelSelectionIsPassedToLaunchCommand() {
        let launcher = launcherWithModel(tool: .codexCLI, codexModel: "gpt-5.6-sol")

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("codex --model 'gpt-5.6-sol' "))
    }

    func testClaudeModelSelectionIsPassedToLaunchCommand() {
        let launcher = launcherWithModel(tool: .claudeCode, claudeModel: "claude-opus-5")

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("claude --model 'claude-opus-5' "))
    }

    func testCopilotModelSelectionIsPassedToDraftAndEditCommands() {
        let launcher = launcherWithModel(tool: .copilot, copilotModel: "auto")

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("copilot --add-dir '/Users/example/acme/frontend' --model 'auto' --disable-builtin-mcps"))
        XCTAssertTrue(script.contains(
            "copilot --add-dir '/Users/example/acme/frontend' --model 'auto' --disable-builtin-mcps"
        ))
        XCTAssertTrue(script.contains("--continue"))
    }

    func testBlankModelSelectionUsesRunnerDefault() {
        let launcher = launcherWithModel(tool: .claudeCode, claudeModel: "   ")

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("claude "))
        XCTAssertFalse(script.contains("--model"))
    }

    func testCopilotExpandsWorkspaceSkillPromptWithPullRequestTarget() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/ndp",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "acme/frontend",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .copilot,
                        workspacePathTemplate: "/Users/example/ndp",
                        promptTemplate: "/ndp-pr-review"
                    )),
                    cloudReview: .disabled
                )
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains(
            "read and follow the project skill at the exact path `/Users/example/ndp/.claude/skills/ndp-pr-review/SKILL.md`"
        ))
        XCTAssertTrue(script.contains("Do not substitute a personal or global skills directory for this path."))
        XCTAssertFalse(script.contains("read and follow `.claude/skills/ndp-pr-review/SKILL.md`"))
        XCTAssertFalse(script.contains("~/.claude/skills/ndp-pr-review/SKILL.md"))
        XCTAssertTrue(script.contains("Skill invocation: /ndp-pr-review"))
        XCTAssertTrue(script.contains("Target pull request: acme/frontend 42"))
        XCTAssertTrue(script.contains("Prepare the review draft only."))
        XCTAssertTrue(script.contains("native human-facing draft presentation exactly"))
        XCTAssertTrue(script.contains("Silently save the machine-readable JSON payload to `"))
        XCTAssertTrue(script.contains("Do not print the raw JSON, the file path, or any transport-file status"))
        XCTAssertTrue(script.contains("The host application renders the Edit, Submit, and Cancel confirmation gate next."))
    }

    func testCopilotWorkspaceSkillUsesPromptRootForExactSkillPath() {
        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "acme/frontend",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .copilot,
                        workspacePathTemplate: "/Users/example/work/{repoName}",
                        promptRootPathTemplate: "/Users/example/ndp",
                        promptTemplate: "/ndp-pr-review"
                    )),
                    cloudReview: .disabled
                )
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("cd '/Users/example/ndp'"))
        XCTAssertTrue(script.contains(
            "exact path `/Users/example/ndp/.claude/skills/ndp-pr-review/SKILL.md`"
        ))
        XCTAssertTrue(script.contains("copilot --add-dir '/Users/example/work/frontend' "))
    }

    func testWorktreeReviewKeepsParentWorkspaceAsImplicitSkillRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarParentWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("developers-tools", isDirectory: true)
        let worktreeRoot = root.appendingPathComponent("worktrees", isDirectory: true)
        let skillDirectory = root
            .appendingPathComponent(".claude/skills/ndp-pr-review", isDirectory: true)
        let isolatedWorkingDirectory = root.appendingPathComponent(".agent/tmp", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: isolatedWorkingDirectory,
            withIntermediateDirectories: true
        )
        try "# NDP PR Review\n".write(
            to: skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "acme/developers-tools",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .copilot,
                        workspacePathTemplate: root.path,
                        worktreeRootPathTemplate: worktreeRoot.path,
                        promptTemplate: "/ndp-pr-review {pr}"
                    )),
                    cloudReview: .disabled
                )
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/developers-tools",
            number: 456
        ))
        let worktreePath = try shellAssignment(named: "review_worktree", in: script)

        XCTAssertTrue(script.contains("cd '\(root.path)'"))
        XCTAssertTrue(script.contains(
            "exact path `\(skillDirectory.path)/SKILL.md`"
        ))
        XCTAssertTrue(script.contains("--add-dir '\(worktreePath)'"))
        XCTAssertFalse(script.contains(
            "exact path `\(worktreePath)/.claude/skills/ndp-pr-review/SKILL.md`"
        ))
        XCTAssertTrue(script.contains(
            "Run relative `.agent` and `developers-tools` skill commands from `\(root.path)`"
        ))
    }

    func testCopilotDisablesWorkspaceMCPServersForDraftAndEdit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarMCPTests-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("frontend", isDirectory: true)
        let isolatedWorkingDirectory = root.appendingPathComponent(".agent/tmp", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: isolatedWorkingDirectory,
            withIntermediateDirectories: true
        )
        try """
        {
          "mcpServers": {
            "github": { "command": "github-mcp-server" },
            "atlassian": { "url": "https://example.invalid/mcp" }
          }
        }
        """.write(
            to: root.appendingPathComponent(".mcp.json"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".vscode", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        {
          "servers": {
            "chrome-devtools": { "command": "chrome-devtools-mcp" }
          }
        }
        """.write(
            to: repository.appendingPathComponent(".vscode/mcp.json"),
            atomically: true,
            encoding: .utf8
        )

        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "acme/frontend",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .copilot,
                        workspacePathTemplate: root.path,
                        promptRootPathTemplate: root.path,
                        promptTemplate: "/ndp-pr-review"
                    )),
                    cloudReview: .disabled
                )
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertEqual(script.components(separatedBy: "--disable-builtin-mcps").count - 1, 2)
        XCTAssertEqual(script.components(separatedBy: "--disable-mcp-server 'atlassian'").count - 1, 2)
        XCTAssertEqual(script.components(separatedBy: "--disable-mcp-server 'chrome-devtools'").count - 1, 2)
        XCTAssertEqual(script.components(separatedBy: "--disable-mcp-server 'github'").count - 1, 2)
        XCTAssertEqual(script.components(separatedBy: "-C '\(isolatedWorkingDirectory.path)'").count - 1, 2)
        XCTAssertTrue(script.contains("Use the local repository checkout at `\(repository.path)`"))
        XCTAssertTrue(script.contains("starts in the isolated directory `\(isolatedWorkingDirectory.path)`"))
        XCTAssertTrue(script.contains("Run relative `.agent` and `developers-tools` skill commands from `\(root.path)`"))
        XCTAssertTrue(script.contains("Do not inspect user-level credential or configuration files"))
        XCTAssertTrue(script.contains("do not search the machine for tools or repositories"))
        XCTAssertTrue(script.contains("skip it and continue with local repository and GitHub CLI evidence"))
    }

    func testCopilotWorkspaceSkillUsesCanonicalTargetForSymlinkedSkill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarSkillTests-\(UUID().uuidString)", isDirectory: true)
        let projectSkills = root
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        let canonicalSkill = root
            .appendingPathComponent("developers-tools", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("ndp-pr-review", isDirectory: true)

        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: projectSkills,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: canonicalSkill,
            withIntermediateDirectories: true
        )
        try "# Test skill".write(
            to: canonicalSkill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            atPath: projectSkills.appendingPathComponent("ndp-pr-review").path,
            withDestinationPath: "../../developers-tools/agents/skills/ndp-pr-review"
        )

        let launcher = PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "acme/frontend",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .copilot,
                        workspacePathTemplate: root.path,
                        promptTemplate: "/ndp-pr-review"
                    )),
                    cloudReview: .disabled
                )
            ]
        ))

        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains(
            "exact path `\(canonicalSkill.appendingPathComponent("SKILL.md").path)`"
        ))
        XCTAssertFalse(script.contains(
            "exact path `\(projectSkills.appendingPathComponent("ndp-pr-review/SKILL.md").path)`"
        ))
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
                terminal: .ghostty,
                globalPrompt: "Review this pull request",
                repositoryPromptOverrides: [:]
            ),
            runner: runner,
            scriptDirectory: scriptDirectory,
            terminalApplications: [.ghostty: "/Applications/Ghostty.app"]
        )
        let pullRequest = samplePullRequest(
            repository: "acme/frontend",
            number: 4264,
            title: "Fix custom ROI ghost labels"
        )

        defer { try? FileManager.default.removeItem(at: scriptDirectory) }

        try await launcher.launchReview(for: pullRequest)

        XCTAssertEqual(runner.invocations.map(\.executable), ["/bin/zsh", "/usr/bin/open"])
        let arguments = try XCTUnwrap(runner.invocations.last?.arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), ["-na", "/Applications/Ghostty.app", "--args"])
        let initialCommand = try XCTUnwrap(arguments.dropFirst(3).first)
        XCTAssertTrue(initialCommand.hasPrefix("--initial-command=/bin/zsh '"))
        XCTAssertTrue(initialCommand.hasSuffix(".command'"))
        XCTAssertEqual(arguments.last, "--working-directory=/Users/example/acme")
        let scriptPath = String(
            initialCommand
                .dropFirst("--initial-command=/bin/zsh '".count)
                .dropLast()
        )
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

    func testCmuxCreatesWorkspaceWithZshAsInitialCommand() async throws {
        let runner = CapturingProcessRunner()
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarTests-\(UUID().uuidString)", isDirectory: true)
        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme",
                terminal: .cmux
            ),
            runner: runner,
            scriptDirectory: scriptDirectory,
            terminalApplications: [.cmux: "/Applications/cmux.app"]
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }

        try await launcher.launchReview(for: samplePullRequest(repository: "acme/frontend", number: 42))

        XCTAssertEqual(runner.invocations.map(\.executable), [
            "/bin/zsh",
            "/usr/bin/open",
            "/Applications/cmux.app/Contents/Resources/bin/cmux"
        ])
        XCTAssertEqual(runner.invocations[1].arguments, ["-a", "/Applications/cmux.app"])
        let arguments = runner.invocations[2].arguments
        XCTAssertEqual(Array(arguments.prefix(4)), [
            "new-workspace", "--cwd", "/Users/example/acme", "--command"
        ])
        XCTAssertTrue(arguments.last?.hasPrefix("/bin/zsh '") == true)
        XCTAssertTrue(arguments.last?.hasSuffix(".command'") == true)
    }

    func testAppleTerminalUsesTemporaryProfileWithZshAsTheShellProcess() async throws {
        let runner = CapturingProcessRunner(results: [
            ProcessResult(
                stdout: "AGENT=/opt/homebrew/bin/copilot\nGH=/opt/homebrew/bin/gh\n",
                stderr: "",
                exitCode: 0
            ),
            ProcessResult(stdout: "", stderr: "", exitCode: 0)
        ])
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarTests-\(UUID().uuidString)", isDirectory: true)
        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme",
                terminal: .appleTerminal,
                appleTerminalProfile: "Review Zsh",
                agentTool: .copilot
            ),
            runner: runner,
            scriptDirectory: scriptDirectory,
            terminalApplications: [:]
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }

        try await launcher.launchReview(for: samplePullRequest(repository: "acme/frontend", number: 42))

        XCTAssertEqual(runner.invocations.map(\.executable), ["/bin/zsh", "/usr/bin/open"])
        XCTAssertEqual(runner.invocations[0].arguments.first, "-lc")
        XCTAssertTrue(runner.invocations[0].arguments.last?.contains("command -v -- copilot") == true)
        XCTAssertTrue(runner.invocations[0].arguments.last?.contains("command -v -- gh") == true)
        let arguments = runner.invocations[1].arguments
        XCTAssertEqual(Array(arguments.prefix(2)), ["-a", "Terminal"])
        let profileURL = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
        XCTAssertEqual(profileURL.pathExtension, "terminal")

        let profileData = try Data(contentsOf: profileURL)
        let profile = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: profileData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(profile["name"] as? String, "Review Zsh")
        XCTAssertEqual(profile["RunCommandAsShell"] as? Bool, true)
        XCTAssertEqual(profile["type"] as? String, "Window Settings")
        let command = try XCTUnwrap(profile["CommandString"] as? String)
        XCTAssertTrue(command.hasSuffix(".command"))
        XCTAssertFalse(command.contains("'"))
        XCTAssertFalse(command.contains("\""))
        XCTAssertFalse(command.contains("fish"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: command))
        let script = try String(contentsOfFile: command, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(script.contains("export PATH='/opt/homebrew/bin':\"$PATH\""))
        XCTAssertTrue(script.contains("'/opt/homebrew/bin/copilot' "))
        XCTAssertFalse(script.contains("--add-dir '/opt/homebrew/bin'"))
        XCTAssertTrue(script.contains("GitHub CLI is already available as `gh` on PATH."))
        XCTAssertTrue(script.contains("Invoke it as `gh`; do not use or search for an absolute executable path."))
        XCTAssertFalse(script.contains("GitHub CLI is installed at the exact path `/opt/homebrew/bin/gh`"))
        XCTAssertFalse(script.contains("--allow-all-paths"))
        XCTAssertFalse(script.contains("command -v -- copilot"))
        XCTAssertFalse(script.contains("\ncopilot "))

        let syntaxResult = try await DefaultProcessRunner().run(
            executable: "/bin/zsh",
            arguments: ["-n", command]
        )
        XCTAssertEqual(syntaxResult.exitCode, 0, syntaxResult.stderr)
    }

    func testCustomTerminalRendersArgumentPlaceholdersWithoutShellInterpolation() async throws {
        let runner = CapturingProcessRunner()
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarTests-\(UUID().uuidString)", isDirectory: true)
        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme",
                terminal: .custom,
                customTerminalExecutable: "/opt/example/bin/terminal",
                customTerminalArguments: "--new-window\n-e\n{shell}\n{script}\n--cwd={workspace}"
            ),
            runner: runner,
            scriptDirectory: scriptDirectory,
            terminalApplications: [:]
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }

        try await launcher.launchReview(for: samplePullRequest(repository: "acme/frontend", number: 42))

        XCTAssertEqual(runner.invocations.last?.executable, "/opt/example/bin/terminal")
        let arguments = try XCTUnwrap(runner.invocations.last?.arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), ["--new-window", "-e", "/bin/zsh"])
        XCTAssertTrue(arguments[3].hasSuffix(".command"))
        XCTAssertEqual(arguments[4], "--cwd=/Users/example/acme")
    }

    func testAutomaticTerminalDoesNotFallBackToDefaultLoginShell() async {
        let runner = CapturingProcessRunner()
        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "acme/frontend",
                workspacePath: "/Users/example/acme",
                terminal: .automatic
            ),
            runner: runner,
            terminalApplications: [:]
        )

        do {
            try await launcher.launchReview(for: samplePullRequest(repository: "acme/frontend", number: 42))
            XCTFail("Expected missing direct-zsh terminal to throw")
        } catch let error as PullRequestAgentReviewLauncher.Error {
            XCTAssertEqual(
                error,
                .terminalUnavailable(
                    terminal: "Automatic",
                    details: "Install Ghostty or cmux, or choose Apple Terminal."
                )
            )
            XCTAssertFalse(runner.invocations.contains { $0.executable == "/usr/bin/osascript" })
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

        XCTAssertEqual(runner.invocations.first?.arguments.first, "-lc")
        XCTAssertTrue(runner.invocations.first?.arguments.last?.contains("command -v -- codex") == true)
        XCTAssertTrue(runner.invocations.first?.arguments.last?.contains("command -v -- gh") == true)
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
                workspacePath: "/Users/example/acme",
                terminal: .ghostty
            ),
            runner: runner,
            terminalApplications: [.ghostty: "/Applications/Ghostty.app"]
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
                    message: "Could not open Ghostty for the Claude Code review: Application isn't running",
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

    func testGeneratedWorktreeScriptsHaveValidZshSyntaxForEveryAgent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarWorktreeSyntaxTests-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("frontend", isDirectory: true)
        let worktreeRoot = root.appendingPathComponent("worktrees", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        for agentTool in AgentReviewTool.allCases {
            let script = worktreeLauncher(
                repository: repository,
                worktreeRoot: worktreeRoot,
                agentTool: agentTool
            ).terminalCommandScript(for: samplePullRequest(
                repository: "acme/frontend",
                number: 42,
                title: "Handle apostrophe's quoting"
            ))
            let scriptURL = root.appendingPathComponent("\(agentTool.rawValue).zsh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            let result = try await DefaultProcessRunner().run(
                executable: "/bin/zsh",
                arguments: ["-n", scriptURL.path]
            )

            XCTAssertEqual(
                result.exitCode,
                0,
                "\(agentTool.displayName) worktree script failed zsh syntax validation: \(result.stderr)"
            )
        }
    }

    func testScopedWorkflowWrapsReviewInExactHeadWorktreeLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarWorktreeScriptTests-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("frontend", isDirectory: true)
        let worktreeRoot = root.appendingPathComponent("review-worktrees", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        let launcher = worktreeLauncher(
            repository: repository,
            worktreeRoot: worktreeRoot,
            agentTool: .claudeCode
        )
        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))

        XCTAssertTrue(script.contains("review_source_repository='\(repository.path)'"))
        XCTAssertTrue(script.contains("review_worktree='\(worktreeRoot.path)/frontend-pr42-"))
        XCTAssertTrue(script.contains("trap cleanup_review_worktree EXIT HUP INT TERM"))
        XCTAssertTrue(script.contains("gh pr view 'https://github.com/acme/frontend/pull/42' --json headRefOid --jq '.headRefOid'"))
        XCTAssertTrue(script.contains("fetch --no-tags origin 'pull/42/head'"))
        XCTAssertTrue(script.contains("worktree add --detach \"$review_worktree\" \"$review_head\""))
        XCTAssertTrue(script.contains("worktree remove --force \"$review_worktree\""))
        XCTAssertTrue(script.contains("The original checkout at `\(repository.path)` must remain unchanged."))
        XCTAssertTrue(script.contains("Do not run `git checkout`, `git switch`, `gh pr checkout`, or create another worktree."))
    }

    func testWorktreeReviewRunsAtPRHeadLeavesSourceBranchUntouchedAndCleansUp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarWorktreeLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("frontend", isDirectory: true)
        let remote = root.appendingPathComponent("frontend.git", isDirectory: true)
        let worktreeRoot = root.appendingPathComponent("review-worktrees", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let agentLog = root.appendingPathComponent("agent.log", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try runGit(["init", "--bare", remote.path], in: root)
        try runGit(["init", "-b", "main"], in: repository)
        try runGit(["config", "user.name", "GHMenuBar Tests"], in: repository)
        try runGit(["config", "user.email", "tests@example.invalid"], in: repository)
        try "base\n".write(
            to: repository.appendingPathComponent("review.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "review.txt"], in: repository)
        try runGit(["commit", "-m", "base"], in: repository)
        try runGit(["remote", "add", "origin", remote.path], in: repository)
        try runGit(["push", "-u", "origin", "main"], in: repository)
        try runGit(["switch", "-c", "feature"], in: repository)
        try "pull request\n".write(
            to: repository.appendingPathComponent("review.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["commit", "-am", "pull request"], in: repository)
        let pullRequestHead = try runGit(["rev-parse", "HEAD"], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["push", "origin", "HEAD:refs/pull/42/head"], in: repository)
        try runGit(["switch", "main"], in: repository)
        let sourceHead = try runGit(["rev-parse", "HEAD"], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try writeExecutable(
            """
            #!/bin/zsh
            print -r -- '\(pullRequestHead)'
            """,
            to: bin.appendingPathComponent("gh", isDirectory: false)
        )
        try writeExecutable(
            """
            #!/bin/zsh
            print -r -- "$PWD" > "$GHMENUBAR_TEST_AGENT_LOG"
            [[ "$(< review.txt)" == "pull request" ]] || exit 9
            print -r -- 'disposable agent output' > review-agent.tmp
            """,
            to: bin.appendingPathComponent("claude", isDirectory: false)
        )

        let launcher = worktreeLauncher(
            repository: repository,
            worktreeRoot: worktreeRoot,
            agentTool: .claudeCode
        )
        let script = launcher.terminalCommandScript(for: samplePullRequest(
            repository: "acme/frontend",
            number: 42
        ))
        let worktreePath = try shellAssignment(named: "review_worktree", in: script)
        let result = try runGeneratedScript(
            script,
            environment: [
                "PATH": "\(bin.path):/usr/bin:/bin",
                "GHMENUBAR_TEST_AGENT_LOG": agentLog.path
            ]
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: agentLog, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            worktreePath
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
        XCTAssertEqual(
            try runGit(["branch", "--show-current"], in: repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "main"
        )
        XCTAssertEqual(
            try runGit(["rev-parse", "HEAD"], in: repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            sourceHead
        )
        XCTAssertTrue(result.output.contains("Cleaning up isolated review worktree..."))
        XCTAssertTrue(result.output.contains("Removed \(worktreePath)"))
        XCTAssertFalse(
            try runGit(["worktree", "list", "--porcelain"], in: repository)
                .contains(worktreePath)
        )
    }

    private func worktreeLauncher(
        repository: URL,
        worktreeRoot: URL,
        agentTool: AgentReviewTool
    ) -> PullRequestAgentReviewLauncher {
        PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "acme/frontend",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: agentTool,
                        workspacePathTemplate: repository.path,
                        worktreeRootPathTemplate: worktreeRoot.path,
                        promptTemplate: "/review {pr} {workspacePath}"
                    )),
                    cloudReview: .disabled
                )
            ]
        ))
    }

    private func shellAssignment(named name: String, in script: String) throws -> String {
        let marker = "\(name)='"
        let markerRange = try XCTUnwrap(script.range(of: marker))
        let remainder = script[markerRange.upperBound...]
        let closingQuote = try XCTUnwrap(remainder.firstIndex(of: "'"))
        return String(remainder[..<closingQuote])
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let outputString = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PullRequestAgentReviewLauncherTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: outputString]
            )
        }
        return outputString
    }

    private func runGeneratedScript(
        _ script: String,
        environment: [String: String]
    ) throws -> (exitCode: Int32, output: String) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarWorktree-\(UUID().uuidString).command", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try writeExecutable(script, to: scriptURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, configured in
            configured
        }
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
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

        XCTAssertEqual(runner.invocations.first?.arguments.first, "-lc")
        XCTAssertTrue(runner.invocations.first?.arguments.last?.contains("command -v -- \(commandName)") == true)
        XCTAssertTrue(runner.invocations.first?.arguments.last?.contains("command -v -- gh") == true)
        let script = try launchedScript(from: runner)
        XCTAssertTrue(script.contains("cd '/Users/example/acme'"))
        XCTAssertTrue(script.contains(expectedCommand))
        XCTAssertTrue(script.contains("/frontend-code-review PR #42 /Users/example/acme/frontend"))
        XCTAssertTrue(script.contains("Repo: acme/frontend"))
        XCTAssertTrue(script.contains("Title: Preserve profile context"))
    }

    private struct CopilotGateFixture {
        let root: URL
        let bin: URL
        let copilotLog: URL
        let githubLog: URL
        let launcher: PullRequestAgentReviewLauncher
        let pullRequest: PullRequest
    }

    private func makeCopilotGateFixture(currentHead: String = String(repeating: "a", count: 40)) throws -> CopilotGateFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarApprovalGateTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let repository = root.appendingPathComponent("frontend", isDirectory: true)
        let isolatedWorkingDirectory = root.appendingPathComponent(".agent/tmp", isDirectory: true)
        let copilotLog = root.appendingPathComponent("copilot.log", isDirectory: false)
        let githubLog = root.appendingPathComponent("github.log", isDirectory: false)

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: isolatedWorkingDirectory,
            withIntermediateDirectories: true
        )

        try writeExecutable(
            """
            #!/bin/zsh
            print -r -- 'invoked' >> "$GHMENUBAR_TEST_COPILOT_LOG"
            exit 0
            """,
            to: bin.appendingPathComponent("copilot", isDirectory: false)
        )
        try writeExecutable(
            """
            #!/bin/zsh
            if [[ "$1" == "pr" && "$2" == "view" ]]; then
              print -r -- '\(currentHead)'
              exit 0
            fi
            print -r -- "$*" >> "$GHMENUBAR_TEST_GITHUB_LOG"
            print -r -- '12345'
            """,
            to: bin.appendingPathComponent("gh", isDirectory: false)
        )

        let launcher = PullRequestAgentReviewLauncher(
            settings: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "",
                workspacePath: "",
                agentTool: .copilot,
                reviewScopes: [
                    AgentReviewScope(
                        pattern: "acme/frontend",
                        localReview: .override(AgentReviewLocalWorkflow(
                            agentTool: .copilot,
                            workspacePathTemplate: root.path,
                            promptRootPathTemplate: root.path,
                            promptTemplate: "/ndp-pr-review"
                        )),
                        cloudReview: .disabled
                    )
                ]
            ),
            scriptDirectory: root.appendingPathComponent("launcher", isDirectory: true)
        )

        return CopilotGateFixture(
            root: root,
            bin: bin,
            copilotLog: copilotLog,
            githubLog: githubLog,
            launcher: launcher,
            pullRequest: samplePullRequest(repository: "acme/frontend", number: 42)
        )
    }

    private func reviewPayloadURL(from script: String) throws -> URL {
        let marker = "review_payload='"
        let markerRange = try XCTUnwrap(script.range(of: marker))
        let remainder = script[markerRange.upperBound...]
        let closingQuote = try XCTUnwrap(remainder.firstIndex(of: "'"))
        return URL(fileURLWithPath: String(remainder[..<closingQuote]), isDirectory: false)
    }

    private func reviewPayload(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeValidReviewPayload(to url: URL) throws {
        try """
        {
          "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "body": "LGTM",
          "event": "APPROVE",
          "comments": []
        }
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func runGeneratedScript(
        _ script: String,
        input: String,
        fixture: CopilotGateFixture
    ) throws -> (exitCode: Int32, output: String) {
        let scriptURL = fixture.root.appendingPathComponent("review.command", isDirectory: false)
        try writeExecutable(script, to: scriptURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(fixture.bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["GHMENUBAR_TEST_COPILOT_LOG"] = fixture.copilotLog.path
        environment["GHMENUBAR_TEST_GITHUB_LOG"] = fixture.githubLog.path
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data(input.utf8))
        try inputPipe.fileHandleForWriting.close()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    private func invocationCount(at url: URL) throws -> Int {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(whereSeparator: \.isNewline).count
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
                terminal: .ghostty,
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
            scriptDirectory: scriptDirectory,
            terminalApplications: [.ghostty: "/Applications/Ghostty.app"]
        )
    }

    private func launchedScript(from runner: CapturingProcessRunner) throws -> String {
        let arguments = try XCTUnwrap(runner.invocations.last?.arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), ["-na", "/Applications/Ghostty.app", "--args"])
        let initialCommand = try XCTUnwrap(arguments.dropFirst(3).first)
        XCTAssertTrue(initialCommand.hasPrefix("--initial-command=/bin/zsh '"))
        XCTAssertTrue(initialCommand.hasSuffix(".command'"))
        let scriptPath = String(
            initialCommand
                .dropFirst("--initial-command=/bin/zsh '".count)
                .dropLast()
        )
        return try String(
            contentsOfFile: scriptPath,
            encoding: .utf8
        )
    }

    private func launcherWithModel(
        tool: AgentReviewTool,
        codexModel: String? = nil,
        claudeModel: String? = nil,
        copilotModel: String? = nil
    ) -> PullRequestAgentReviewLauncher {
        PullRequestAgentReviewLauncher(settings: AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "acme/frontend",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: tool,
                        codexModel: codexModel,
                        claudeModel: claudeModel,
                        copilotModel: copilotModel,
                        workspacePathTemplate: "/Users/example/acme/{repoName}",
                        promptTemplate: "/review {pr}"
                    )),
                    cloudReview: .disabled
                )
            ]
        ))
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
