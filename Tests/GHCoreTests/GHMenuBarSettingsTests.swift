import Foundation
import XCTest
@testable import GHCore

final class GHMenuBarSettingsTests: XCTestCase {
    func testDefaultSettingsHavePublishableFallbacks() {
        XCTAssertEqual(
            GHMenuBarSettings.default,
            GHMenuBarSettings(
                githubOwner: "",
                refreshIntervalSeconds: 300,
                general: GeneralSettings(
                    isAutomaticRefreshEnabled: true,
                    showsPullRequestCount: false,
                    menuBarCountScope: .reviewRequests,
                    hidesZeroPullRequestCount: true,
                    notifiesForNewPullRequests: true,
                    notifiesForReviewRequests: true,
                    notifiesForCIFailures: false
                ),
                repositoryFilter: RepositoryFilterSettings(),
                agentReview: AgentReviewSettings(
                    isEnabled: false,
                    supportedRepository: "",
                    workspacePath: "",
                    agentTool: .claudeCode,
                    agentToolOverrides: [:],
                    reviewProfiles: [],
                    globalPrompt: AgentReviewSettings.defaultPrompt,
                    repositoryPromptOverrides: [:]
                )
            )
        )
    }

    func testStoragePersistsSanitizedSettings() throws {
        let suiteName = "GHMenuBarTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = GHMenuBarSettingsStorage(defaults: defaults)

        storage.save(GHMenuBarSettings(
            githubOwner: " acme ",
            refreshIntervalSeconds: 12,
            general: GeneralSettings(
                isAutomaticRefreshEnabled: false,
                showsPullRequestCount: false,
                menuBarCountScope: .failingChecks,
                hidesZeroPullRequestCount: false,
                notifiesForNewPullRequests: false,
                notifiesForReviewRequests: false,
                notifiesForCIFailures: true
            ),
            repositoryFilter: RepositoryFilterSettings(
                organizations: [" acme ", "", "octo"],
                includedRepositories: [" acme/frontend "],
                excludedRepositories: [" acme/legacy "]
            ),
            agentReview: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: " acme/frontend ",
                workspacePath: " /Users/example/acme ",
                terminal: .custom,
                appleTerminalProfile: " Review Zsh ",
                customTerminalExecutable: " /opt/example/bin/terminal ",
                customTerminalArguments: " --new-window\n{script} ",
                agentTool: .copilot,
                agentToolOverrides: [
                    " acme/frontend ": .claudeCode,
                    " acme/* ": .copilot,
                    " ": .copilot
                ],
                reviewProfiles: [
                    AgentReviewProfile(
                        pathPattern: " ~/work/* ",
                        agentTool: .claudeCode,
                        reviewCommand: " /code-review "
                    ),
                    AgentReviewProfile(
                        pathPattern: " * ",
                        agentTool: .codexCLI,
                        reviewCommand: " /review "
                    ),
                    AgentReviewProfile(
                        pathPattern: " ",
                        agentTool: .copilot,
                        reviewCommand: "/ignored"
                    )
                ],
                globalPrompt: " Review carefully ",
                repositoryPromptOverrides: [" acme/frontend ": " Use frontend rules "]
            )
        ))

        XCTAssertEqual(
            storage.settings,
            GHMenuBarSettings(
                githubOwner: "acme",
                refreshIntervalSeconds: 60,
                general: GeneralSettings(
                    isAutomaticRefreshEnabled: false,
                    showsPullRequestCount: false,
                    menuBarCountScope: .failingChecks,
                    hidesZeroPullRequestCount: false,
                    notifiesForNewPullRequests: false,
                    notifiesForReviewRequests: false,
                    notifiesForCIFailures: true
                ),
                repositoryFilter: RepositoryFilterSettings(
                    organizations: ["acme", "octo"],
                    includedRepositories: ["acme/frontend"],
                    excludedRepositories: ["acme/legacy"]
                ),
                agentReview: AgentReviewSettings(
                    isEnabled: true,
                    supportedRepository: "acme/frontend",
                    workspacePath: "/Users/example/acme",
                    terminal: .custom,
                    appleTerminalProfile: "Review Zsh",
                    customTerminalExecutable: "/opt/example/bin/terminal",
                    customTerminalArguments: "--new-window\n{script}",
                    agentTool: .copilot,
                    agentToolOverrides: [
                        "acme/frontend": .claudeCode,
                        "acme/*": .copilot
                    ],
                    reviewProfiles: [
                        AgentReviewProfile(
                            pathPattern: "~/work/*",
                            agentTool: .claudeCode,
                            reviewCommand: "/code-review"
                        ),
                        AgentReviewProfile(
                            pathPattern: "*",
                            agentTool: .codexCLI,
                            reviewCommand: "/review"
                        )
                    ],
                    globalPrompt: "Review carefully",
                    repositoryPromptOverrides: ["acme/frontend": "Use frontend rules"]
                )
            )
        )
    }

    func testStorageFallsBackToClaudeCodeForUnknownOrLegacyAgentTool() throws {
        let suiteName = "GHMenuBarTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("automatic", forKey: GHMenuBarSettingsStorage.agentReviewToolKey)

        XCTAssertEqual(
            GHMenuBarSettingsStorage(defaults: defaults).settings.agentReview.agentTool,
            .claudeCode
        )
    }

    func testStorageFallsBackToAutomaticForUnknownOrMissingReviewTerminal() throws {
        let suiteName = "GHMenuBarTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = GHMenuBarSettingsStorage(defaults: defaults)

        XCTAssertEqual(storage.settings.agentReview.terminal, .automatic)

        defaults.set("future-terminal", forKey: GHMenuBarSettingsStorage.agentReviewTerminalKey)
        XCTAssertEqual(storage.settings.agentReview.terminal, .automatic)
    }

    func testRepositoryFilterAppliesOrganizationsIncludeAndExclude() {
        let filter = RepositoryFilterSettings(
            organizations: ["acme"],
            includedRepositories: ["acme/frontend", "other/app"],
            excludedRepositories: ["acme/legacy"]
        )

        XCTAssertEqual(
            filter.filteredRepositories([
                "acme/frontend",
                "acme/legacy",
                "acme/backend",
                "other/app"
            ]),
            ["acme/frontend"]
        )
    }

    func testRepositoryFilterUsesAllRepositoriesWhenListsAreEmpty() {
        XCTAssertEqual(
            RepositoryFilterSettings().filteredRepositories(["acme/frontend", "other/app"]),
            ["acme/frontend", "other/app"]
        )
    }

    func testAgentReviewPromptUsesRepositoryOverrideBeforeGlobalPrompt() {
        let settings = AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/acme",
            globalPrompt: "Global review prompt",
            repositoryPromptOverrides: ["acme/frontend": "Frontend review prompt"]
        )

        XCTAssertEqual(settings.promptInstruction(for: "acme/frontend"), "Frontend review prompt")
        XCTAssertEqual(settings.promptInstruction(for: "acme/backend"), "Global review prompt")
    }

    func testAgentReviewToolUsesRepositoryOverrideBeforeOrganizationAndGlobalTool() {
        let settings = AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "/Users/example/acme",
            agentTool: .claudeCode,
            agentToolOverrides: [
                "acme/*": .copilot,
                "acme/frontend": .claudeCode
            ]
        )

        XCTAssertEqual(settings.agentTool(for: "acme/frontend"), .claudeCode)
        XCTAssertEqual(settings.agentTool(for: "acme/backend"), .copilot)
        XCTAssertEqual(settings.agentTool(for: "other/app"), .claudeCode)
    }

    func testAgentReviewToolCanParseUserFacingToolNames() {
        XCTAssertEqual(AgentReviewTool(userFacingName: "Copilot"), .copilot)
        XCTAssertEqual(AgentReviewTool(userFacingName: "GitHub Copilot"), .copilot)
        XCTAssertEqual(AgentReviewTool(userFacingName: "Claude Code"), .claudeCode)
        XCTAssertEqual(AgentReviewTool(userFacingName: "Codex CLI"), .codexCLI)
    }

    func testAgentReviewScopesResolveLocalAndCloudIndependently() {
        let settings = AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "*",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .codexCLI,
                        workspacePathTemplate: "~/work/{repoName}",
                        promptTemplate: "$requesting-code-review {pr}"
                    )),
                    cloudReview: .disabled
                ),
                AgentReviewScope(
                    pattern: "acme/*",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .claudeCode,
                        workspacePathTemplate: "~/acme/{repoName}",
                        promptTemplate: "/code-review {pr}"
                    )),
                    cloudReview: .override(AgentReviewCloudWorkflow(
                        workflowName: "Acme cloud review",
                        triggerTemplate: "@codex review for {pr}",
                        readinessRequirements: "Codex cloud enabled"
                    ))
                ),
                AgentReviewScope(
                    pattern: "acme/frontend",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .claudeCode,
                        workspacePathTemplate: "~/acme/frontend",
                        promptTemplate: "/frontend-code-review {pr}"
                    )),
                    cloudReview: .disabled
                )
            ]
        )

        XCTAssertEqual(
            settings.localReviewWorkflow(for: "acme/frontend")?.promptTemplate,
            "/frontend-code-review {pr}"
        )
        XCTAssertNil(settings.cloudReviewWorkflow(for: "acme/frontend"))
        XCTAssertEqual(
            settings.localReviewWorkflow(for: "acme/service")?.workspacePathTemplate,
            "~/acme/{repoName}"
        )
        XCTAssertEqual(
            settings.cloudReviewWorkflow(for: "acme/service")?.workflowName,
            "Acme cloud review"
        )
        XCTAssertEqual(
            settings.localReviewWorkflow(for: "other/app")?.agentTool,
            .codexCLI
        )
        XCTAssertNil(settings.cloudReviewWorkflow(for: "other/app"))
    }

    func testAgentReviewScopePatternValidationAcceptsRepositorySyntax() {
        XCTAssertEqual(AgentReviewScope(pattern: "*").patternValidation, .valid)
        XCTAssertEqual(AgentReviewScope(pattern: " acme/* ").patternValidation, .valid)
        XCTAssertEqual(AgentReviewScope(pattern: "acme/frontend").patternValidation, .valid)
        XCTAssertEqual(AgentReviewScope(pattern: "acme/frontend.swift").patternValidation, .valid)
    }

    func testAgentReviewScopePatternValidationDistinguishesUnconfiguredAndInvalidPatterns() {
        XCTAssertEqual(AgentReviewScope(pattern: "  ").patternValidation, .unconfigured)

        let invalidPatterns = [
            "~/work/frontend",
            "~/work/*",
            "/Users/example/frontend",
            "acme",
            "acme/",
            "acme/frontend/extra",
            "acme/front end",
            "acme*",
            "*/frontend",
            "acme/front*",
            "acmé/frontend"
        ]

        for pattern in invalidPatterns {
            XCTAssertEqual(
                AgentReviewScope(pattern: pattern).patternValidation,
                .invalid,
                "Expected \(pattern) to be invalid"
            )
        }
    }

    func testAgentReviewScopeMatchesOnlyValidRepositoryIdentifiers() {
        XCTAssertTrue(AgentReviewScope(pattern: "*").matches(repository: "acme/frontend"))
        XCTAssertTrue(AgentReviewScope(pattern: "acme/*").matches(repository: "acme/backend"))
        XCTAssertFalse(AgentReviewScope(pattern: "acme/*").matches(repository: "other/backend"))
        XCTAssertTrue(AgentReviewScope(pattern: "acme/frontend").matches(repository: "acme/frontend"))

        XCTAssertFalse(
            AgentReviewScope(pattern: "~/work/*").matches(repository: "~/work/frontend")
        )
        XCTAssertFalse(
            AgentReviewScope(pattern: "/Users/example/frontend")
                .matches(repository: "/Users/example/frontend")
        )
        XCTAssertFalse(AgentReviewScope(pattern: "*").matches(repository: "~/work/frontend"))
    }

    func testAgentReviewScopeResolutionReportsConfigurationAndSupportStates() {
        let unconfigured = AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: ""
        )
        XCTAssertEqual(
            unconfigured.reviewScopeResolution(for: "acme/frontend"),
            .unconfigured
        )

        let configured = AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [AgentReviewScope(pattern: "acme/*")]
        )
        XCTAssertEqual(
            configured.reviewScopeResolution(for: "acme/frontend"),
            .supported
        )
        XCTAssertEqual(
            configured.reviewScopeResolution(for: "other/frontend"),
            .unsupported
        )

        let invalid = AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(pattern: "acme/*"),
                AgentReviewScope(pattern: "~/work/frontend")
            ]
        )
        XCTAssertEqual(
            invalid.reviewScopeResolution(for: "acme/frontend"),
            .invalid(patterns: ["~/work/frontend"])
        )
    }

    func testInvalidScopeRemainsCodableButNeverParticipatesInMatching() throws {
        let scope = AgentReviewScope(
            pattern: "~/work/frontend",
            localReview: .disabled,
            cloudReview: .inherit
        )

        let data = try JSONEncoder().encode(scope)
        XCTAssertEqual(try JSONDecoder().decode(AgentReviewScope.self, from: data), scope)

        let settings = AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: "",
            reviewScopes: [
                AgentReviewScope(
                    pattern: "*",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .codexCLI,
                        workspacePathTemplate: "~/work/{repoName}",
                        promptTemplate: "/review {pr}"
                    ))
                ),
                AgentReviewScope(
                    pattern: "~/work/*",
                    localReview: .disabled
                )
            ]
        )

        XCTAssertEqual(
            settings.localReviewWorkflow(for: "acme/frontend")?.promptTemplate,
            "/review {pr}"
        )
    }

    func testStoragePersistsAgentReviewScopes() throws {
        let suiteName = "GHMenuBarTests.AgentReviewScopes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = GHMenuBarSettingsStorage(defaults: defaults)

        storage.save(GHMenuBarSettings(
            githubOwner: "",
            refreshIntervalSeconds: 300,
            agentReview: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "",
                workspacePath: "",
                reviewScopes: [
                    AgentReviewScope(
                        pattern: " acme/* ",
                        localReview: .override(AgentReviewLocalWorkflow(
                            agentTool: .claudeCode,
                            codexModel: " gpt-5.6-sol ",
                            claudeModel: " claude-opus-5 ",
                            copilotModel: " auto ",
                            workspacePathTemplate: " ~/acme/{repoName} ",
                            promptRootPathTemplate: " ~/acme ",
                            worktreeRootPathTemplate: " ~/.reviews/{repoName} ",
                            promptTemplate: " /code-review {pr} "
                        )),
                        cloudReview: .override(AgentReviewCloudWorkflow(
                            workflowName: " Acme cloud ",
                            triggerTemplate: " @codex review for {pr} ",
                            readinessRequirements: " Codex cloud enabled "
                        ))
                    )
                ]
            )
        ))

        XCTAssertEqual(
            storage.settings.agentReview.reviewScopes,
            [
                AgentReviewScope(
                    pattern: "acme/*",
                    localReview: .override(AgentReviewLocalWorkflow(
                        agentTool: .claudeCode,
                        codexModel: "gpt-5.6-sol",
                        claudeModel: "claude-opus-5",
                        copilotModel: "auto",
                        workspacePathTemplate: "~/acme/{repoName}",
                        promptRootPathTemplate: "~/acme",
                        worktreeRootPathTemplate: "~/.reviews/{repoName}",
                        promptTemplate: "/code-review {pr}"
                    )),
                    cloudReview: .override(AgentReviewCloudWorkflow(
                        workflowName: "Acme cloud",
                        triggerTemplate: "@codex review for {pr}",
                        readinessRequirements: "Codex cloud enabled"
                    ))
                )
            ]
        )
    }

    func testLocalWorkflowRetainsIndependentModelsForEveryRunner() {
        let workflow = AgentReviewLocalWorkflow(
            agentTool: .copilot,
            codexModel: "gpt-5.6-sol",
            claudeModel: "claude-opus-5",
            copilotModel: "auto",
            workspacePathTemplate: "~/work/{repoName}",
            promptTemplate: "/review {pr}"
        )

        XCTAssertEqual(workflow.model(for: .codexCLI), "gpt-5.6-sol")
        XCTAssertEqual(workflow.model(for: .claudeCode), "claude-opus-5")
        XCTAssertEqual(workflow.model(for: .copilot), "auto")
    }

    func testLegacyLocalWorkflowJSONDecodesWithoutModelSelections() throws {
        let data = try XCTUnwrap(
            """
            {
              "agentTool": "copilot",
              "workspacePathTemplate": "~/work/{repoName}",
              "promptTemplate": "/review {pr}"
            }
            """.data(using: .utf8)
        )

        let workflow = try JSONDecoder().decode(AgentReviewLocalWorkflow.self, from: data)

        XCTAssertNil(workflow.model(for: .codexCLI))
        XCTAssertNil(workflow.model(for: .claudeCode))
        XCTAssertNil(workflow.model(for: .copilot))
        XCTAssertNil(workflow.worktreeRootPathTemplate)
    }

    func testStorageRepairsAndPersistsUniquePathScopeMatchWithoutChangingWorkflow() throws {
        let suiteName = "GHMenuBarTests.AgentReviewScopeRepair.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = GHMenuBarSettingsStorage(defaults: defaults)
        let localWorkflow = AgentReviewLocalWorkflow(
            agentTool: .claudeCode,
            workspacePathTemplate: "~/workspaces/preserved-frontend",
            promptRootPathTemplate: "~/workspaces",
            promptTemplate: "/frontend-review {pr}"
        )
        let cloudWorkflow = AgentReviewCloudWorkflow(
            workflowName: "Frontend cloud review",
            triggerTemplate: "@codex review {pr}",
            readinessRequirements: "Cloud environment ready"
        )

        storage.save(GHMenuBarSettings(
            githubOwner: "",
            refreshIntervalSeconds: 300,
            repositoryFilter: RepositoryFilterSettings(
                        includedRepositories: ["acme/frontend", "acme/service"]
            ),
            agentReview: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "",
                workspacePath: "",
                reviewScopes: [
                    AgentReviewScope(
                        pattern: "~/work/frontend",
                        localReview: .override(localWorkflow),
                        cloudReview: .override(cloudWorkflow)
                    )
                ]
            )
        ))

        let repairedSettings = storage.settings
        let repairedScope = try XCTUnwrap(repairedSettings.agentReview.reviewScopes.first)
                    XCTAssertEqual(repairedScope.pattern, "acme/frontend")
        XCTAssertEqual(repairedScope.localReview, .override(localWorkflow))
        XCTAssertEqual(repairedScope.cloudReview, .override(cloudWorkflow))

        let persistedData = try XCTUnwrap(
            defaults.data(forKey: GHMenuBarSettingsStorage.agentReviewScopesKey)
        )
        XCTAssertEqual(
            try JSONDecoder().decode([AgentReviewScope].self, from: persistedData),
            [repairedScope]
        )
        XCTAssertEqual(storage.settings.agentReview.reviewScopes, [repairedScope])
    }

    func testStorageLeavesPathScopeInvalidWithoutUniqueRepositoryBasenameMatch() throws {
        let suiteName = "GHMenuBarTests.AgentReviewScopeAmbiguity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = GHMenuBarSettingsStorage(defaults: defaults)
        let scopes = [
                AgentReviewScope(pattern: "~/work/shared"),
            AgentReviewScope(pattern: "/work/missing"),
            AgentReviewScope(pattern: "shared")
        ]

        storage.save(GHMenuBarSettings(
            githubOwner: "",
            refreshIntervalSeconds: 300,
            repositoryFilter: RepositoryFilterSettings(
                includedRepositories: [
                    "first/shared",
                    "second/shared",
                    "first/other",
                    "not-a-repository"
                ]
            ),
            agentReview: AgentReviewSettings(
                isEnabled: true,
                supportedRepository: "",
                workspacePath: "",
                reviewScopes: scopes
            )
        ))

        XCTAssertEqual(storage.settings.agentReview.reviewScopes, scopes)
        XCTAssertEqual(
            storage.settings.agentReview.reviewScopeResolution(for: "first/shared"),
            .invalid(patterns: scopes.map(\.pattern))
        )
    }

    func testReviewProfileChoosesExactPathBeforeWildcardAndFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHMenuBarProfiles-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let frontend = work.appendingPathComponent("frontend", isDirectory: true)
        let backend = work.appendingPathComponent("service", isDirectory: true)
        try FileManager.default.createDirectory(at: frontend, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AgentReviewSettings(
            isEnabled: true,
            supportedRepository: "",
            workspacePath: root.appendingPathComponent("outside", isDirectory: true).path,
            reviewProfiles: [
                AgentReviewProfile(
                    pathPattern: frontend.path,
                    agentTool: .claudeCode,
                    reviewCommand: "/frontend-code-review"
                ),
                AgentReviewProfile(
                    pathPattern: work.appendingPathComponent("*").path,
                    agentTool: .claudeCode,
                    reviewCommand: "/code-review"
                ),
                AgentReviewProfile(
                    pathPattern: "*",
                    agentTool: .codexCLI,
                    reviewCommand: "/review"
                )
            ]
        )

        XCTAssertEqual(
            settings.reviewProfile(for: "acme/frontend")?.workspacePath,
            frontend.path
        )
        XCTAssertEqual(
            settings.reviewProfile(for: "acme/frontend")?.reviewCommand,
            "/frontend-code-review"
        )
        XCTAssertEqual(
            settings.reviewProfile(for: "acme/service")?.workspacePath,
            backend.path
        )
        XCTAssertEqual(
            settings.reviewProfile(for: "acme/service")?.reviewCommand,
            "/code-review"
        )
        XCTAssertEqual(
            settings.reviewProfile(for: "acme/other")?.workspacePath,
            root.appendingPathComponent("outside", isDirectory: true).path
        )
        XCTAssertEqual(
            settings.reviewProfile(for: "acme/other")?.agentTool,
            .codexCLI
        )
    }
}
