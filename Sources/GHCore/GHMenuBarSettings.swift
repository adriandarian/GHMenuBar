import Foundation

public struct GHMenuBarSettings: Equatable, Sendable {
    public static let minimumRefreshIntervalSeconds = 60

    public static let `default` = GHMenuBarSettings(
        githubOwner: "",
        refreshIntervalSeconds: 300,
        general: GeneralSettings(),
        repositoryFilter: RepositoryFilterSettings(),
        agentReview: AgentReviewSettings(
            isEnabled: false,
            supportedRepository: "",
            workspacePath: "",
            globalPrompt: AgentReviewSettings.defaultPrompt,
            repositoryPromptOverrides: [:]
        )
    )

    public let githubOwner: String
    public let refreshIntervalSeconds: Int
    public let general: GeneralSettings
    public let repositoryFilter: RepositoryFilterSettings
    public let agentReview: AgentReviewSettings

    public init(
        githubOwner: String,
        refreshIntervalSeconds: Int,
        general: GeneralSettings = GeneralSettings(),
        repositoryFilter: RepositoryFilterSettings = RepositoryFilterSettings(),
        agentReview: AgentReviewSettings
    ) {
        self.githubOwner = githubOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        self.refreshIntervalSeconds = max(refreshIntervalSeconds, Self.minimumRefreshIntervalSeconds)
        self.general = general
        self.repositoryFilter = repositoryFilter.sanitized()
        self.agentReview = agentReview.sanitized()
    }

}

public enum MenuBarCountScope: String, CaseIterable, Identifiable, Sendable {
    case allPullRequests
    case reviewRequests
    case failingChecks

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .allPullRequests:
            return "All"
        case .reviewRequests:
            return "Review"
        case .failingChecks:
            return "CI"
        }
    }
}

public struct GeneralSettings: Equatable, Sendable {
    public let isAutomaticRefreshEnabled: Bool
    public let showsPullRequestCount: Bool
    public let menuBarCountScope: MenuBarCountScope
    public let hidesZeroPullRequestCount: Bool
    public let notifiesForNewPullRequests: Bool
    public let notifiesForReviewRequests: Bool
    public let notifiesForCIFailures: Bool

    public init(
        isAutomaticRefreshEnabled: Bool = true,
        showsPullRequestCount: Bool = false,
        menuBarCountScope: MenuBarCountScope = .reviewRequests,
        hidesZeroPullRequestCount: Bool = true,
        notifiesForNewPullRequests: Bool = true,
        notifiesForReviewRequests: Bool = true,
        notifiesForCIFailures: Bool = false
    ) {
        self.isAutomaticRefreshEnabled = isAutomaticRefreshEnabled
        self.showsPullRequestCount = showsPullRequestCount
        self.menuBarCountScope = menuBarCountScope
        self.hidesZeroPullRequestCount = hidesZeroPullRequestCount
        self.notifiesForNewPullRequests = notifiesForNewPullRequests
        self.notifiesForReviewRequests = notifiesForReviewRequests
        self.notifiesForCIFailures = notifiesForCIFailures
    }
}

public struct RepositoryFilterSettings: Equatable, Sendable {
    public let organizations: [String]
    public let includedRepositories: [String]
    public let excludedRepositories: [String]

    public init(
        organizations: [String] = [],
        includedRepositories: [String] = [],
        excludedRepositories: [String] = []
    ) {
        self.organizations = organizations
        self.includedRepositories = includedRepositories
        self.excludedRepositories = excludedRepositories
    }

    public func sanitized() -> RepositoryFilterSettings {
        RepositoryFilterSettings(
            organizations: Self.normalizedList(organizations),
            includedRepositories: Self.normalizedList(includedRepositories),
            excludedRepositories: Self.normalizedList(excludedRepositories)
        )
    }

    public func filteredRepositories(_ repositories: [String]) -> [String] {
        let sanitizedFilter = sanitized()
        let organizationSet = Set(sanitizedFilter.organizations.map { $0.lowercased() })
        let includeSet = Set(sanitizedFilter.includedRepositories.map { $0.lowercased() })
        let excludeSet = Set(sanitizedFilter.excludedRepositories.map { $0.lowercased() })

        return repositories.filter { repository in
            let normalizedRepository = repository.lowercased()

            if !organizationSet.isEmpty,
               !organizationSet.contains(Self.owner(from: repository).lowercased()) {
                return false
            }

            if !includeSet.isEmpty,
               !includeSet.contains(normalizedRepository) {
                return false
            }

            return !excludeSet.contains(normalizedRepository)
        }
    }

    public func allows(repository: String) -> Bool {
        filteredRepositories([repository]).count == 1
    }

    public var hasExactlyOneIncludedRepository: Bool {
        sanitized().includedRepositories.count == 1
    }

    private static func owner(from repository: String) -> String {
        repository.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repository
    }

    private static func normalizedList(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { normalizedValues, value in
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedValue.isEmpty,
                  !normalizedValues.contains(normalizedValue)
            else {
                return
            }

            normalizedValues.append(normalizedValue)
        }
    }
}

public struct AgentReviewSettings: Equatable, Sendable {
    public static let defaultPrompt = "Review this pull request."
    public static let defaultAppleTerminalProfile = "GHMenuBar Review"
    public static let defaultCustomTerminalArguments = "{shell}\n{script}"

    public let isEnabled: Bool
    public let supportedRepository: String
    public let workspacePath: String
    public let terminal: AgentReviewTerminal
    public let appleTerminalProfile: String
    public let customTerminalExecutable: String
    public let customTerminalArguments: String
    public let agentTool: AgentReviewTool
    public let agentToolOverrides: [String: AgentReviewTool]
    public let reviewProfiles: [AgentReviewProfile]
    public let reviewScopes: [AgentReviewScope]
    public let globalPrompt: String
    public let repositoryPromptOverrides: [String: String]

    public init(
        isEnabled: Bool,
        supportedRepository: String,
        workspacePath: String,
        terminal: AgentReviewTerminal = .automatic,
        appleTerminalProfile: String = Self.defaultAppleTerminalProfile,
        customTerminalExecutable: String = "",
        customTerminalArguments: String = Self.defaultCustomTerminalArguments,
        agentTool: AgentReviewTool = .claudeCode,
        agentToolOverrides: [String: AgentReviewTool] = [:],
        reviewProfiles: [AgentReviewProfile] = [],
        reviewScopes: [AgentReviewScope] = [],
        globalPrompt: String = Self.defaultPrompt,
        repositoryPromptOverrides: [String: String] = [:]
    ) {
        self.isEnabled = isEnabled
        self.supportedRepository = supportedRepository
        self.workspacePath = workspacePath
        self.terminal = terminal
        self.appleTerminalProfile = appleTerminalProfile
        self.customTerminalExecutable = customTerminalExecutable
        self.customTerminalArguments = customTerminalArguments
        self.agentTool = agentTool
        self.agentToolOverrides = agentToolOverrides
        self.reviewProfiles = reviewProfiles
        self.reviewScopes = reviewScopes
        self.globalPrompt = globalPrompt
        self.repositoryPromptOverrides = repositoryPromptOverrides
    }

    public func sanitized() -> AgentReviewSettings {
        AgentReviewSettings(
            isEnabled: isEnabled,
            supportedRepository: supportedRepository.trimmingCharacters(in: .whitespacesAndNewlines),
            workspacePath: workspacePath.trimmingCharacters(in: .whitespacesAndNewlines),
            terminal: terminal,
            appleTerminalProfile: appleTerminalProfile.trimmingCharacters(in: .whitespacesAndNewlines),
            customTerminalExecutable: customTerminalExecutable.trimmingCharacters(in: .whitespacesAndNewlines),
            customTerminalArguments: customTerminalArguments.trimmingCharacters(in: .whitespacesAndNewlines),
            agentTool: agentTool,
            agentToolOverrides: agentToolOverrides.reduce(into: [String: AgentReviewTool]()) { overrides, entry in
                let normalizedPattern = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedPattern.isEmpty else { return }
                overrides[normalizedPattern] = entry.value
            },
            reviewProfiles: reviewProfiles.compactMap { profile in
                profile.sanitized()
            },
            reviewScopes: reviewScopes.compactMap { scope in
                scope.sanitized()
            },
            globalPrompt: normalizedPrompt(globalPrompt),
            repositoryPromptOverrides: repositoryPromptOverrides.reduce(into: [String: String]()) { overrides, entry in
                let normalizedRepository = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedRepository.isEmpty else { return }
                overrides[normalizedRepository] = normalizedPrompt(entry.value)
            }
        )
    }

    public func promptInstruction(for repository: String) -> String {
        let sanitizedSettings = sanitized()
        return sanitizedSettings.repositoryPromptOverrides[repository] ?? sanitizedSettings.globalPrompt
    }

    public func agentTool(for repository: String) -> AgentReviewTool {
        let sanitizedSettings = sanitized()
        if let repositoryTool = sanitizedSettings.agentToolOverrides[repository] {
            return repositoryTool
        }

        let owner = repository.split(separator: "/", maxSplits: 1).first.map(String.init)
        if let owner,
           let organizationTool = sanitizedSettings.agentToolOverrides["\(owner)/*"] {
            return organizationTool
        }

        return sanitizedSettings.agentTool
    }

    public func reviewProfile(for repository: String) -> ResolvedAgentReviewProfile? {
        let sanitizedSettings = sanitized()
        if !sanitizedSettings.reviewScopes.isEmpty {
            guard let workflow = sanitizedSettings.localReviewWorkflow(for: repository) else { return nil }
            let workspacePath = Self.expandedPath(
                Self.renderTemplate(workflow.workspacePathTemplate, repository: repository)
            )
            return ResolvedAgentReviewProfile(
                workspacePath: workspacePath,
                promptRootPath: workflow.promptRootPathTemplate.map {
                    Self.expandedPath(Self.renderTemplate($0, repository: repository))
                },
                agentTool: workflow.agentTool,
                reviewCommand: workflow.promptTemplate
            )
        }

        let repositoryName = Self.repositoryName(from: repository)
        let profiles = sanitizedSettings.reviewProfiles

        if let exactProfile = profiles.first(where: { $0.isExactMatch(for: repositoryName) }) {
            return exactProfile.resolvedProfile(
                workspacePath: Self.expandedPath(exactProfile.pathPattern)
            )
        }

        for wildcardProfile in profiles where wildcardProfile.isPathWildcard {
            let candidatePath = wildcardProfile.candidateWorkspacePath(for: repositoryName)
            guard FileManager.default.fileExists(atPath: candidatePath, isDirectory: nil) else {
                continue
            }

            return wildcardProfile.resolvedProfile(workspacePath: candidatePath)
        }

        if let fallbackProfile = profiles.first(where: { $0.isFallback }) {
            return fallbackProfile.resolvedProfile(workspacePath: sanitizedSettings.workspacePath)
        }

        guard !sanitizedSettings.workspacePath.isEmpty else { return nil }
        return ResolvedAgentReviewProfile(
            workspacePath: sanitizedSettings.workspacePath,
            promptRootPath: nil,
            agentTool: sanitizedSettings.agentTool(for: repository),
            reviewCommand: sanitizedSettings.promptInstruction(for: repository)
        )
    }

    public func localReviewWorkflow(for repository: String) -> AgentReviewLocalWorkflow? {
        sanitized().matchingScopes(for: repository).reduce(nil) { resolvedWorkflow, scope in
            switch scope.localReview {
            case .inherit:
                return resolvedWorkflow
            case .override(let workflow):
                return workflow
            case .disabled:
                return nil
            }
        }
    }

    public func cloudReviewWorkflow(for repository: String) -> AgentReviewCloudWorkflow? {
        sanitized().matchingScopes(for: repository).reduce(nil) { resolvedWorkflow, scope in
            switch scope.cloudReview {
            case .inherit:
                return resolvedWorkflow
            case .override(let workflow):
                return workflow
            case .disabled:
                return nil
            }
        }
    }

    public func reviewScopeResolution(for repository: String) -> AgentReviewScopeResolution {
        let normalizedScopes = reviewScopes.compactMap { $0.sanitized() }
        guard !normalizedScopes.isEmpty else { return .unconfigured }

        let invalidPatterns = normalizedScopes.compactMap { scope in
            scope.patternValidation == .invalid ? scope.pattern : nil
        }
        guard invalidPatterns.isEmpty else {
            return .invalid(patterns: invalidPatterns)
        }

        return normalizedScopes.contains { $0.matches(repository: repository) }
            ? .supported
            : .unsupported
    }

    private func normalizedPrompt(_ prompt: String) -> String {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedPrompt.isEmpty ? Self.defaultPrompt : normalizedPrompt
    }

    private func matchingScopes(for repository: String) -> [AgentReviewScope] {
        let scopes = reviewScopes.filter { $0.matches(repository: repository) }
        return scopes.sorted { lhs, rhs in
            if lhs.specificity == rhs.specificity {
                let lhsIndex = reviewScopes.firstIndex(of: lhs) ?? 0
                let rhsIndex = reviewScopes.firstIndex(of: rhs) ?? 0
                return lhsIndex < rhsIndex
            }
            return lhs.specificity < rhs.specificity
        }
    }

    private static func repositoryName(from repository: String) -> String {
        repository.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repository
    }

    private static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func renderTemplate(_ template: String, repository: String) -> String {
        template
            .replacingOccurrences(of: "{repo}", with: repository)
            .replacingOccurrences(of: "{repoName}", with: repositoryName(from: repository))
    }
}

public enum AgentReviewTerminal: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case ghostty
    case cmux
    case appleTerminal = "apple-terminal"
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .ghostty:
            return "Ghostty"
        case .cmux:
            return "cmux"
        case .appleTerminal:
            return "Apple Terminal"
        case .custom:
            return "Custom"
        }
    }
}

public struct AgentReviewScope: Equatable, Codable, Sendable {
    public let pattern: String
    public let localReview: AgentReviewLocalSetting
    public let cloudReview: AgentReviewCloudSetting

    public init(
        pattern: String,
        localReview: AgentReviewLocalSetting = .inherit,
        cloudReview: AgentReviewCloudSetting = .inherit
    ) {
        self.pattern = pattern
        self.localReview = localReview
        self.cloudReview = cloudReview
    }

    public var patternValidation: AgentReviewScopePatternValidation {
        Self.parse(pattern: pattern).validation
    }

    public func matches(repository: String) -> Bool {
        guard case .valid(let scopePattern) = Self.parse(pattern: pattern),
              case .valid(let repositoryPattern) = Self.parse(pattern: repository),
              case .repository(let repositoryOwner, let repositoryName) = repositoryPattern
        else {
            return false
        }

        switch scopePattern {
        case .allRepositories:
            return true
        case .owner(let owner):
            return owner == repositoryOwner
        case .repository(let owner, let name):
            return owner == repositoryOwner && name == repositoryName
        }
    }

    fileprivate func sanitized() -> AgentReviewScope? {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty else { return nil }

        return AgentReviewScope(
            pattern: normalizedPattern,
            localReview: localReview.sanitized(),
            cloudReview: cloudReview.sanitized()
        )
    }

    fileprivate var specificity: Int {
        switch Self.parse(pattern: pattern) {
        case .valid(.allRepositories):
            return 0
        case .valid(.owner):
            return 1
        case .valid(.repository):
            return 2
        case .unconfigured, .invalid:
            return -1
        }
    }

    private static func parse(pattern: String) -> ParsedAgentReviewScopePattern {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty else { return .unconfigured }
        guard normalizedPattern != "*" else { return .valid(.allRepositories) }
        guard !normalizedPattern.hasPrefix("~"),
              !normalizedPattern.hasPrefix("/"),
              !normalizedPattern.contains("\\"),
              !normalizedPattern.contains(where: \.isWhitespace)
        else {
            return .invalid
        }

        let components = normalizedPattern.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return .invalid }

        let owner = String(components[0])
        let repository = String(components[1])
        guard isValidOwner(owner) else { return .invalid }

        if repository == "*" {
            return .valid(.owner(owner))
        }

        guard isValidRepositoryName(repository) else { return .invalid }
        return .valid(.repository(owner: owner, name: repository))
    }

    private static func isValidOwner(_ owner: String) -> Bool {
        guard !owner.isEmpty,
              owner.count <= 39,
              owner.first != "-",
              owner.last != "-"
        else {
            return false
        }

        let allowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
        return owner.unicodeScalars.allSatisfy(allowedCharacters.unicodeScalars.contains)
    }

    private static func isValidRepositoryName(_ repository: String) -> Bool {
        guard !repository.isEmpty, repository.count <= 100 else { return false }
        let allowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        return repository.unicodeScalars.allSatisfy(allowedCharacters.unicodeScalars.contains)
    }
}

public enum AgentReviewScopePatternValidation: Equatable, Sendable {
    case unconfigured
    case valid
    case invalid
}

public enum AgentReviewScopeResolution: Equatable, Sendable {
    case unconfigured
    case invalid(patterns: [String])
    case unsupported
    case supported
}

private enum ParsedAgentReviewScopePattern {
    case unconfigured
    case valid(AgentReviewRepositoryScopePattern)
    case invalid

    var validation: AgentReviewScopePatternValidation {
        switch self {
        case .unconfigured:
            return .unconfigured
        case .valid:
            return .valid
        case .invalid:
            return .invalid
        }
    }
}

private enum AgentReviewRepositoryScopePattern {
    case allRepositories
    case owner(String)
    case repository(owner: String, name: String)
}

public enum AgentReviewLocalSetting: Equatable, Codable, Sendable {
    case inherit
    case override(AgentReviewLocalWorkflow)
    case disabled

    fileprivate func sanitized() -> AgentReviewLocalSetting {
        switch self {
        case .inherit, .disabled:
            return self
        case .override(let workflow):
            return workflow.sanitized().map(AgentReviewLocalSetting.override) ?? .disabled
        }
    }
}

public enum AgentReviewCloudSetting: Equatable, Codable, Sendable {
    case inherit
    case override(AgentReviewCloudWorkflow)
    case disabled

    fileprivate func sanitized() -> AgentReviewCloudSetting {
        switch self {
        case .inherit, .disabled:
            return self
        case .override(let workflow):
            return workflow.sanitized().map(AgentReviewCloudSetting.override) ?? .disabled
        }
    }
}

public struct AgentReviewLocalWorkflow: Equatable, Codable, Sendable {
    public static let defaultWorktreeRootPathTemplate = "~/.ghmenubar/worktrees"

    public let agentTool: AgentReviewTool
    public let codexModel: String?
    public let claudeModel: String?
    public let copilotModel: String?
    public let workspacePathTemplate: String
    public let promptRootPathTemplate: String?
    public let worktreeRootPathTemplate: String?
    public let promptTemplate: String

    public init(
        agentTool: AgentReviewTool,
        codexModel: String? = nil,
        claudeModel: String? = nil,
        copilotModel: String? = nil,
        workspacePathTemplate: String,
        promptRootPathTemplate: String? = nil,
        worktreeRootPathTemplate: String? = nil,
        promptTemplate: String
    ) {
        self.agentTool = agentTool
        self.codexModel = codexModel
        self.claudeModel = claudeModel
        self.copilotModel = copilotModel
        self.workspacePathTemplate = workspacePathTemplate
        self.promptRootPathTemplate = promptRootPathTemplate
        self.worktreeRootPathTemplate = worktreeRootPathTemplate
        self.promptTemplate = promptTemplate
    }

    public func model(for agentTool: AgentReviewTool) -> String? {
        switch agentTool {
        case .codexCLI:
            return codexModel
        case .claudeCode:
            return claudeModel
        case .copilot:
            return copilotModel
        }
    }

    fileprivate func sanitized() -> AgentReviewLocalWorkflow? {
        let normalizedWorkspacePathTemplate = workspacePathTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPromptRootPathTemplate = promptRootPathTemplate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWorktreeRootPathTemplate = worktreeRootPathTemplate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPromptTemplate = promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspacePathTemplate.isEmpty, !normalizedPromptTemplate.isEmpty else { return nil }

        return AgentReviewLocalWorkflow(
            agentTool: agentTool,
            codexModel: Self.normalizedModel(codexModel),
            claudeModel: Self.normalizedModel(claudeModel),
            copilotModel: Self.normalizedModel(copilotModel),
            workspacePathTemplate: normalizedWorkspacePathTemplate,
            promptRootPathTemplate: normalizedPromptRootPathTemplate?.isEmpty == false ? normalizedPromptRootPathTemplate : nil,
            worktreeRootPathTemplate: normalizedWorktreeRootPathTemplate?.isEmpty == false
                ? normalizedWorktreeRootPathTemplate
                : nil,
            promptTemplate: normalizedPromptTemplate
        )
    }

    private static func normalizedModel(_ model: String?) -> String? {
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedModel?.isEmpty == false ? normalizedModel : nil
    }
}

public struct AgentReviewCloudWorkflow: Equatable, Codable, Sendable {
    public let workflowName: String
    public let triggerTemplate: String
    public let readinessRequirements: String

    public init(
        workflowName: String,
        triggerTemplate: String,
        readinessRequirements: String = ""
    ) {
        self.workflowName = workflowName
        self.triggerTemplate = triggerTemplate
        self.readinessRequirements = readinessRequirements
    }

    fileprivate func sanitized() -> AgentReviewCloudWorkflow? {
        let normalizedWorkflowName = workflowName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTriggerTemplate = triggerTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkflowName.isEmpty, !normalizedTriggerTemplate.isEmpty else { return nil }

        return AgentReviewCloudWorkflow(
            workflowName: normalizedWorkflowName,
            triggerTemplate: normalizedTriggerTemplate,
            readinessRequirements: readinessRequirements.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public struct AgentReviewProfile: Equatable, Codable, Sendable {
    public let pathPattern: String
    public let agentTool: AgentReviewTool
    public let reviewCommand: String

    public init(pathPattern: String, agentTool: AgentReviewTool, reviewCommand: String) {
        self.pathPattern = pathPattern
        self.agentTool = agentTool
        self.reviewCommand = reviewCommand
    }

    fileprivate func sanitized() -> AgentReviewProfile? {
        let normalizedPathPattern = pathPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReviewCommand = reviewCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPathPattern.isEmpty, !normalizedReviewCommand.isEmpty else { return nil }

        return AgentReviewProfile(
            pathPattern: normalizedPathPattern,
            agentTool: agentTool,
            reviewCommand: normalizedReviewCommand
        )
    }

    fileprivate var isFallback: Bool {
        pathPattern == "*"
    }

    fileprivate var isPathWildcard: Bool {
        pathPattern.hasSuffix("/*")
    }

    fileprivate func isExactMatch(for repositoryName: String) -> Bool {
        !isFallback &&
            !isPathWildcard &&
            URL(fileURLWithPath: expandedPath(pathPattern)).lastPathComponent == repositoryName
    }

    fileprivate func candidateWorkspacePath(for repositoryName: String) -> String {
        let basePattern = String(pathPattern.dropLast(2))
        return URL(fileURLWithPath: expandedPath(basePattern))
            .appendingPathComponent(repositoryName, isDirectory: true)
            .path
    }

    fileprivate func resolvedProfile(workspacePath: String) -> ResolvedAgentReviewProfile {
        ResolvedAgentReviewProfile(
            workspacePath: workspacePath,
            promptRootPath: nil,
            agentTool: agentTool,
            reviewCommand: reviewCommand
        )
    }

    private func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

public struct ResolvedAgentReviewProfile: Equatable, Sendable {
    public let workspacePath: String
    public let promptRootPath: String?
    public let agentTool: AgentReviewTool
    public let reviewCommand: String
}

public enum AgentReviewTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case codexCLI = "codex-cli"
    case claudeCode = "claude-code"
    case copilot

    public var id: String { rawValue }

    public init?(userFacingName: String) {
        let normalizedName = userFacingName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedName {
        case "codex", "codex-cli", "codex cli":
            self = .codexCLI
        case "claude", "claude-code", "claude code":
            self = .claudeCode
        case "copilot", "github copilot", "github-copilot":
            self = .copilot
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .codexCLI:
            return "Codex CLI"
        case .claudeCode:
            return "Claude Code"
        case .copilot:
            return "GitHub Copilot"
        }
    }
}

public struct GHMenuBarSettingsStorage {
    public static let githubOwnerKey = "GHMenuBar.settings.githubOwner"
    public static let refreshIntervalSecondsKey = "GHMenuBar.settings.refreshIntervalSeconds"
    public static let automaticRefreshEnabledKey = "GHMenuBar.settings.general.automaticRefreshEnabled"
    public static let showsPullRequestCountKey = "GHMenuBar.settings.general.showsPullRequestCount"
    public static let menuBarCountScopeKey = "GHMenuBar.settings.general.menuBarCountScope"
    public static let hidesZeroPullRequestCountKey = "GHMenuBar.settings.general.hidesZeroPullRequestCount"
    public static let notifiesForNewPullRequestsKey = "GHMenuBar.settings.general.notifiesForNewPullRequests"
    public static let notifiesForReviewRequestsKey = "GHMenuBar.settings.general.notifiesForReviewRequests"
    public static let notifiesForCIFailuresKey = "GHMenuBar.settings.general.notifiesForCIFailures"
    public static let organizationsKey = "GHMenuBar.settings.repositoryFilter.organizations"
    public static let includedRepositoriesKey = "GHMenuBar.settings.repositoryFilter.includedRepositories"
    public static let excludedRepositoriesKey = "GHMenuBar.settings.repositoryFilter.excludedRepositories"
    public static let agentReviewEnabledKey = "GHMenuBar.settings.agentReview.enabled"
    public static let agentReviewSupportedRepositoryKey = "GHMenuBar.settings.agentReview.supportedRepository"
    public static let agentReviewWorkspacePathKey = "GHMenuBar.settings.agentReview.workspacePath"
    public static let agentReviewTerminalKey = "GHMenuBar.settings.agentReview.terminal"
    public static let agentReviewAppleTerminalProfileKey = "GHMenuBar.settings.agentReview.appleTerminalProfile"
    public static let agentReviewCustomTerminalExecutableKey = "GHMenuBar.settings.agentReview.customTerminalExecutable"
    public static let agentReviewCustomTerminalArgumentsKey = "GHMenuBar.settings.agentReview.customTerminalArguments"
    public static let agentReviewToolKey = "GHMenuBar.settings.agentReview.tool"
    public static let agentReviewToolOverridesKey = "GHMenuBar.settings.agentReview.toolOverrides"
    public static let agentReviewProfilesKey = "GHMenuBar.settings.agentReview.profiles"
    public static let agentReviewScopesKey = "GHMenuBar.settings.agentReview.scopes"
    public static let agentReviewGlobalPromptKey = "GHMenuBar.settings.agentReview.globalPrompt"
    public static let agentReviewRepositoryPromptOverridesKey = "GHMenuBar.settings.agentReview.repositoryPromptOverrides"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var settings: GHMenuBarSettings {
        let includedRepositories = RepositoryFilterSettings(
            includedRepositories: stringList(forKey: Self.includedRepositoriesKey)
        ).sanitized().includedRepositories
        let storedReviewScopes = reviewScopes()
        let repairedReviewScopes = Self.repairedReviewScopes(
            storedReviewScopes,
            includedRepositories: includedRepositories
        )
        if repairedReviewScopes != storedReviewScopes {
            saveReviewScopes(repairedReviewScopes)
        }

        return GHMenuBarSettings(
            githubOwner: defaults.string(forKey: Self.githubOwnerKey) ?? GHMenuBarSettings.default.githubOwner,
            refreshIntervalSeconds: storedRefreshIntervalSeconds,
            general: GeneralSettings(
                isAutomaticRefreshEnabled: bool(
                    forKey: Self.automaticRefreshEnabledKey,
                    defaultValue: GHMenuBarSettings.default.general.isAutomaticRefreshEnabled
                ),
                showsPullRequestCount: bool(
                    forKey: Self.showsPullRequestCountKey,
                    defaultValue: GHMenuBarSettings.default.general.showsPullRequestCount
                ),
                menuBarCountScope: Self.menuBarCountScope(
                    from: defaults.string(forKey: Self.menuBarCountScopeKey)
                ),
                hidesZeroPullRequestCount: bool(
                    forKey: Self.hidesZeroPullRequestCountKey,
                    defaultValue: GHMenuBarSettings.default.general.hidesZeroPullRequestCount
                ),
                notifiesForNewPullRequests: bool(
                    forKey: Self.notifiesForNewPullRequestsKey,
                    defaultValue: GHMenuBarSettings.default.general.notifiesForNewPullRequests
                ),
                notifiesForReviewRequests: bool(
                    forKey: Self.notifiesForReviewRequestsKey,
                    defaultValue: GHMenuBarSettings.default.general.notifiesForReviewRequests
                ),
                notifiesForCIFailures: bool(
                    forKey: Self.notifiesForCIFailuresKey,
                    defaultValue: GHMenuBarSettings.default.general.notifiesForCIFailures
                )
            ),
            repositoryFilter: RepositoryFilterSettings(
                organizations: stringList(forKey: Self.organizationsKey),
                includedRepositories: includedRepositories,
                excludedRepositories: stringList(forKey: Self.excludedRepositoriesKey)
            ),
            agentReview: AgentReviewSettings(
                isEnabled: defaults.bool(forKey: Self.agentReviewEnabledKey),
                supportedRepository: defaults.string(forKey: Self.agentReviewSupportedRepositoryKey) ?? "",
                workspacePath: defaults.string(forKey: Self.agentReviewWorkspacePathKey) ?? "",
                terminal: Self.agentReviewTerminal(
                    from: defaults.string(forKey: Self.agentReviewTerminalKey)
                ),
                appleTerminalProfile: defaults.string(forKey: Self.agentReviewAppleTerminalProfileKey)
                    ?? AgentReviewSettings.defaultAppleTerminalProfile,
                customTerminalExecutable: defaults.string(forKey: Self.agentReviewCustomTerminalExecutableKey) ?? "",
                customTerminalArguments: defaults.string(forKey: Self.agentReviewCustomTerminalArgumentsKey)
                    ?? AgentReviewSettings.defaultCustomTerminalArguments,
                agentTool: Self.agentReviewTool(
                    from: defaults.string(forKey: Self.agentReviewToolKey)
                ),
                agentToolOverrides: Self.agentReviewToolOverrides(
                    from: stringDictionary(forKey: Self.agentReviewToolOverridesKey)
                ),
                reviewProfiles: reviewProfiles(),
                reviewScopes: repairedReviewScopes,
                globalPrompt: defaults.string(forKey: Self.agentReviewGlobalPromptKey) ?? AgentReviewSettings.defaultPrompt,
                repositoryPromptOverrides: stringDictionary(forKey: Self.agentReviewRepositoryPromptOverridesKey)
            )
        )
    }

    public func save(_ settings: GHMenuBarSettings) {
        let sanitizedSettings = GHMenuBarSettings(
            githubOwner: settings.githubOwner,
            refreshIntervalSeconds: settings.refreshIntervalSeconds,
            general: settings.general,
            repositoryFilter: settings.repositoryFilter,
            agentReview: settings.agentReview
        )

        defaults.set(sanitizedSettings.githubOwner, forKey: Self.githubOwnerKey)
        defaults.set(sanitizedSettings.refreshIntervalSeconds, forKey: Self.refreshIntervalSecondsKey)
        defaults.set(sanitizedSettings.general.isAutomaticRefreshEnabled, forKey: Self.automaticRefreshEnabledKey)
        defaults.set(sanitizedSettings.general.showsPullRequestCount, forKey: Self.showsPullRequestCountKey)
        defaults.set(sanitizedSettings.general.menuBarCountScope.rawValue, forKey: Self.menuBarCountScopeKey)
        defaults.set(sanitizedSettings.general.hidesZeroPullRequestCount, forKey: Self.hidesZeroPullRequestCountKey)
        defaults.set(sanitizedSettings.general.notifiesForNewPullRequests, forKey: Self.notifiesForNewPullRequestsKey)
        defaults.set(sanitizedSettings.general.notifiesForReviewRequests, forKey: Self.notifiesForReviewRequestsKey)
        defaults.set(sanitizedSettings.general.notifiesForCIFailures, forKey: Self.notifiesForCIFailuresKey)
        setStringList(sanitizedSettings.repositoryFilter.organizations, forKey: Self.organizationsKey)
        setStringList(sanitizedSettings.repositoryFilter.includedRepositories, forKey: Self.includedRepositoriesKey)
        setStringList(sanitizedSettings.repositoryFilter.excludedRepositories, forKey: Self.excludedRepositoriesKey)
        defaults.set(sanitizedSettings.agentReview.isEnabled, forKey: Self.agentReviewEnabledKey)
        defaults.set(sanitizedSettings.agentReview.supportedRepository, forKey: Self.agentReviewSupportedRepositoryKey)
        defaults.set(sanitizedSettings.agentReview.workspacePath, forKey: Self.agentReviewWorkspacePathKey)
        defaults.set(sanitizedSettings.agentReview.terminal.rawValue, forKey: Self.agentReviewTerminalKey)
        defaults.set(
            sanitizedSettings.agentReview.appleTerminalProfile,
            forKey: Self.agentReviewAppleTerminalProfileKey
        )
        defaults.set(
            sanitizedSettings.agentReview.customTerminalExecutable,
            forKey: Self.agentReviewCustomTerminalExecutableKey
        )
        defaults.set(
            sanitizedSettings.agentReview.customTerminalArguments,
            forKey: Self.agentReviewCustomTerminalArgumentsKey
        )
        defaults.set(sanitizedSettings.agentReview.agentTool.rawValue, forKey: Self.agentReviewToolKey)
        setStringDictionary(
            Self.stringDictionary(from: sanitizedSettings.agentReview.agentToolOverrides),
            forKey: Self.agentReviewToolOverridesKey
        )
        saveReviewProfiles(sanitizedSettings.agentReview.reviewProfiles)
        saveReviewScopes(sanitizedSettings.agentReview.reviewScopes)
        defaults.set(sanitizedSettings.agentReview.globalPrompt, forKey: Self.agentReviewGlobalPromptKey)
        setStringDictionary(
            sanitizedSettings.agentReview.repositoryPromptOverrides,
            forKey: Self.agentReviewRepositoryPromptOverridesKey
        )
    }

    private static func agentReviewTool(from rawValue: String?) -> AgentReviewTool {
        rawValue.flatMap(AgentReviewTool.init(rawValue:)) ?? .claudeCode
    }

    private static func agentReviewTerminal(from rawValue: String?) -> AgentReviewTerminal {
        rawValue.flatMap(AgentReviewTerminal.init(rawValue:)) ?? .automatic
    }

    private static func menuBarCountScope(from rawValue: String?) -> MenuBarCountScope {
        rawValue.flatMap(MenuBarCountScope.init(rawValue:)) ?? GHMenuBarSettings.default.general.menuBarCountScope
    }

    private static func agentReviewToolOverrides(from values: [String: String]) -> [String: AgentReviewTool] {
        values.reduce(into: [String: AgentReviewTool]()) { overrides, entry in
            guard let tool = AgentReviewTool(rawValue: entry.value) else { return }
            overrides[entry.key] = tool
        }
    }

    private static func stringDictionary(from values: [String: AgentReviewTool]) -> [String: String] {
        values.reduce(into: [String: String]()) { dictionary, entry in
            dictionary[entry.key] = entry.value.rawValue
        }
    }

    private static func repairedReviewScopes(
        _ scopes: [AgentReviewScope],
        includedRepositories: [String]
    ) -> [AgentReviewScope] {
        scopes.map { scope in
            guard scope.patternValidation == .invalid,
                  let scopeBasename = localPathBasename(scope.pattern)
            else {
                return scope
            }

            let matches = includedRepositories.filter { repository in
                AgentReviewScope(pattern: repository).matches(repository: repository)
                    && repositoryBasename(repository)?.caseInsensitiveCompare(scopeBasename) == .orderedSame
            }
            guard matches.count == 1, let repository = matches.first else {
                return scope
            }

            return AgentReviewScope(
                pattern: repository,
                localReview: scope.localReview,
                cloudReview: scope.cloudReview
            )
        }
    }

    private static func localPathBasename(_ pattern: String) -> String? {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedPattern.hasPrefix("/")
                || normalizedPattern.hasPrefix("~/")
                || normalizedPattern.hasPrefix("./")
                || normalizedPattern.hasPrefix("../")
        else {
            return nil
        }

        let basename = (normalizedPattern as NSString).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    private static func repositoryBasename(_ repository: String) -> String? {
        repository.split(separator: "/", maxSplits: 1).last.map(String.init)
    }

    private func reviewProfiles() -> [AgentReviewProfile] {
        guard let data = defaults.data(forKey: Self.agentReviewProfilesKey),
              let profiles = try? JSONDecoder().decode([AgentReviewProfile].self, from: data)
        else {
            return []
        }

        return profiles
    }

    private func saveReviewProfiles(_ profiles: [AgentReviewProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.agentReviewProfilesKey)
    }

    private func reviewScopes() -> [AgentReviewScope] {
        guard let data = defaults.data(forKey: Self.agentReviewScopesKey),
              let scopes = try? JSONDecoder().decode([AgentReviewScope].self, from: data)
        else {
            return []
        }

        return scopes
    }

    private func saveReviewScopes(_ scopes: [AgentReviewScope]) {
        guard let data = try? JSONEncoder().encode(scopes) else { return }
        defaults.set(data, forKey: Self.agentReviewScopesKey)
    }

    private var storedRefreshIntervalSeconds: Int {
        let storedValue = defaults.integer(forKey: Self.refreshIntervalSecondsKey)
        guard storedValue > 0 else { return GHMenuBarSettings.default.refreshIntervalSeconds }
        return storedValue
    }

    private func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private func stringList(forKey key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    private func setStringList(_ values: [String], forKey key: String) {
        defaults.set(values, forKey: key)
    }

    private func stringDictionary(forKey key: String) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func setStringDictionary(_ values: [String: String], forKey key: String) {
        defaults.set(values, forKey: key)
    }
}
