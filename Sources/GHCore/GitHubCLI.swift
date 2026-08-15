import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> ProcessResult
}

public enum GitHubCLIError: Error, LocalizedError, Equatable {
    case commandFailed(message: String, exitCode: Int32)
    case invalidJSON(message: String)
    case processFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message, _),
             .invalidJSON(let message),
             .processFailed(let message):
            return message
        }
    }
}

public enum GitHubAuthenticationStatus: Equatable, Sendable {
    case unknown
    case authenticated(login: String)
    case unauthenticated(message: String)
}

public struct GitHubCLI: Sendable {
    public static let defaultRepositoryLimit = 1_000
    public static let defaultOpenPullRequestLimit = 1_000
    public static let defaultRepositoryOpenPullRequestLimit = 48
    private static let badCredentialsMessage = "GitHub credentials were rejected. Run `gh auth login -h github.com` or `gh auth refresh -h github.com`."
    private static let searchPullRequestJSONFields = "title,url,repository,author,updatedAt,isDraft"
    private static let repositoryPullRequestJSONFields = [
        "title",
        "url",
        "author",
        "updatedAt",
        "isDraft",
        "reviewDecision",
        "reviewRequests",
        "latestReviews",
        "statusCheckRollup",
        "commits"
    ].joined(separator: ",")

    private let owner: String
    private let runner: ProcessRunning

    public init(
        owner: String = GHMenuBarSettings.default.githubOwner,
        runner: ProcessRunning = DefaultProcessRunner()
    ) {
        self.owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runner = runner
    }

    public init(
        settings: GHMenuBarSettings,
        runner: ProcessRunning = DefaultProcessRunner()
    ) {
        self.init(owner: GHMenuBarSettings.default.githubOwner, runner: runner)
    }

    public static func openPullRequestsCommand(limit: Int) -> [String] {
        openPullRequestsCommand(owner: GHMenuBarSettings.default.githubOwner, limit: limit)
    }

    public static func openPullRequestsCommand(owner: String, limit: Int) -> [String] {
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = [
            "search", "prs",
            "--state", "open",
            "--draft=false",
            "--limit", "\(limit)",
            "--sort", "updated",
            "--order", "desc",
            "--json", searchPullRequestJSONFields
        ]

        if !normalizedOwner.isEmpty {
            arguments.insert(contentsOf: ["--owner", normalizedOwner], at: 5)
        }

        return arguments
    }

    public static func repositoryListCommand(limit: Int) -> [String] {
        repositoryListCommand(owner: GHMenuBarSettings.default.githubOwner, limit: limit)
    }

    public static func repositoryListCommand(owner: String, limit: Int) -> [String] {
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = [
            "repo", "list",
            "--limit", "\(limit)",
            "--json", "nameWithOwner"
        ]

        if !normalizedOwner.isEmpty {
            arguments.insert(normalizedOwner, at: 2)
        }

        return arguments
    }

    public static func openPullRequestsCommand(repository: String, limit: Int) -> [String] {
        [
            "pr", "list",
            "--repo", repository,
            "--state", "open",
            "--search", "draft:false",
            "--limit", "\(limit)",
            "--json", repositoryPullRequestJSONFields
        ]
    }

    public static func viewerLoginCommand() -> [String] {
        ["api", "user", "--jq", ".login"]
    }

    public static func organizationListCommand() -> [String] {
        ["api", "user/orgs", "--paginate", "--jq", ".[].login"]
    }

    public func fetchRepositories(limit: Int = Self.defaultRepositoryLimit) async throws -> [String] {
        let result = try await runGitHubCommand(arguments: Self.repositoryListCommand(owner: owner, limit: limit))

        return try decodeRepositories(from: result.stdout)
    }

    public func fetchRepositories(owner: String, limit: Int = Self.defaultRepositoryLimit) async throws -> [String] {
        let result = try await runGitHubCommand(arguments: Self.repositoryListCommand(owner: owner, limit: limit))

        return try decodeRepositories(from: result.stdout)
    }

    private func decodeRepositories(from stdout: String) throws -> [String] {
        do {
            return try JSONDecoder()
                .decode([GitHubRepositoryDTO].self, from: Data(stdout.utf8))
                .map(\.nameWithOwner)
                .sorted()
        } catch {
            throw GitHubCLIError.invalidJSON(message: "Unable to decode gh repository JSON: \(error.localizedDescription)")
        }
    }

    public func fetchOpenPullRequests(limit: Int = Self.defaultOpenPullRequestLimit) async throws -> [PullRequest] {
        let result = try await runGitHubCommand(arguments: Self.openPullRequestsCommand(owner: owner, limit: limit))

        return try decodePullRequests(from: result.stdout)
    }

    public func fetchOpenPullRequests(owner: String, limit: Int = Self.defaultOpenPullRequestLimit) async throws -> [PullRequest] {
        let result = try await runGitHubCommand(arguments: Self.openPullRequestsCommand(owner: owner, limit: limit))

        return try decodePullRequests(from: result.stdout)
    }

    public func fetchOpenPullRequests(
        repository: String,
        limit: Int = Self.defaultRepositoryOpenPullRequestLimit
    ) async throws -> [PullRequest] {
        let result = try await runGitHubCommand(arguments: Self.openPullRequestsCommand(
            repository: repository,
            limit: limit
        ))

        return try decodePullRequests(from: result.stdout, repositoryOverride: repository)
    }

    public func fetchViewerLogin() async throws -> String {
        let result = try await runGitHubCommand(arguments: Self.viewerLoginCommand())
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func fetchOrganizations() async throws -> [String] {
        let result = try await runGitHubCommand(arguments: Self.organizationListCommand())
        return Self.lines(from: result.stdout)
    }

    public func fetchAccounts() async throws -> [String] {
        let viewerLogin = try await fetchViewerLogin()
        let organizations = try await fetchOrganizations()
        return Self.uniquePreservingOrder([viewerLogin] + organizations)
    }

    public func authenticationStatus() async -> GitHubAuthenticationStatus {
        do {
            let login = try await fetchViewerLogin()
            guard !login.isEmpty else {
                return .unauthenticated(message: "gh did not return an authenticated user")
            }

            return .authenticated(login: login)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .unauthenticated(message: message)
        }
    }

    private func runGitHubCommand(arguments: [String]) async throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try await runner.run(
                executable: "gh",
                arguments: arguments
            )
        } catch {
            throw GitHubCLIError.processFailed(message: error.localizedDescription)
        }

        guard result.exitCode == 0 else {
            if Self.isBadCredentialsFailure(result) {
                _ = try? await runner.run(
                    executable: "gh",
                    arguments: ["config", "clear-cache"]
                )

                let retryResult: ProcessResult
                do {
                    retryResult = try await runner.run(
                        executable: "gh",
                        arguments: arguments
                    )
                } catch {
                    throw GitHubCLIError.processFailed(message: error.localizedDescription)
                }

                guard retryResult.exitCode == 0 else {
                    let message = Self.commandFailureMessage(for: retryResult)
                    throw GitHubCLIError.commandFailed(
                        message: message.isEmpty ? "gh exited with status \(retryResult.exitCode)" : message,
                        exitCode: retryResult.exitCode
                    )
                }

                return retryResult
            }

            let message = Self.commandFailureMessage(for: result)
            throw GitHubCLIError.commandFailed(
                message: message.isEmpty ? "gh exited with status \(result.exitCode)" : message,
                exitCode: result.exitCode
            )
        }

        return result
    }

    private static func commandFailureMessage(for result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if isBadCredentialsFailure(result) {
            return badCredentialsMessage
        }

        return stderr
    }

    private static func isBadCredentialsFailure(_ result: ProcessResult) -> Bool {
        let combinedOutput = [result.stderr, result.stdout]
            .joined(separator: "\n")
            .lowercased()

        return combinedOutput.contains("401")
            && combinedOutput.contains("bad credentials")
    }

    private func decodePullRequests(from stdout: String, repositoryOverride: String? = nil) throws -> [PullRequest] {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder
                .decode([GitHubPullRequestDTO].self, from: Data(stdout.utf8))
                .filter { !$0.isDependabotAuthored }
                .map { $0.model(repositoryOverride: repositoryOverride) }
        } catch {
            throw GitHubCLIError.invalidJSON(message: "Unable to decode gh pull request JSON: \(error.localizedDescription)")
        }
    }

    private static func lines(from stdout: String) -> [String] {
        stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { uniqueValues, value in
            guard !value.isEmpty,
                  !uniqueValues.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
            else {
                return
            }

            uniqueValues.append(value)
        }
    }
}

struct GitHubRepositoryDTO: Decodable {
    let nameWithOwner: String
}

public struct DefaultProcessRunner: ProcessRunning {
    public init() {}

    static func searchPath(existingPath: String?) -> String {
        let existingComponents = (existingPath ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbackComponents = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        return (existingComponents + fallbackComponents)
            .reduce(into: [String]()) { components, component in
                guard !components.contains(component) else { return }
                components.append(component)
            }
            .joined(separator: ":")
    }

    static func executablePath(
        executable: String,
        searchPath: String,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if executable.contains("/") {
            return fileExists(executable) ? executable : nil
        }

        for component in searchPath.split(separator: ":").map(String.init) {
            let candidate = "\(component)/\(executable)"
            if fileExists(candidate) {
                return candidate
            }
        }

        return nil
    }

    public func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        try await Task.detached {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            var environment = ProcessInfo.processInfo.environment
            let searchPath = Self.searchPath(existingPath: environment["PATH"])
            let executablePath = Self.executablePath(executable: executable, searchPath: searchPath)

            process.executableURL = URL(fileURLWithPath: executablePath ?? "/usr/bin/env")
            process.arguments = executablePath == nil ? [executable] + arguments : arguments
            environment["PATH"] = searchPath
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            let stdoutTask = Task.detached {
                stdout.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrTask = Task.detached {
                stderr.fileHandleForReading.readDataToEndOfFile()
            }
            process.waitUntilExit()

            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value

            return ProcessResult(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
        }.value
    }
}
