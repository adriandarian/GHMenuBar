import Foundation

public struct PullRequestAgentReviewLauncher: Sendable {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case unsupportedRepository(String)
        case agentToolUnavailable(tool: String, command: String, details: String)
        case commandFailed(message: String, exitCode: Int32)
        case processFailed(message: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedRepository(let repository):
                return "Agent review is not configured for \(repository)."
            case .agentToolUnavailable(let tool, let command, let details):
                let suffix = details.isEmpty ? "" : " \(details)"
                return """
                \(tool) is not available in the shell used by GHMenuBar.\(suffix) \
                Install `\(command)` or update your shell PATH, then try again.
                """
            case .commandFailed(let message, _),
                 .processFailed(let message):
                return message
            }
        }
    }

    private let settings: AgentReviewSettings
    private let runner: ProcessRunning
    private let scriptDirectory: URL

    public init(
        settings: AgentReviewSettings = GHMenuBarSettings.default.agentReview,
        runner: ProcessRunning = DefaultProcessRunner(),
        scriptDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GHMenuBarAgentReviews",
            isDirectory: true
        )
    ) {
        self.settings = settings.sanitized()
        self.runner = runner
        self.scriptDirectory = scriptDirectory
    }

    public static func isSupported(pullRequest: PullRequest) -> Bool {
        PullRequestAgentReviewLauncher().isSupported(pullRequest: pullRequest)
    }

    public func isSupported(pullRequest: PullRequest) -> Bool {
        settings.isEnabled &&
            settings.reviewProfile(for: pullRequest.repository) != nil &&
            (settings.supportedRepository.isEmpty || pullRequest.repository == settings.supportedRepository)
    }

    public func launchReview(for pullRequest: PullRequest) async throws {
        let reviewProfile = settings.reviewProfile(for: pullRequest.repository)
        let configuredAgentTool = reviewProfile?.agentTool ?? settings.agentTool(for: pullRequest.repository)
        try await launchReview(for: pullRequest, using: configuredAgentTool)
    }

    public func launchReview(
        for pullRequest: PullRequest,
        using agentTool: AgentReviewTool
    ) async throws {
        guard isSupported(pullRequest: pullRequest) else {
            throw Error.unsupportedRepository(pullRequest.repository)
        }

        let commandName = Self.commandName(for: agentTool)
        let toolName = agentTool.displayName

        let availabilityResult: ProcessResult
        do {
            availabilityResult = try await runner.run(
                executable: "/bin/zsh",
                arguments: ["-lc", "command -v -- \(commandName) >/dev/null"]
            )
        } catch {
            throw Error.processFailed(
                message: "Could not verify that \(toolName) is installed: \(error.localizedDescription)"
            )
        }

        guard availabilityResult.exitCode == 0 else {
            throw Error.agentToolUnavailable(
                tool: toolName,
                command: commandName,
                details: Self.failureDetails(from: availabilityResult)
            )
        }

        let scriptURL: URL
        do {
            scriptURL = try writeCommandScript(
                for: pullRequest,
                using: agentTool,
                in: scriptDirectory
            )
        } catch {
            throw Error.processFailed(
                message: "Could not prepare the \(toolName) review command: \(error.localizedDescription)"
            )
        }

        let result: ProcessResult
        do {
            result = try await runner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-l", "JavaScript", "-e", Self.terminalLaunchJavaScript, scriptURL.path]
            )
        } catch {
            throw Error.processFailed(
                message: "Could not open Terminal for the \(toolName) review: \(error.localizedDescription)"
            )
        }

        guard result.exitCode == 0 else {
            let details = Self.failureDetails(from: result)
            throw Error.commandFailed(
                message: details.isEmpty
                    ? "Could not open Terminal for the \(toolName) review (status \(result.exitCode))."
                    : "Could not open Terminal for the \(toolName) review: \(details)",
                exitCode: result.exitCode
            )
        }
    }

    public static func terminalCommandScript(for pullRequest: PullRequest) -> String {
        PullRequestAgentReviewLauncher().terminalCommandScript(for: pullRequest)
    }

    public func terminalCommandScript(for pullRequest: PullRequest) -> String {
        let reviewProfile = settings.reviewProfile(for: pullRequest.repository)
        let configuredAgentTool = reviewProfile?.agentTool ?? settings.agentTool(for: pullRequest.repository)
        return terminalCommandScript(
            for: pullRequest,
            using: configuredAgentTool,
            reviewProfile: reviewProfile
        )
    }

    private func terminalCommandScript(
        for pullRequest: PullRequest,
        using agentTool: AgentReviewTool,
        reviewProfile: ResolvedAgentReviewProfile?
    ) -> String {
        let commandWorkspacePath = reviewProfile?.promptRootPath ?? reviewProfile?.workspacePath ?? settings.workspacePath
        return """
        #!/bin/zsh
        cd \(Self.shellQuoted(commandWorkspacePath)) || exit $?
        \(agentCommandScript(for: pullRequest, using: agentTool, reviewProfile: reviewProfile))

        """
    }

    public static func prompt(for pullRequest: PullRequest) -> String {
        PullRequestAgentReviewLauncher().prompt(for: pullRequest)
    }

    public func prompt(for pullRequest: PullRequest) -> String {
        prompt(for: pullRequest, reviewCommand: settings.promptInstruction(for: pullRequest.repository))
    }

    private func prompt(for pullRequest: PullRequest, reviewCommand: String) -> String {
        let reviewTarget = Self.pullRequestNumber(from: pullRequest.url)
            .map { "PR #\($0)" } ?? pullRequest.url.absoluteString

        return """
        \(reviewCommand) \(reviewTarget).

        Repository: \(pullRequest.repository)
        Title: \(pullRequest.title)
        URL: \(pullRequest.url.absoluteString)

        Do not submit the GitHub review until I explicitly approve the draft.
        """
    }

    private static func pullRequestNumber(from url: URL) -> Int? {
        url.pathComponents.reversed().lazy.compactMap(Int.init).first
    }

    private func writeCommandScript(
        for pullRequest: PullRequest,
        using agentTool: AgentReviewTool,
        in directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let scriptURL = directory.appendingPathComponent(
            "frontend-pr-review-\(UUID().uuidString).command"
        )
        let reviewProfile = settings.reviewProfile(for: pullRequest.repository)
        try terminalCommandScript(
            for: pullRequest,
            using: agentTool,
            reviewProfile: reviewProfile
        ).write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private func agentCommandScript(
        for pullRequest: PullRequest,
        using agentTool: AgentReviewTool,
        reviewProfile: ResolvedAgentReviewProfile?
    ) -> String {
        let reviewCommand = reviewProfile?.reviewCommand ?? settings.promptInstruction(for: pullRequest.repository)
        let prompt = settings.reviewScopes.isEmpty
            ? prompt(for: pullRequest, reviewCommand: reviewCommand)
            : renderedPromptTemplate(reviewCommand, for: pullRequest, reviewProfile: reviewProfile)
        let agentPrompt = agentTool == .copilot
            ? copilotCompatiblePrompt(prompt, for: pullRequest)
            : prompt
        let quotedPrompt = Self.shellQuoted(agentPrompt)
        let command: String
        switch agentTool {
        case .codexCLI:
            command = "codex \(additionalDirectoryArguments(for: reviewProfile))\(quotedPrompt)"
        case .claudeCode:
            command = "claude \(additionalDirectoryArguments(for: reviewProfile))\(quotedPrompt)"
        case .copilot:
            return copilotCommandScript(
                prompt: quotedPrompt,
                reviewProfile: reviewProfile
            )
        }

        return guardedCommandScript(
            command: command,
            commandName: Self.commandName(for: agentTool),
            toolName: agentTool.displayName
        )
    }

    private func additionalDirectoryArguments(for reviewProfile: ResolvedAgentReviewProfile?) -> String {
        guard let reviewProfile,
              let promptRootPath = reviewProfile.promptRootPath,
              promptRootPath != reviewProfile.workspacePath
        else {
            return ""
        }

        return "--add-dir \(Self.shellQuoted(reviewProfile.workspacePath)) "
    }

    private func copilotCommandScript(
        prompt: String,
        reviewProfile: ResolvedAgentReviewProfile?
    ) -> String {
        let workspacePath = reviewProfile?.workspacePath ?? settings.workspacePath
        let workspaceArguments = workspacePath.isEmpty
            ? ""
            : "--add-dir \(Self.shellQuoted(workspacePath)) "
        let draftCommand = """
        copilot \(workspaceArguments)--disable-builtin-mcps --allow-all-tools \
        --deny-tool 'write' \
        --deny-tool 'shell(gh pr review)' \
        --deny-tool 'shell(gh pr comment)' \
        --deny-tool 'shell(gh pr merge)' \
        --deny-tool 'shell(git push)' \
        --prompt \(prompt)
        """
        let resumeCommand = "copilot \(workspaceArguments)--continue"

        return """
        \(commandAvailabilityCheck(commandName: "copilot", toolName: AgentReviewTool.copilot.displayName))
        \(draftCommand)
        review_status=$?
        if (( review_status != 0 )); then
          print -u2 -- '\\nGitHub Copilot could not prepare the review draft (status '\"$review_status\"').'
          print -u2 -- 'The output above contains the original failure. Fix it, then launch the review again.'
          read -k 1 '?Press any key to close this window.'
          print
          exit "$review_status"
        fi
        print -- '\\nReview draft prepared. Continuing interactively so you can inspect it and explicitly approve any submission.'
        \(resumeCommand)
        review_status=$?
        if (( review_status != 0 )); then
          print -u2 -- '\\nGitHub Copilot could not resume the review session (status '\"$review_status\"').'
          print -u2 -- 'Run `copilot --continue` to retry the interactive approval step.'
          read -k 1 '?Press any key to close this window.'
          print
        fi
        exit "$review_status"
        """
    }

    private func copilotCompatiblePrompt(
        _ prompt: String,
        for pullRequest: PullRequest
    ) -> String {
        guard let skillName = Self.workspaceSkillName(from: prompt) else {
            return prompt
        }

        let reviewTarget = Self.pullRequestNumber(from: pullRequest.url)
            .map(String.init) ?? pullRequest.url.absoluteString

        return """
        You are explicitly invoking the workspace skill `/\(skillName)`.
        Before taking any other action, read and follow `.claude/skills/\(skillName)/SKILL.md`.

        Skill invocation: \(prompt)
        Target pull request: \(pullRequest.repository) \(reviewTarget)
        URL: \(pullRequest.url.absoluteString)
        """
    }

    private func guardedCommandScript(
        command: String,
        commandName: String,
        toolName: String
    ) -> String {
        """
        \(commandAvailabilityCheck(commandName: commandName, toolName: toolName))
        \(command)
        review_status=$?
        if (( review_status != 0 )); then
          print -u2 -- '\\n\(toolName) exited before completing the review (status '\"$review_status\"').'
          print -u2 -- 'The output above contains the original failure. Fix it, then launch the review again.'
          read -k 1 '?Press any key to close this window.'
          print
        fi
        exit "$review_status"
        """
    }

    private func commandAvailabilityCheck(commandName: String, toolName: String) -> String {
        """
        if ! command -v -- \(commandName) >/dev/null 2>&1; then
          print -u2 -- '\(toolName) was not found in this Terminal shell.'
          print -u2 -- 'Install \(commandName), or update your shell PATH, then launch the review again.'
          read -k 1 '?Press any key to close this window.'
          print
          exit 127
        fi
        """
    }

    private static func commandName(for tool: AgentReviewTool) -> String {
        switch tool {
        case .codexCLI:
            return "codex"
        case .claudeCode:
            return "claude"
        case .copilot:
            return "copilot"
        }
    }

    private static func workspaceSkillName(from prompt: String) -> String? {
        let command = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first

        guard let command,
              command.first == "/"
        else {
            return nil
        }

        let skillName = command.dropFirst()
        guard !skillName.isEmpty,
              skillName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else {
            return nil
        }

        return String(skillName)
    }

    private static let terminalLaunchJavaScript = """
    function run(argv) {
        if (argv.length !== 1) {
            throw new Error("Expected one review-script path.");
        }

        const terminal = Application("Terminal");
        const reviewTab = terminal.doScript("");
        const promptPattern = /(?:^|\\n)[^\\n]*[>$%#❯] ?\\s*$/u;
        const commandToRun = "/bin/zsh '" + argv[0].replace(/'/g, "'\\\\''") + "'";

        terminal.activate();
        for (let attempt = 0; attempt < 300; attempt++) {
            if (promptPattern.test(reviewTab.contents())) {
                terminal.doScript(commandToRun, { in: reviewTab });
                return;
            }
            delay(0.1);
        }
        throw new Error("Terminal did not show a shell prompt within 30 seconds.");
    }
    """

    private static func failureDetails(from result: ProcessResult) -> String {
        [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func renderedPromptTemplate(
        _ template: String,
        for pullRequest: PullRequest,
        reviewProfile: ResolvedAgentReviewProfile?
    ) -> String {
        let reviewTarget = Self.pullRequestNumber(from: pullRequest.url)
            .map { "PR #\($0)" } ?? pullRequest.url.absoluteString

        return template
            .replacingOccurrences(of: "{pr}", with: reviewTarget)
            .replacingOccurrences(of: "{repo}", with: pullRequest.repository)
            .replacingOccurrences(of: "{repoName}", with: Self.repositoryName(from: pullRequest.repository))
            .replacingOccurrences(of: "{workspace}", with: reviewProfile?.workspacePath ?? "")
            .replacingOccurrences(of: "{workspacePath}", with: reviewProfile?.workspacePath ?? "")
            .replacingOccurrences(of: "{promptRoot}", with: reviewProfile?.promptRootPath ?? "")
            .replacingOccurrences(of: "{promptRootPath}", with: reviewProfile?.promptRootPath ?? "")
            .replacingOccurrences(of: "{title}", with: pullRequest.title)
            .replacingOccurrences(of: "{url}", with: pullRequest.url.absoluteString)
    }

    private static func repositoryName(from repository: String) -> String {
        repository.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repository
    }
}
