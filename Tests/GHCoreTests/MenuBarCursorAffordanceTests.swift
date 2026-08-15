import Foundation
import XCTest

final class MenuBarCursorAffordanceTests: XCTestCase {
    func testAutomaticRefreshRunsFromAlwaysVisibleMenuBarLabel() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("MenuBarStatusLabel(\n                title: store.menuBarTitle,\n                notification: store.menuBarNotification\n            )\n            .task {\n                await store.runAutomaticRefreshLoop()\n            }"),
            "Automatic refresh must be attached to the always-visible menu bar label so it starts before the user opens the menu."
        )
    }

    func testEveryStyledMenuButtonUsesPointingHandCursor() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)

        let missingCursorLines = lines.indices.compactMap { index -> Int? in
            guard lines[index].contains(".buttonStyle(") else { return nil }

            let endIndex = min(index + 3, lines.count - 1)
            let modifierBlock = lines[index...endIndex].joined(separator: "\n")
            return modifierBlock.contains(".pointingHandCursor()") ? nil : index + 1
        }

        XCTAssertTrue(
            missingCursorLines.isEmpty,
            "Styled menu buttons must use pointingHandCursor(); missing near lines \(missingCursorLines)"
        )
    }

    func testMenuHeaderIncludesGearButtonForSettings() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Image(systemName: \"gearshape\")"))
        XCTAssertTrue(source.contains("@Environment(\\.openWindow) private var openWindow"))
        XCTAssertTrue(source.contains("openWindow(id: Self.settingsWindowID)"))
    }

    func testMenuFooterDoesNotExposeRestartAction() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Button(\"Restart\")"))
        XCTAssertFalse(source.contains("restartApplication()"))
    }

    func testSettingsUseIndependentMacSettingsWindow() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Window(\"Settings\", id: PullRequestMenuView.settingsWindowID)"))
        XCTAssertFalse(source.contains("@Environment(\\.openSettings)"), "MenuBarExtra should open an explicit window instead of relying on the Settings command.")
        XCTAssertFalse(source.contains(".sheet(isPresented:"), "Settings should not be presented as a sheet from MenuBarExtra because the menu closes on interaction.")
    }

    func testSettingsViewExposesPublishableConfigurationFields() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("TextField(\"GitHub owner\""))
        XCTAssertFalse(source.contains("Text(\"Settings\")"))
        XCTAssertTrue(source.contains("Label(\"General\", systemImage: \"slider.horizontal.3\")"))
        XCTAssertTrue(source.contains("Label(\"Repositories\", systemImage: \"folder\")"))
        XCTAssertTrue(source.contains("Label(\"Agent Review\", systemImage: \"sparkles\")"))
        XCTAssertTrue(source.contains("AccountPickerColumn("))
        XCTAssertTrue(source.contains("RepositoryPickerColumn("))
        XCTAssertFalse(source.contains("title: \"Exclude repositories\""))
        XCTAssertTrue(source.contains("AgentReviewScopeEditor("))
        XCTAssertTrue(source.contains("AgentReviewWorkflowCard("))
        XCTAssertTrue(source.contains("modeTitle: \"Local review mode\""))
        XCTAssertTrue(source.contains("CloudReviewUnavailableCard("))
        XCTAssertTrue(source.contains("GHMenuBar does not currently have a cloud review executor."))
        XCTAssertFalse(source.contains("modeTitle: \"Cloud review mode\""))
        XCTAssertFalse(source.contains("TextField(\"Cloud workflow name\""))
        XCTAssertFalse(source.contains("TextField(\"Trigger template\""))
        XCTAssertFalse(source.contains("Toggle(\"Enable agent review\", isOn: $draft.agentReview.isEnabled)"))
        XCTAssertFalse(source.contains("settingsSection(\"Fallback\")"))
        XCTAssertFalse(source.contains("Picker(\"Fallback agent\", selection: $draft.agentReview.agentTool)"))
        XCTAssertFalse(source.contains("TextField(\"Review repository\", text: $draft.agentReview.supportedRepository)"))
        XCTAssertFalse(source.contains("TextField(\"Fallback workspace path\", text: $draft.agentReview.workspacePath)"))
        XCTAssertFalse(source.contains("title: \"Agent tool overrides\""))
        XCTAssertFalse(source.contains("ReviewProfileEditor(profiles: $draft.agentReview.reviewProfiles)"))
        XCTAssertFalse(source.contains("ForEach($profiles)"))
        XCTAssertTrue(source.contains("Label(\"Add scope\", systemImage: \"plus\")"))
        XCTAssertFalse(source.contains("reviewProfilesText"))
        XCTAssertFalse(source.contains("title: \"Review profiles\""))
        XCTAssertFalse(source.contains("DisclosureGroup(\"Advanced prompts\")"))
        XCTAssertFalse(source.contains("title: \"Global prompt\""))
        XCTAssertFalse(source.contains("title: \"Repository prompt overrides\""))
        XCTAssertTrue(source.contains("TextField(\"Refresh interval\", value: $draft.refreshIntervalSeconds, formatter: Self.integerFormatter)"))
        XCTAssertTrue(source.contains("Toggle(\"Automatic refresh\", isOn: $draft.general.isAutomaticRefreshEnabled)"))
        XCTAssertTrue(source.contains("Button(\"Sync now\")"))
        XCTAssertTrue(source.contains("settingsSection(\"GitHub CLI\")"))
        XCTAssertFalse(source.contains("Toggle(\"Show pull request count\", isOn: $draft.general.showsPullRequestCount)"))
        XCTAssertFalse(source.contains("Picker(\"Count includes\", selection: $draft.general.menuBarCountScope)"))
        XCTAssertFalse(source.contains("Toggle(\"Hide count when zero\", isOn: $draft.general.hidesZeroPullRequestCount)"))
        XCTAssertTrue(source.contains("settingsSection(\"Notifications\")"))
        XCTAssertTrue(source.contains("Toggle(\"New pull requests\", isOn: $draft.general.notifiesForNewPullRequests)"))
        XCTAssertTrue(source.contains("Toggle(\"Review requested\", isOn: $draft.general.notifiesForReviewRequests)"))
        XCTAssertTrue(source.contains("Toggle(\"CI failures\", isOn: $draft.general.notifiesForCIFailures)"))
    }

    func testGeneralSettingsUseBalancedAccentColors() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private enum GeneralSettingsPalette"))
        XCTAssertTrue(source.contains("iconColor: GeneralSettingsPalette.sync"))
        XCTAssertTrue(source.contains("iconColor: GeneralSettingsPalette.github"))
        XCTAssertTrue(source.contains("iconColor: GeneralSettingsPalette.notifications"))
        XCTAssertTrue(source.contains(".tint(GeneralSettingsPalette.sync)"))
        XCTAssertTrue(source.contains(".tint(GeneralSettingsPalette.notifications)"))
        XCTAssertFalse(source.contains(".foregroundStyle(Color.accentColor)"))
    }

    func testLoadedMenuBarTitleDoesNotRenderNumericPullRequestCount() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("return count >= 100 ? \"99+\" : \"\\(count)\""))
        XCTAssertFalse(source.contains("guard settings.general.showsPullRequestCount else { return \"PRs\" }"))
        XCTAssertTrue(source.contains("case .loaded:\n            return \"PRs\""))
    }

    func testAgentReviewSettingsUseSeparateLocalAndCloudColors() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private enum AgentReviewPalette"))
        XCTAssertTrue(source.contains("AgentReviewPalette.local"))
        XCTAssertTrue(source.contains("AgentReviewPalette.cloud"))
        XCTAssertTrue(source.contains("AgentReviewPalette.selectedScope"))
        XCTAssertFalse(source.contains(".tint(.pink)"))
        XCTAssertFalse(source.contains("Color.pink"))
    }

    func testAgentReviewModePickerHidesRedundantLabel() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("Picker(modeTitle, selection: $mode) {\n                ForEach(AgentReviewDraftMode.allCases) { mode in\n                    Text(mode.displayName).tag(mode)\n                }\n            }\n            .labelsHidden()\n            .pickerStyle(.segmented)"),
            "The workflow mode segmented picker must hide its label; the card header already identifies the mode, and a visible label collapses vertically in narrow cards."
        )
    }

    func testPullRequestRowsAlwaysExposeAReviewAction() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Text(\"Set Up Review\")"))
        XCTAssertTrue(source.contains("if let configuredAgentTool"))
        XCTAssertTrue(source.contains("Text(\"Review\")"))
        XCTAssertFalse(
            source.contains("if isAgentReviewSupported"),
            "A missing local-review scope should turn the action into configuration guidance, not hide it."
        )
    }

    func testConfiguredReviewActionOffersEveryAgentAndMarksTheDefault() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private static let reviewToolChoices: [AgentReviewTool] = [.claudeCode, .copilot, .codexCLI]"))
        XCTAssertTrue(source.contains("ForEach(Self.reviewToolChoices) { agentTool in"))
        XCTAssertTrue(source.contains("Label(\"\\(agentTool.displayName) (Default)\", systemImage: \"checkmark\")"))
        XCTAssertTrue(source.contains("Text(\"\\(configuredAgentTool.displayName) default\")"))
        XCTAssertTrue(source.contains(".menuStyle(.borderlessButton)"))
    }

    func testReviewMenuPassesOneOffAgentOverrideToLauncher() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("onLaunchAgentReview: { agentTool in"))
        XCTAssertTrue(source.contains("store.launchAgentReview(for: pullRequest, using: agentTool)"))
        XCTAssertTrue(source.contains("func launchAgentReview(for pullRequest: PullRequest, using agentTool: AgentReviewTool)"))
        XCTAssertTrue(source.contains("try await agentReviewLauncher.launchReview(for: pullRequest, using: agentTool)"))
    }

    func testUnconfiguredReviewActionOpensAgentReviewSettings() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("TabView(selection: $selectedTab)"))
        XCTAssertTrue(source.contains(".tag(PullRequestSettingsTab.agentReview)"))
        XCTAssertTrue(
            source.contains("store.selectedSettingsTab = .agentReview\n                                    NSApp.activate(ignoringOtherApps: true)\n                                    openWindow(id: Self.settingsWindowID)")
        )
    }

    func testAgentReviewLaunchFailuresArePresentedVisibly() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("agentReviewLaunchErrorMessage = error.localizedDescription"))
        XCTAssertTrue(source.contains(".alert(\n            \"Couldn’t Start Review\""))
        let launchMethodStart = try XCTUnwrap(
            source.range(of: "func launchAgentReview(for pullRequest: PullRequest, using agentTool: AgentReviewTool) {")
        )
        let nextMethodStart = try XCTUnwrap(
            source.range(
                of: "func configuredAgentReviewTool",
                range: launchMethodStart.upperBound..<source.endIndex
            )
        )
        let launchMethod = source[launchMethodStart.lowerBound..<nextMethodStart.lowerBound]
        XCTAssertFalse(launchMethod.contains("NSSound.beep()"))
    }

    func testLegacyAgentReviewMigrationKeepsPathsOutOfRepositoryScopePatterns() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("pattern: repository"))
        XCTAssertTrue(source.contains("localWorkspacePathTemplate: profile.workspacePath"))
        XCTAssertTrue(source.contains("String(wildcardProfile.pathPattern.dropLast()) + \"{repoName}\""))
        XCTAssertFalse(
            source.contains("pattern: profile.pathPattern"),
            "Legacy filesystem path patterns must remain workspace paths and never become repository scopes."
        )
    }

    func testPersistedPathShapedScopesRepairOnlyUniqueRepositoryBasenameMatches() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Self.repairedStoredScope("))
        XCTAssertTrue(source.contains("includedRepositories: settings.repositoryFilter.includedRepositories"))
        XCTAssertTrue(source.contains("let repositoryBasename = localPathBasename(scope.pattern)"))
        XCTAssertTrue(source.contains("guard matches.count == 1, let repository = matches.first"))
        XCTAssertTrue(source.contains("draft.pattern = repository"))
        XCTAssertTrue(source.contains("draft.localWorkspacePathTemplate = scope.pattern"))
    }

    func testScopePatternValidationExplainsAcceptedFormsAndBlocksInvalidSave() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Accepted forms: *, owner/*, or owner/repo."))
        XCTAssertTrue(source.contains("filesystem paths belong in Workspace."))
        XCTAssertTrue(source.contains("guard agentReview.hasValidScopePatterns else"))
        XCTAssertTrue(source.contains("reviewScopes.allSatisfy(\\.isPatternValid)"))
    }

    func testCloudReviewIsReadOnlyUnavailableAndStoredDataRemainsSerializable() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Label(\"Unavailable\", systemImage: \"cloud.slash\")"))
        XCTAssertTrue(source.contains("Text(\"Coming later\")"))
        XCTAssertTrue(source.contains("Previously saved cloud settings are preserved, but remain inactive."))
        XCTAssertTrue(source.contains("cloudReview: cloudSetting"))
        XCTAssertTrue(source.contains("case .override:\n            return .override(AgentReviewCloudWorkflow("))
        XCTAssertFalse(source.contains("This action is hidden for matching pull requests."))
    }

    func testMenuHidesRepositoryPickerForOneWatchedRepository() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("store.shouldShowRepositoryPicker"))
        XCTAssertTrue(source.contains("settings.repositoryFilter.hasExactlyOneIncludedRepository"))
    }

    func testRefreshButtonCanBootstrapIdleStoreAfterSettingsChange() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.range(
                of: #"case \.idle, \.failed:\s+await loadRepositories\(\)"#,
                options: .regularExpression
            ) != nil,
            "The selected-repository refresh button must load repositories when settings reset the store to idle."
        )
    }

    func testSavingRepositoryFiltersReloadsMenuAutomatically() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.range(
                of: #"if settings\.repositoryFilter != oldSettings\.repositoryFilter \{(?s).*Task \{\s+await loadRepositories\(\)\s+\}"#,
                options: .regularExpression
            ) != nil,
            "Saving selected repositories must immediately reload the menu instead of leaving the store idle until manual refresh."
        )
    }

    func testHeaderUsesSingleSmartRefreshButton() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("store.refreshFromButton()"))
        XCTAssertTrue(source.contains(".help(\"Refresh\")"))
        XCTAssertFalse(source.contains("store.batchRefreshFromButton()"))
        XCTAssertFalse(source.contains("Image(systemName: \"tray.and.arrow.down\")"))
        XCTAssertFalse(source.contains(".help(\"Batch refresh all repositories\")"))
    }

    func testRefreshButtonBatchRefreshesWhenMultipleRepositoriesAreLoaded() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.range(
                of: #"case \.loaded\(let selection, _, _\):\s+if selection\.hasMultipleRepositories \{\s+await batchRefresh\(\)\s+\} else \{\s+await loadSelectedRepository\(force: true\)\s+\}"#,
                options: .regularExpression
            ) != nil,
            "The single refresh button must batch-refresh multi-repository selections and refresh the selected repository otherwise."
        )
    }

    func testRepositoryPickerUsesSelectAllCheckboxAndGuardsSave() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("PickerSelectAllToggle("))
        XCTAssertTrue(source.contains("Toggle(\"Select all\""))
        XCTAssertFalse(source.contains("Button(\"Deselect all\")"))
        XCTAssertTrue(source.contains(".disabled(!draft.canSave)"))
    }

    func testRepositoryPickerClearsLegacyExcludedRepositoriesOnSave() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("excludedRepositoriesText"))
        XCTAssertTrue(source.contains("excludedRepositories: []"))
    }

    func testRepositoryPickerUsesModernColumnChrome() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("PickerColumnHeader("))
        XCTAssertTrue(source.contains("PickerRow("))
        XCTAssertTrue(source.contains("Search accounts"))
        XCTAssertTrue(source.contains("Search repositories"))
        XCTAssertTrue(source.contains("selectionSummary"))
    }

    func testSettingsViewAvoidsCollapsedFormScrolling() throws {
        let sourceURL = try packageRoot().appendingPathComponent("Sources/GHMenuBar/GHMenuBarApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Form {"), "The menu-bar settings sheet should not use Form because it collapses into a tiny scrolling region.")
        XCTAssertTrue(source.contains("ScrollView(.vertical)"))
        XCTAssertTrue(source.contains(".frame(width: 820, height: 720)"))
        XCTAssertFalse(source.contains(".frame(width: 700, height: 560)"))
    }

    private func packageRoot() throws -> URL {
        var currentURL = URL(fileURLWithPath: #filePath)
        while currentURL.path != "/" {
            if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent("Package.swift").path) {
                return currentURL
            }
            currentURL.deleteLastPathComponent()
        }

        throw NSError(
            domain: "MenuBarCursorAffordanceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate Package.swift from \(#filePath)"]
        )
    }
}
