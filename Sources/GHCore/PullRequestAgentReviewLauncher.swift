import Foundation

public struct PullRequestAgentReviewLauncher: Sendable {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case unsupportedRepository(String)
        case agentToolUnavailable(tool: String, command: String, details: String)
        case worktreeUnavailable(repository: String, details: String)
        case terminalUnavailable(terminal: String, details: String)
        case terminalMisconfigured(terminal: String, details: String)
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
            case .worktreeUnavailable(let repository, let details):
                return "Could not prepare an isolated review worktree for \(repository). \(details)"
            case .terminalUnavailable(let terminal, let details):
                return "\(terminal) is not available for Agent Review. \(details)"
            case .terminalMisconfigured(let terminal, let details):
                return "\(terminal) is not configured for Agent Review. \(details)"
            case .commandFailed(let message, _),
                 .processFailed(let message):
                return message
            }
        }
    }

    private let settings: AgentReviewSettings
    private let runner: ProcessRunning
    private let scriptDirectory: URL
    private let terminalApplications: [AgentReviewTerminal: String]

    private struct ReviewWorktree {
        let sourceRepositoryPath: String
        let path: String
    }

    public init(
        settings: AgentReviewSettings = GHMenuBarSettings.default.agentReview,
        runner: ProcessRunning = DefaultProcessRunner(),
        scriptDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GHMenuBarAgentReviews",
            isDirectory: true
        ),
        terminalApplications: [AgentReviewTerminal: String]? = nil
    ) {
        self.settings = settings.sanitized()
        self.runner = runner
        self.scriptDirectory = scriptDirectory
        self.terminalApplications = terminalApplications ?? Self.detectedTerminalApplications()
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
                arguments: ["-lc", Self.executableResolutionCommand(for: commandName)]
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

        let resolvedExecutables = availabilityResult.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let agentExecutable = resolvedExecutables
            .first(where: { $0.hasPrefix("AGENT=/") })
            .map { String($0.dropFirst("AGENT=".count)) } ?? commandName
        let githubCLIExecutable = resolvedExecutables
            .first(where: { $0.hasPrefix("GH=/") })
            .map { String($0.dropFirst("GH=".count)) }

        let reviewProfile = settings.reviewProfile(for: pullRequest.repository)

        if settings.localReviewWorkflow(for: pullRequest.repository)?.worktreeRootPathTemplate != nil {
            guard githubCLIExecutable != nil else {
                throw Error.worktreeUnavailable(
                    repository: pullRequest.repository,
                    details: "GitHub CLI is required to resolve the exact pull-request head."
                )
            }
            guard reviewWorktree(for: pullRequest, reviewProfile: reviewProfile) != nil else {
                throw Error.worktreeUnavailable(
                    repository: pullRequest.repository,
                    details: "The configured Workspace must resolve to an existing checkout, and the worktree root must be an absolute or ~/ path outside that checkout."
                )
            }
        }

        let scriptURL: URL
        do {
            scriptURL = try writeCommandScript(
                for: pullRequest,
                using: agentTool,
                agentExecutable: agentExecutable,
                githubCLIExecutable: githubCLIExecutable,
                in: scriptDirectory
            )
        } catch {
            throw Error.processFailed(
                message: "Could not prepare the \(toolName) review command: \(error.localizedDescription)"
            )
        }

        let workspacePath = reviewProfile?.promptRootPath
            ?? reviewProfile?.workspacePath
            ?? settings.workspacePath
        try await launchTerminal(
            scriptURL: scriptURL,
            workspacePath: workspacePath,
            toolName: toolName
        )
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
        reviewProfile: ResolvedAgentReviewProfile?,
        agentExecutable: String? = nil,
        githubCLIExecutable: String? = nil,
        copilotWorkingDirectory: String? = nil
    ) -> String {
        let reviewWorktree = reviewWorktree(for: pullRequest, reviewProfile: reviewProfile)
        let commandReviewProfile = reviewProfileForAgentCommand(
            reviewProfile,
            reviewWorktree: reviewWorktree
        )
        let initialWorkspacePath = reviewProfile?.promptRootPath
            ?? reviewProfile?.workspacePath
            ?? settings.workspacePath
        let commandWorkspacePath = commandReviewProfile?.promptRootPath
            ?? commandReviewProfile?.workspacePath
            ?? settings.workspacePath
        let resolvedCopilotWorkingDirectory = copilotWorkingDirectory
            ?? isolatedCopilotWorkingDirectory(for: commandReviewProfile)
        let reviewDraftPath = reviewDraftPath(
            for: pullRequest,
            copilotWorkingDirectory: resolvedCopilotWorkingDirectory
        )
        let githubCLIPathSetup = githubCLIExecutable.map { executable in
            let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            return "export PATH=\(Self.shellQuoted(directory)):\"$PATH\"\n"
        } ?? ""
        let worktreeSetup = reviewWorktree.map {
            reviewWorktreeSetupScript(
                $0,
                for: pullRequest,
                githubCLIExecutable: githubCLIExecutable
            ) + "\n"
        } ?? ""
        let commandWorkspaceSetup = reviewWorktree == nil
            ? ""
            : "cd \(Self.shellQuoted(commandWorkspacePath)) || exit $?\n"
        return """
        #!/bin/zsh
        cd \(Self.shellQuoted(initialWorkspacePath)) || exit $?
        \(githubCLIPathSetup)\
        \(worktreeSetup)\
        \(commandWorkspaceSetup)\
        \(agentCommandScript(
            for: pullRequest,
            using: agentTool,
            reviewProfile: commandReviewProfile,
            reviewWorktree: reviewWorktree,
            agentExecutable: agentExecutable ?? Self.commandName(for: agentTool),
            githubCLIExecutable: githubCLIExecutable,
            copilotWorkingDirectory: resolvedCopilotWorkingDirectory,
            reviewDraftPath: reviewDraftPath
        ))

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
        agentExecutable: String,
        githubCLIExecutable: String?,
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
            reviewProfile: reviewProfile,
            agentExecutable: agentExecutable,
            githubCLIExecutable: githubCLIExecutable,
            copilotWorkingDirectory: isolatedCopilotWorkingDirectory(for: reviewProfile)
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
        reviewProfile: ResolvedAgentReviewProfile?,
        reviewWorktree: ReviewWorktree?,
        agentExecutable: String,
        githubCLIExecutable: String?,
        copilotWorkingDirectory: String?,
        reviewDraftPath: String
    ) -> String {
        let reviewCommand = reviewProfile?.reviewCommand ?? settings.promptInstruction(for: pullRequest.repository)
        let basePrompt = settings.reviewScopes.isEmpty
            ? prompt(for: pullRequest, reviewCommand: reviewCommand)
            : renderedPromptTemplate(reviewCommand, for: pullRequest, reviewProfile: reviewProfile)
        let prompt = reviewWorktree.map {
            worktreeReviewPrompt(basePrompt, reviewWorktree: $0)
        } ?? basePrompt
        let approvalCelebration = ApprovalCelebration.random()
        let agentPrompt = agentTool == .copilot
            ? copilotCompatiblePrompt(
                prompt,
                for: pullRequest,
                reviewProfile: reviewProfile,
                githubCLIExecutable: githubCLIExecutable,
                reviewDraftPath: reviewDraftPath,
                approvalCelebration: approvalCelebration
            )
            : prompt
        let quotedPrompt = Self.shellQuoted(agentPrompt)
        let modelArgument = modelArgument(for: agentTool, repository: pullRequest.repository)
        let executableCommand = agentExecutable.hasPrefix("/")
            ? Self.shellQuoted(agentExecutable)
            : agentExecutable
        let command: String
        switch agentTool {
        case .codexCLI:
            command = "\(executableCommand) \(modelArgument)\(additionalDirectoryArguments(for: reviewProfile))\(quotedPrompt)"
        case .claudeCode:
            command = "\(executableCommand) \(modelArgument)\(additionalDirectoryArguments(for: reviewProfile))\(quotedPrompt)"
        case .copilot:
            return copilotCommandScript(
                prompt: quotedPrompt,
                reviewProfile: reviewProfile,
                modelArgument: modelArgument,
                agentExecutable: agentExecutable,
                executableCommand: executableCommand,
                githubCLIExecutable: githubCLIExecutable,
                copilotWorkingDirectory: copilotWorkingDirectory,
                reviewDraftPath: reviewDraftPath,
                approvalCelebration: approvalCelebration,
                pullRequest: pullRequest
            )
        }

        return guardedCommandScript(
            command: command,
            commandName: Self.commandName(for: agentTool),
            toolName: agentTool.displayName,
            agentExecutable: agentExecutable
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

    private func modelArgument(for agentTool: AgentReviewTool, repository: String) -> String {
        guard let model = settings.localReviewWorkflow(for: repository)?.model(for: agentTool) else {
            return ""
        }
        return "--model \(Self.shellQuoted(model)) "
    }

    private func copilotCommandScript(
        prompt: String,
        reviewProfile: ResolvedAgentReviewProfile?,
        modelArgument: String,
        agentExecutable: String,
        executableCommand: String,
        githubCLIExecutable: String?,
        copilotWorkingDirectory: String?,
        reviewDraftPath: String,
        approvalCelebration: ApprovalCelebration,
        pullRequest: PullRequest
    ) -> String {
        let workspacePath = reviewProfile?.workspacePath ?? settings.workspacePath
        let allowedWorkspacePaths = [
            workspacePath,
            reviewProfile?.promptRootPath
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let workspaceArguments = allowedWorkspacePaths
            .reduce(into: [String]()) { paths, path in
                guard !paths.contains(path) else { return }
                paths.append(path)
            }
            .map { "--add-dir \(Self.shellQuoted($0)) " }
            .joined()
        let workingDirectoryArgument = copilotWorkingDirectory.map {
            "-C \(Self.shellQuoted($0)) "
        } ?? ""
        let disabledMCPArguments = disabledMCPServerArguments(
            for: reviewProfile,
            pullRequest: pullRequest
        )
        let postingDenials = copilotPostingDenialArguments(
            githubCLIExecutable: githubCLIExecutable,
            reviewProfile: reviewProfile
        )
        let draftCommand = """
        \(executableCommand) \(workingDirectoryArgument)\(workspaceArguments)\(modelArgument)--disable-builtin-mcps \(disabledMCPArguments)--allow-all-tools \
        --deny-tool 'write' \
        \(postingDenials)\
        --prompt \(prompt)
        """
        let editCommand = """
        \(executableCommand) \(workingDirectoryArgument)\(workspaceArguments)\(modelArgument)--disable-builtin-mcps \
        \(disabledMCPArguments)\(postingDenials)--continue
        """
        let githubCommand = githubCLIExecutable.map(Self.shellQuoted) ?? "gh"
        let reviewNumber = Self.pullRequestNumber(from: pullRequest.url).map(String.init) ?? ""
        let reviewEndpoint = "repos/\(pullRequest.repository)/pulls/\(reviewNumber)/reviews"

        return """
        \(commandAvailabilityCheck(
            agentExecutable: agentExecutable,
            commandName: "copilot",
            toolName: AgentReviewTool.copilot.displayName
        ))
        review_payload=\(Self.shellQuoted(reviewDraftPath))
        approval_celebration=\(Self.shellQuoted(approvalCelebration.markdown))
        \(draftCommand)
        review_status=$?
        if (( review_status != 0 )) && [[ ! -s "$review_payload" ]]; then
          print -u2 -- '\\nGitHub Copilot could not prepare the review draft (status '"$review_status"').'
          print -u2 -- 'The output above contains the original failure. Fix it, then launch the review again.'
          read -k 1 '?Press any key to close this window.'
          print
          exit "$review_status"
        fi
        if (( review_status != 0 )); then
          print -u2 -- '\\nGitHub Copilot reported a failure after saving the draft. Nothing was submitted; review the draft below.'
        fi

        if [[ ! -s "$review_payload" ]]; then
          print -u2 -- '\\nGitHub Copilot finished without saving the required review draft.'
          print -u2 -- 'Nothing was submitted. Launch the review again.'
          read -k 1 '?Press any key to close this window.'
          print
          exit 1
        fi

        validate_review_payload() {
          python3 - "$review_payload" "$approval_celebration" <<'PY'
        import json
        import os
        import re
        import sys

        payload_path = sys.argv[1]
        approval_celebration = sys.argv[2]
        celebration_start = "<!-- ghmenubar-approval-celebration:start -->"
        celebration_end = "<!-- ghmenubar-approval-celebration:end -->"

        def fail(message):
            raise SystemExit(f"review payload {message}")

        with open(payload_path, encoding="utf-8") as handle:
            payload = json.load(handle)

        if not isinstance(payload, dict):
            fail("must be a JSON object")

        allowed_payload_fields = {"commit_id", "body", "event", "comments"}
        unsupported_payload_fields = sorted(set(payload) - allowed_payload_fields)
        if unsupported_payload_fields:
            fail(
                "contains unsupported fields: "
                + ", ".join(unsupported_payload_fields)
            )

        commit_id = payload.get("commit_id", "")
        event = payload.get("event", "")
        body = payload.get("body")
        comments = payload.get("comments")
        if not re.fullmatch(r"[0-9a-fA-F]{40}", commit_id):
            fail("commit_id must be a full 40-character SHA")
        if event not in {"APPROVE", "COMMENT", "REQUEST_CHANGES"}:
            fail("event is invalid")
        if not isinstance(body, str):
            fail("body must be a string")
        if not isinstance(comments, list):
            fail("comments must be a list")

        celebration_pattern = re.compile(
            r"(?:\\n\\n)?"
            + re.escape(celebration_start)
            + r"\\n.*?\\n"
            + re.escape(celebration_end),
            re.DOTALL,
        )
        undecorated_body = celebration_pattern.sub("", body)
        if event == "APPROVE":
            celebration_block = (
                celebration_start
                + "\\n"
                + approval_celebration
                + "\\n"
                + celebration_end
            )
            trimmed_body = undecorated_body.rstrip()
            payload["body"] = (
                trimmed_body + "\\n\\n" + celebration_block
                if trimmed_body
                else celebration_block
            )
        else:
            normalized_body = (
                undecorated_body.rstrip()
                if undecorated_body != body
                else body
            )
            if not normalized_body.strip():
                fail(f"{event} requires a non-empty body")
            payload["body"] = normalized_body

        allowed_comment_fields = {
            "path",
            "body",
            "position",
            "line",
            "side",
            "start_line",
            "start_side",
            # Older review prompts emitted this convenience field. GitHub's
            # API does not accept it, so convert it to supported Markdown.
            "suggestion",
        }

        def positive_integer(value):
            return isinstance(value, int) and not isinstance(value, bool) and value > 0

        for index, comment in enumerate(comments, start=1):
            if not isinstance(comment, dict):
                fail(f"comment {index} must be an object")

            unsupported_comment_fields = sorted(set(comment) - allowed_comment_fields)
            if unsupported_comment_fields:
                fail(
                    f"comment {index} contains unsupported fields: "
                    + ", ".join(unsupported_comment_fields)
                )

            path = comment.get("path")
            comment_body = comment.get("body")
            if not isinstance(path, str) or not path.strip():
                fail(f"comment {index} path must be a non-empty string")
            if not isinstance(comment_body, str) or not comment_body.strip():
                fail(f"comment {index} body must be a non-empty string")

            has_position = "position" in comment
            has_line = "line" in comment
            if has_position == has_line:
                fail(f"comment {index} must contain exactly one of position or line")

            if has_position:
                if not positive_integer(comment["position"]):
                    fail(f"comment {index} position must be a positive integer")
                location_only_fields = {"side", "start_line", "start_side"} & set(comment)
                if location_only_fields:
                    fail(
                        f"comment {index} cannot combine position with: "
                        + ", ".join(sorted(location_only_fields))
                    )
            else:
                if not positive_integer(comment["line"]):
                    fail(f"comment {index} line must be a positive integer")
                if comment.get("side") not in {"LEFT", "RIGHT"}:
                    fail(f"comment {index} side must be LEFT or RIGHT")
                has_start_line = "start_line" in comment
                has_start_side = "start_side" in comment
                if has_start_line and not has_start_side:
                    # A range that names only one side is unambiguous: both
                    # endpoints belong to that side. Canonicalize this common
                    # draft omission before sending the payload to GitHub.
                    comment["start_side"] = comment["side"]
                    has_start_side = True
                if has_start_side and not has_start_line:
                    fail(f"comment {index} start_side requires start_line")
                if has_start_line:
                    if not positive_integer(comment["start_line"]):
                        fail(f"comment {index} start_line must be a positive integer")
                    if comment["start_line"] > comment["line"]:
                        fail(f"comment {index} start_line cannot exceed line")
                    if comment["start_side"] not in {"LEFT", "RIGHT"}:
                        fail(f"comment {index} start_side must be LEFT or RIGHT")

            suggestion = comment.pop("suggestion", None)
            if suggestion is not None:
                if not isinstance(suggestion, str) or not suggestion.strip():
                    fail(f"comment {index} suggestion must be a non-empty string")
                if "```" in suggestion:
                    fail(f"comment {index} suggestion cannot contain a Markdown fence")
                if "```suggestion" not in comment_body:
                    comment["body"] = (
                        comment_body.rstrip()
                        + "\\n\\n```suggestion\\n"
                        + suggestion.rstrip()
                        + "\\n```"
                    )

        payload["commit_id"] = commit_id.lower()
        temporary_path = f"{payload_path}.tmp.{os.getpid()}"
        try:
            with open(temporary_path, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False, indent=2)
                handle.write("\\n")
            os.replace(temporary_path, payload_path)
        finally:
            try:
                os.remove(temporary_path)
            except FileNotFoundError:
                pass
        PY
        }

        show_review_actions() {
          local approval_event
          approval_event=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["event"])' "$review_payload" 2>/dev/null) || approval_event=""
          print -- '\\n============================================================'
          print -- 'REVIEW READY — NOTHING SUBMITTED'
          if [[ "$approval_event" == "APPROVE" ]]; then
            print -- '  Approval celebration selected from the reviewed allowlist:'
            print -r -- "  $approval_celebration"
          fi
          print -- '  [e] Edit the draft with Copilot'
          print -- '  [s] Submit the draft as shown'
          print -- '  [c] Cancel without submitting'
          print -- '============================================================'
        }

        submit_review_payload() {
          local reviewed_head current_head submission_output submission_status
          validate_review_payload || return $?
          reviewed_head=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["commit_id"])' "$review_payload") || return $?

          current_head=$(\(githubCommand) pr view \(Self.shellQuoted(reviewNumber)) \
            --repo \(Self.shellQuoted(pullRequest.repository)) \
            --json headRefOid --jq .headRefOid) || return $?
          current_head=${current_head:l}
          if [[ "$current_head" != "$reviewed_head" ]]; then
            print -u2 -- "\\nPR head changed from $reviewed_head to $current_head. Nothing was submitted."
            print -u2 -- 'This draft is stale and cannot be updated safely. Start a new review from the current PR head.'
            # Keep this distinct from an ordinary gh/API failure. The caller
            # must leave the draft gate instead of offering the stale draft
            # again indefinitely.
            return 75
          fi

          submission_output=$(\(githubCommand) api \
            \(Self.shellQuoted(reviewEndpoint)) \
            --method POST \
            --input "$review_payload" 2>&1)
          submission_status=$?
          if (( submission_status != 0 )); then
            print -r -u2 -- "$submission_output"
          fi
          return "$submission_status"
        }

        if ! validate_review_payload; then
          print -u2 -- '\\nThe internal draft is not valid for GitHub submission. Choose Edit to correct it or Cancel.'
        fi
        while true; do
          show_review_actions
          read -r "review_action?Choose e, s, or c: "
          case "$review_action" in
            e|E|edit|Edit|EDIT)
              print -- '\\nOpening the draft session for editing. Posting remains blocked.'
              print -- 'Describe the changes to Copilot, then exit Copilot to return to this menu.'
              \(editCommand)
              review_status=$?
              if (( review_status != 0 )); then
                print -u2 -- '\\nGitHub Copilot exited during editing (status '"$review_status"'). Nothing was submitted.'
              fi
              if ! validate_review_payload; then
                print -u2 -- '\\nThe edited draft is not valid for GitHub submission. Edit it again or Cancel.'
              fi
              ;;
            s|S|submit|Submit|SUBMIT)
              print -- '\\nRechecking the PR head before submission...'
              submit_review_payload
              review_submit_status=$?
              if (( review_submit_status == 0 )); then
                print -- '\\nReview submitted.'
                exit 0
              fi
              if (( review_submit_status == 75 )); then
                exit 75
              fi
              print -u2 -- '\\nSubmission failed. Nothing was posted by GHMenuBar.'
              print -u2 -- 'Choose Edit to correct the draft or Cancel. Retry Submit only after a transient GitHub error.'
              ;;
            c|C|cancel|Cancel|CANCEL|"")
              print -- '\\nReview cancelled. Nothing was submitted.'
              exit 0
              ;;
            *)
              print -u2 -- 'Choose Edit, Submit, or Cancel.'
              ;;
          esac
        done
        """
    }

    private func copilotCompatiblePrompt(
        _ prompt: String,
        for pullRequest: PullRequest,
        reviewProfile: ResolvedAgentReviewProfile?,
        githubCLIExecutable: String?,
        reviewDraftPath: String,
        approvalCelebration: ApprovalCelebration
    ) -> String {
        let githubCLIGuidance = githubCLIExecutable.map { _ in
            """
            GitHub CLI is already available as `gh` on PATH.
            Invoke it as `gh`; do not use or search for an absolute executable path.
            """
        } ?? ""
        let repositoryPath = localRepositoryPath(for: pullRequest, reviewProfile: reviewProfile)
        let localRepositoryGuidance = repositoryPath.map {
            "Use the local repository checkout at `\($0)` when reading repository files."
        } ?? ""
        let draftOnlyGuidance = """
        Prepare the review draft only. Do not call `gh pr review`, `gh api`, `.agent/scripts/gh-pr-review-post.sh`, or any equivalent posting command.
        Use the skill's native human-facing draft presentation exactly, including its body, event, score, inline comments, and internal receipt when required. Do not add a raw `Payload` section.
        Silently save the machine-readable JSON payload to `\(reviewDraftPath)` for the host application. Do not print the raw JSON, the file path, or any transport-file status in the user-facing draft.
        The JSON payload must contain only `commit_id`, `body`, `event`, and `comments`. Each inline comment must contain only GitHub's supported `path`, `body`, and location fields (`position`, or `line` plus `side`). For a multi-line range, always include both `start_line` and `start_side`; use the same value as `side` when both endpoints are on that side. Encode a suggested change inside the comment's `body` as a fenced `suggestion` Markdown block; never add a separate `suggestion` JSON field.
        If the review event is `APPROVE`, end the human-facing review body with exactly this host-selected celebration: \(approvalCelebration.markdown)
        The celebration came from the host application's closed, reviewed allowlist. Do not replace it with another emoji, meme, image, GIF, or URL. Do not include it for `COMMENT` or `REQUEST_CHANGES`; the host application enforces these rules before submission.
        Finish after the human-facing draft without submitting or asking a second confirmation question. The host application renders the Edit, Submit, and Cancel confirmation gate next. A draft is incomplete until the internal JSON file exists.
        """
        guard let skillName = Self.workspaceSkillName(from: prompt) else {
            return [prompt, githubCLIGuidance, draftOnlyGuidance]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }

        let reviewTarget = Self.pullRequestNumber(from: pullRequest.url)
            .map(String.init) ?? pullRequest.url.absoluteString
        let skillRootPath = reviewProfile?.promptRootPath
            ?? reviewProfile?.workspacePath
            ?? settings.workspacePath
        let isolatedWorkingDirectoryGuidance = isolatedCopilotWorkingDirectory(for: reviewProfile).map {
            "The Copilot process starts in the isolated directory `\($0)` to avoid unrelated workspace configuration. Run relative `.agent` and `developers-tools` skill commands from `\(skillRootPath)`, not from the isolated directory."
        } ?? ""
        let skillPath = URL(fileURLWithPath: skillRootPath, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
            .resolvingSymlinksInPath()
            .path
        return """
        You are explicitly invoking the workspace skill `/\(skillName)`.
        Before taking any other action, read and follow the project skill at the exact path `\(skillPath)`.
        Do not substitute a personal or global skills directory for this path.
        \(githubCLIGuidance)
        \(localRepositoryGuidance)
        \(isolatedWorkingDirectoryGuidance)
        Follow the skill's required route directly. Do not inspect user-level credential or configuration files, and do not search the machine for tools or repositories.
        If an optional external integration is unavailable and the skill does not require it, skip it and continue with local repository and GitHub CLI evidence.
        \(draftOnlyGuidance)

        Skill invocation: \(prompt)
        Target pull request: \(pullRequest.repository) \(reviewTarget)
        URL: \(pullRequest.url.absoluteString)
        """
    }

    private func reviewDraftPath(
        for pullRequest: PullRequest,
        copilotWorkingDirectory: String?
    ) -> String {
        let directory = copilotWorkingDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? scriptDirectory
        let repository = Self.repositoryName(from: pullRequest.repository)
            .replacingOccurrences(of: "/", with: "-")
        let reviewNumber = Self.pullRequestNumber(from: pullRequest.url).map(String.init) ?? "unknown"
        return directory
            .appendingPathComponent(
                "ghmenubar-\(repository)-pr\(reviewNumber)-\(UUID().uuidString)-review.json",
                isDirectory: false
            )
            .path
    }

    private func copilotPostingDenialArguments(
        githubCLIExecutable: String?,
        reviewProfile: ResolvedAgentReviewProfile?
    ) -> String {
        var commands = [
            "gh pr review",
            "gh pr comment",
            "gh pr merge",
            "gh api",
            "git push",
            ".agent/scripts/gh-pr-review-post.sh",
            "gh-pr-review-post.sh"
        ]

        if let githubCLIExecutable {
            commands.append(contentsOf: [
                "\(githubCLIExecutable) pr review",
                "\(githubCLIExecutable) pr comment",
                "\(githubCLIExecutable) pr merge",
                "\(githubCLIExecutable) api"
            ])
        }

        let skillRootPath = reviewProfile?.promptRootPath
            ?? reviewProfile?.workspacePath
            ?? settings.workspacePath
        if !skillRootPath.isEmpty {
            commands.append(
                URL(fileURLWithPath: skillRootPath, isDirectory: true)
                    .appendingPathComponent(".agent/scripts/gh-pr-review-post.sh", isDirectory: false)
                    .path
            )
        }

        return commands
            .reduce(into: [String]()) { unique, command in
                guard !unique.contains(command) else { return }
                unique.append(command)
            }
            .map { "--deny-tool \(Self.shellQuoted("shell(\($0))")) " }
            .joined()
    }

    private func disabledMCPServerArguments(
        for reviewProfile: ResolvedAgentReviewProfile?,
        pullRequest: PullRequest
    ) -> String {
        let roots = [
            reviewProfile?.promptRootPath,
            reviewProfile?.workspacePath,
            settings.workspacePath,
            localRepositoryPath(for: pullRequest, reviewProfile: reviewProfile)
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let relativeConfigurationPaths = [
            ".mcp.json",
            ".github/mcp.json",
            ".vscode/mcp.json"
        ]
        var serverNames = Set<String>()

        for root in Set(roots) {
            for relativePath in relativeConfigurationPaths {
                let configurationURL = URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(relativePath, isDirectory: false)
                guard let data = try? Data(contentsOf: configurationURL),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }

                for containerName in ["servers", "mcpServers"] {
                    guard let servers = object[containerName] as? [String: Any] else { continue }
                    serverNames.formUnion(servers.keys.filter { !$0.isEmpty })
                }
            }
        }

        return serverNames
            .sorted()
            .map { "--disable-mcp-server \(Self.shellQuoted($0)) " }
            .joined()
    }

    private func localRepositoryPath(
        for pullRequest: PullRequest,
        reviewProfile: ResolvedAgentReviewProfile?
    ) -> String? {
        let workspacePath = reviewProfile?.workspacePath ?? settings.workspacePath
        guard !workspacePath.isEmpty else { return nil }

        let repositoryName = pullRequest.repository.split(separator: "/").last.map(String.init) ?? ""
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let candidates = workspaceURL.lastPathComponent == repositoryName
            ? [workspaceURL]
            : [workspaceURL.appendingPathComponent(repositoryName, isDirectory: true)]
        return candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        })?.path
    }

    private func reviewWorktree(
        for pullRequest: PullRequest,
        reviewProfile: ResolvedAgentReviewProfile?
    ) -> ReviewWorktree? {
        guard let workflow = settings.localReviewWorkflow(for: pullRequest.repository),
              let rootTemplate = workflow.worktreeRootPathTemplate,
              let pullRequestNumber = Self.pullRequestNumber(from: pullRequest.url),
              let sourceRepositoryPath = localRepositoryPath(
                  for: pullRequest,
                  reviewProfile: reviewProfile
              )
        else {
            return nil
        }

        let sourceRepositoryURL = URL(fileURLWithPath: sourceRepositoryPath, isDirectory: true)
            .standardizedFileURL
        let renderedRoot = rootTemplate
            .replacingOccurrences(of: "{pr}", with: String(pullRequestNumber))
            .replacingOccurrences(of: "{repo}", with: pullRequest.repository)
            .replacingOccurrences(
                of: "{repoName}",
                with: Self.repositoryName(from: pullRequest.repository)
            )
            .replacingOccurrences(of: "{workspace}", with: sourceRepositoryURL.path)
            .replacingOccurrences(of: "{workspacePath}", with: sourceRepositoryURL.path)
            .replacingOccurrences(
                of: "{workspaceParent}",
                with: sourceRepositoryURL.deletingLastPathComponent().path
            )
        let expandedRoot = (renderedRoot as NSString).expandingTildeInPath
        guard expandedRoot.hasPrefix("/") else { return nil }

        let rootURL = URL(fileURLWithPath: expandedRoot, isDirectory: true).standardizedFileURL
        let sourcePrefix = sourceRepositoryURL.path.hasSuffix("/")
            ? sourceRepositoryURL.path
            : sourceRepositoryURL.path + "/"
        guard rootURL.path != sourceRepositoryURL.path,
              !rootURL.path.hasPrefix(sourcePrefix)
        else {
            return nil
        }

        let sessionID = UUID().uuidString.lowercased().prefix(8)
        let sessionName = "\(Self.repositoryName(from: pullRequest.repository))-pr\(pullRequestNumber)-\(sessionID)"
        return ReviewWorktree(
            sourceRepositoryPath: sourceRepositoryURL.path,
            path: rootURL.appendingPathComponent(sessionName, isDirectory: true).path
        )
    }

    private func reviewProfileForAgentCommand(
        _ reviewProfile: ResolvedAgentReviewProfile?,
        reviewWorktree: ReviewWorktree?
    ) -> ResolvedAgentReviewProfile? {
        guard let reviewProfile, let reviewWorktree else { return reviewProfile }
        let workspaceURL = URL(fileURLWithPath: reviewProfile.workspacePath, isDirectory: true)
            .standardizedFileURL
        let sourceRepositoryURL = URL(
            fileURLWithPath: reviewWorktree.sourceRepositoryPath,
            isDirectory: true
        ).standardizedFileURL
        let promptRootPath = reviewProfile.promptRootPath
            ?? (workspaceURL.path == sourceRepositoryURL.path ? nil : workspaceURL.path)
        return ResolvedAgentReviewProfile(
            workspacePath: reviewWorktree.path,
            promptRootPath: promptRootPath,
            agentTool: reviewProfile.agentTool,
            reviewCommand: reviewProfile.reviewCommand
        )
    }

    private func worktreeReviewPrompt(
        _ prompt: String,
        reviewWorktree: ReviewWorktree
    ) -> String {
        """
        \(prompt)

        GHMenuBar creates a disposable detached worktree at `\(reviewWorktree.path)` for this review and pins it to the exact pull-request head before the agent starts. Review files only from that worktree. Do not run `git checkout`, `git switch`, `gh pr checkout`, or create another worktree. The original checkout at `\(reviewWorktree.sourceRepositoryPath)` must remain unchanged. GHMenuBar removes the disposable worktree when this review session exits; do not store lasting work there.
        """
    }

    private func reviewWorktreeSetupScript(
        _ reviewWorktree: ReviewWorktree,
        for pullRequest: PullRequest,
        githubCLIExecutable: String?
    ) -> String {
        let githubCommand = githubCLIExecutable.map(Self.shellQuoted) ?? "gh"
        let pullRequestNumber = Self.pullRequestNumber(from: pullRequest.url).map(String.init) ?? ""

        return """
        review_source_repository=\(Self.shellQuoted(reviewWorktree.sourceRepositoryPath))
        review_worktree=\(Self.shellQuoted(reviewWorktree.path))
        review_worktree_created=0

        cleanup_review_worktree() {
          local review_exit_status=$?
          trap - EXIT HUP INT TERM
          if (( review_worktree_created == 1 )); then
            print -- '\nCleaning up isolated review worktree...'
            if git -C "$review_source_repository" worktree remove --force "$review_worktree"; then
              print -- "Removed $review_worktree"
            else
              print -u2 -- "Could not remove $review_worktree automatically. It was left in place so you can inspect and remove it safely."
            fi
            git -C "$review_source_repository" worktree prune >/dev/null 2>&1 || true
          fi
          exit "$review_exit_status"
        }
        trap cleanup_review_worktree EXIT HUP INT TERM

        if ! git -C "$review_source_repository" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          print -u2 -- "The configured Workspace is not a Git checkout: $review_source_repository"
          exit 1
        fi
        if [[ -e "$review_worktree" ]]; then
          print -u2 -- "Refusing to reuse an existing review path: $review_worktree"
          exit 1
        fi
        review_worktree_parent=${review_worktree:h}
        if ! mkdir -p "$review_worktree_parent"; then
          print -u2 -- "Could not create the review worktree root: $review_worktree_parent"
          exit 1
        fi

        print -- 'Resolving the exact pull-request head...'
        review_head=$(\(githubCommand) pr view \(Self.shellQuoted(pullRequest.url.absoluteString)) --json headRefOid --jq '.headRefOid') || exit $?
        if [[ ${#review_head} -ne 40 || "$review_head" == *[^0-9a-fA-F]* ]]; then
          print -u2 -- 'GitHub returned an invalid pull-request head SHA.'
          exit 1
        fi
        if ! git -C "$review_source_repository" fetch --no-tags origin \(Self.shellQuoted("pull/\(pullRequestNumber)/head")); then
          print -u2 -- 'Could not fetch the pull-request head from the configured checkout remote named origin.'
          exit 1
        fi
        review_fetched_head=$(git -C "$review_source_repository" rev-parse FETCH_HEAD) || exit $?
        if [[ "$review_fetched_head" != "$review_head" ]]; then
          print -u2 -- 'The pull-request head changed while the review worktree was being prepared. Launch the review again.'
          exit 1
        fi
        if ! git -C "$review_source_repository" worktree add --detach "$review_worktree" "$review_head"; then
          print -u2 -- 'Could not create the isolated review worktree.'
          exit 1
        fi
        review_worktree_created=1
        print -- "Reviewing $review_head in isolated worktree $review_worktree"
        """
    }

    private func isolatedCopilotWorkingDirectory(
        for reviewProfile: ResolvedAgentReviewProfile?
    ) -> String? {
        let roots = [
            reviewProfile?.promptRootPath,
            reviewProfile?.workspacePath,
            settings.workspacePath
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        for root in Set(roots) {
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(".agent/tmp", isDirectory: true)
                .path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }

        return nil
    }

    private func guardedCommandScript(
        command: String,
        commandName: String,
        toolName: String,
        agentExecutable: String
    ) -> String {
        """
        \(commandAvailabilityCheck(
            agentExecutable: agentExecutable,
            commandName: commandName,
            toolName: toolName
        ))
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

    private func commandAvailabilityCheck(
        agentExecutable: String,
        commandName: String,
        toolName: String
    ) -> String {
        if agentExecutable.hasPrefix("/") {
            return """
            if [[ ! -x \(Self.shellQuoted(agentExecutable)) ]]; then
              print -u2 -- '\(toolName) moved or became unavailable after GHMenuBar found it at \(agentExecutable).'
              print -u2 -- 'Reinstall \(commandName), then launch the review again.'
              read -k 1 '?Press any key to close this window.'
              print
              exit 127
            fi
            """
        }

        return """
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

    private static func executableResolutionCommand(for commandName: String) -> String {
        """
        agent_path=$(command -v -- \(commandName)) || exit $?
        print -r -- "AGENT=$agent_path"
        gh_path=$(command -v -- gh 2>/dev/null) && print -r -- "GH=$gh_path"
        true
        """
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

    private func launchTerminal(
        scriptURL: URL,
        workspacePath: String,
        toolName: String
    ) async throws {
        let terminal = try resolvedTerminal()
        let invocation: (executable: String, arguments: [String])

        switch terminal {
        case .ghostty:
            let applicationPath = try terminalApplicationPath(for: .ghostty)
            let initialCommand = "/bin/zsh \(Self.shellQuoted(scriptURL.path))"
            invocation = (
                "/usr/bin/open",
                [
                    "-na", applicationPath,
                    "--args",
                    "--initial-command=\(initialCommand)",
                    "--working-directory=\(workspacePath)"
                ]
            )
        case .cmux:
            let applicationPath = try terminalApplicationPath(for: .cmux)
            let openResult = try await runTerminalProcess(
                executable: "/usr/bin/open",
                arguments: ["-a", applicationPath],
                terminalName: AgentReviewTerminal.cmux.displayName,
                toolName: toolName
            )
            guard openResult.exitCode == 0 else {
                try throwTerminalCommandFailure(
                    result: openResult,
                    terminalName: AgentReviewTerminal.cmux.displayName,
                    toolName: toolName
                )
            }
            let cmuxExecutable = URL(fileURLWithPath: applicationPath, isDirectory: true)
                .appendingPathComponent("Contents/Resources/bin/cmux")
                .path
            invocation = (
                cmuxExecutable,
                [
                    "new-workspace",
                    "--cwd", workspacePath,
                    "--command", "/bin/zsh \(Self.shellQuoted(scriptURL.path))"
                ]
            )
        case .appleTerminal:
            let profileName = settings.appleTerminalProfile
            guard !profileName.isEmpty else {
                throw Error.terminalMisconfigured(
                    terminal: terminal.displayName,
                    details: "Enter a name for the temporary zsh session profile."
                )
            }

            let terminalProfileURL: URL
            do {
                terminalProfileURL = try writeAppleTerminalProfile(
                    scriptURL: scriptURL,
                    profileName: profileName,
                    in: scriptDirectory
                )
            } catch {
                throw Error.processFailed(
                    message: "Could not prepare the Apple Terminal zsh profile: \(error.localizedDescription)"
                )
            }
            invocation = (
                "/usr/bin/open",
                ["-a", "Terminal", terminalProfileURL.path]
            )
        case .custom:
            invocation = try customTerminalInvocation(
                scriptURL: scriptURL,
                workspacePath: workspacePath
            )
        case .automatic:
            preconditionFailure("Automatic terminal must be resolved before launch.")
        }

        let result = try await runTerminalProcess(
            executable: invocation.executable,
            arguments: invocation.arguments,
            terminalName: terminal.displayName,
            toolName: toolName
        )
        guard result.exitCode == 0 else {
            try throwTerminalCommandFailure(
                result: result,
                terminalName: terminal.displayName,
                toolName: toolName
            )
        }
    }

    private func resolvedTerminal() throws -> AgentReviewTerminal {
        guard settings.terminal == .automatic else { return settings.terminal }
        if terminalApplications[.ghostty] != nil { return .ghostty }
        if terminalApplications[.cmux] != nil { return .cmux }
        throw Error.terminalUnavailable(
            terminal: AgentReviewTerminal.automatic.displayName,
            details: "Install Ghostty or cmux, or choose Apple Terminal."
        )
    }

    private func writeAppleTerminalProfile(
        scriptURL: URL,
        profileName: String,
        in directory: URL
    ) throws -> URL {
        let profileURL = directory.appendingPathComponent(
            "agent-review-\(UUID().uuidString).terminal"
        )
        let profile: [String: Any] = [
            // The generated script is executable and has a /bin/zsh shebang. Give
            // Terminal its path as the executable itself so no shell parses (or
            // preserves) quoting characters around the filename.
            "CommandString": scriptURL.path,
            // Terminal's plist key is named from Terminal's perspective: true means
            // this command is the tab's shell process, rather than input sent to the
            // user's default login shell.
            "RunCommandAsShell": true,
            "ProfileCurrentVersion": 2.09,
            "name": profileName,
            "type": "Window Settings"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .xml,
            options: 0
        )
        try data.write(to: profileURL, options: .atomic)
        return profileURL
    }

    private func terminalApplicationPath(for terminal: AgentReviewTerminal) throws -> String {
        guard let path = terminalApplications[terminal] else {
            throw Error.terminalUnavailable(
                terminal: terminal.displayName,
                details: "Install it or choose another Review terminal in Agent Review settings."
            )
        }
        return path
    }

    private func customTerminalInvocation(
        scriptURL: URL,
        workspacePath: String
    ) throws -> (executable: String, arguments: [String]) {
        let executable = settings.customTerminalExecutable
        let argumentTemplate = settings.customTerminalArguments
        guard executable.hasPrefix("/"), !argumentTemplate.isEmpty,
              argumentTemplate.contains("{script}")
        else {
            throw Error.terminalMisconfigured(
                terminal: AgentReviewTerminal.custom.displayName,
                details: "Provide an absolute executable path and one argument per line, including {script}."
            )
        }

        let arguments = argumentTemplate.components(separatedBy: .newlines).map { argument in
            argument
                .replacingOccurrences(of: "{script}", with: scriptURL.path)
                .replacingOccurrences(of: "{workspace}", with: workspacePath)
                .replacingOccurrences(of: "{shell}", with: "/bin/zsh")
        }
        return (executable, arguments)
    }

    private func runTerminalProcess(
        executable: String,
        arguments: [String],
        terminalName: String,
        toolName: String
    ) async throws -> ProcessResult {
        do {
            return try await runner.run(executable: executable, arguments: arguments)
        } catch {
            throw Error.processFailed(
                message: "Could not open \(terminalName) for the \(toolName) review: \(error.localizedDescription)"
            )
        }
    }

    private func throwTerminalCommandFailure(
        result: ProcessResult,
        terminalName: String,
        toolName: String
    ) throws -> Never {
        let details = Self.failureDetails(from: result)
        throw Error.commandFailed(
            message: details.isEmpty
                ? "Could not open \(terminalName) for the \(toolName) review (status \(result.exitCode))."
                : "Could not open \(terminalName) for the \(toolName) review: \(details)",
            exitCode: result.exitCode
        )
    }

    private static func detectedTerminalApplications() -> [AgentReviewTerminal: String] {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let candidates: [(AgentReviewTerminal, [String])] = [
            (.ghostty, [
                "/Applications/Ghostty.app",
                homeApplications.appendingPathComponent("Ghostty.app", isDirectory: true).path
            ]),
            (.cmux, [
                "/Applications/cmux.app",
                homeApplications.appendingPathComponent("cmux.app", isDirectory: true).path
            ])
        ]
        return candidates.reduce(into: [:]) { applications, candidate in
            if let path = candidate.1.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                applications[candidate.0] = path
            }
        }
    }

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
