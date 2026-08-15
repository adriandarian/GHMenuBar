import AppKit
import GHCore
import SwiftUI

@main
struct GHMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PullRequestStore()

    var body: some Scene {
        MenuBarExtra {
            PullRequestMenuView(store: store)
                .frame(width: 380)
        } label: {
            MenuBarStatusLabel(
                title: store.menuBarTitle,
                notification: store.menuBarNotification
            )
            .task {
                await store.runAutomaticRefreshLoop()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: PullRequestMenuView.settingsWindowID) {
            PullRequestSettingsView(
                settings: store.settings,
                selectedTab: $store.selectedSettingsTab,
                authenticationStatus: store.authenticationStatus,
                currentUserLogin: store.currentUserLogin,
                lastUpdated: store.lastUpdated,
                onSyncNow: {
                    store.refreshFromButton()
                }
            ) { settings in
                store.saveSettings(settings)
            }
        }
        .windowResizability(.contentSize)
    }
}

struct MenuBarStatusLabel: View {
    let title: String
    let notification: PullRequestMenuBarNotification

    var body: some View {
        let image = MenuBarStatusImage.image(title: title, notification: notification)
        Image(nsImage: image)
            .frame(width: image.size.width, height: image.size.height)
    }
}

enum MenuBarStatusImage {
    private static let height: CGFloat = 18
    private static let iconSize: CGFloat = 18
    private static let spacing: CGFloat = 5
    private static let dotSize: CGFloat = 7

    static func image(title: String, notification: PullRequestMenuBarNotification) -> NSImage {
        let fallbackLabel = title == "PRs" ? nil : title
        let fallbackWidth = fallbackLabel.map { ceil(labelSize($0).width) } ?? 0
        let overlayWidth = notification.showsDot ? dotSize : 0
        let overlayX = badgeOriginX(width: overlayWidth)
        let width: CGFloat

        if overlayWidth > 0 {
            width = max(iconSize, overlayX + overlayWidth)
        } else if fallbackLabel != nil {
            width = iconSize + spacing + fallbackWidth
        } else {
            width = iconSize
        }

        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            drawSymbol(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))

            if notification.showsDot {
                drawDot()
            } else if let fallbackLabel {
                drawLabel(fallbackLabel, at: NSPoint(x: iconSize + spacing, y: 1.5))
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    private static func labelSize(_ label: String) -> NSSize {
        label.size(withAttributes: fallbackLabelAttributes)
    }

    private static func badgeOriginX(width: CGFloat) -> CGFloat {
        iconSize - width * 0.45
    }

    private static func drawSymbol(in rect: NSRect) {
        guard let symbol = NSImage(
            systemSymbolName: "arrow.triangle.pull",
            accessibilityDescription: "Pull requests"
        ) else {
            return
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let configuredSymbol = symbol.withSymbolConfiguration(configuration) ?? symbol
        let symbolRect = NSRect(
            x: rect.midX - 7.5,
            y: rect.midY - 7.5,
            width: 15,
            height: 15
        )

        guard let cgImage = configuredSymbol.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = NSGraphicsContext.current?.cgContext
        else {
            NSColor.white.set()
            configuredSymbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        context.saveGState()
        context.clip(to: symbolRect, mask: cgImage)
        NSColor.white.setFill()
        context.fill(symbolRect)
        context.restoreGState()
    }

    private static func drawDot() {
        let dotRect = NSRect(
            x: badgeOriginX(width: dotSize),
            y: height - dotSize - 2,
            width: dotSize,
            height: dotSize
        )

        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    private static func drawLabel(_ label: String, at point: NSPoint) {
        label.draw(at: point, withAttributes: fallbackLabelAttributes)
    }

    private static var fallbackLabelAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                if isInside, isEnabled, !isHovering {
                    NSCursor.pointingHand.push()
                    isHovering = true
                } else if (!isInside || !isEnabled), isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .onChange(of: isEnabled) { _, newIsEnabled in
                if !newIsEnabled, isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

@MainActor
final class PullRequestStore: ObservableObject {
    enum LoadState {
        case idle
        case loadingRepositories
        case loaded(PullRequestRepositorySelection, isLoadingSelectedRepository: Bool, isBatchRefreshing: Bool)
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var currentUserLogin: String?
    @Published private(set) var authenticationStatus: GitHubAuthenticationStatus = .unknown
    @Published private(set) var settings: GHMenuBarSettings
    @Published var selectedSettingsTab: PullRequestSettingsTab = .general
    @Published private(set) var agentReviewLaunchErrorMessage: String?

    private var client: GitHubCLI
    private var agentReviewLauncher: PullRequestAgentReviewLauncher
    private let settingsStorage: GHMenuBarSettingsStorage
    private let selectedRepositoryMemory: SelectedRepositoryMemory
    private var hasLoaded = false
    private var repositories: [String] = []
    private var cachedPullRequestsByRepository: [String: [PullRequest]] = [:]

    init(
        settingsStorage: GHMenuBarSettingsStorage = GHMenuBarSettingsStorage(),
        selectedRepositoryMemory: SelectedRepositoryMemory = SelectedRepositoryMemory()
    ) {
        let settings = settingsStorage.settings
        self.settings = settings
        self.client = GitHubCLI(settings: settings)
        self.agentReviewLauncher = PullRequestAgentReviewLauncher(settings: settings.agentReview)
        self.settingsStorage = settingsStorage
        self.selectedRepositoryMemory = selectedRepositoryMemory
    }

    var menuBarTitle: String {
        switch state {
        case .loaded:
            return "PRs"
        case .failed:
            return "!"
        case .idle, .loadingRepositories:
            return "PRs"
        }
    }

    var menuBarNotification: PullRequestMenuBarNotification {
        return PullRequestMenuBarNotification(count: visiblePullRequests.count)
    }

    var selection: PullRequestRepositorySelection? {
        guard case .loaded(let selection, _, _) = state else { return nil }
        return selection
    }

    var visiblePullRequests: [PullRequest] {
        selection?.visiblePullRequestsRequiringReview(from: currentUserLogin) ?? []
    }

    var shouldShowRepositoryPicker: Bool {
        guard !settings.repositoryFilter.hasExactlyOneIncludedRepository else {
            return false
        }

        return selection?.hasMultipleRepositories ?? false
    }

    var isLoadingSelectedRepository: Bool {
        guard case .loaded(_, let isLoadingSelectedRepository, _) = state else { return false }
        return isLoadingSelectedRepository
    }

    var isBatchRefreshing: Bool {
        guard case .loaded(_, _, let isBatchRefreshing) = state else { return false }
        return isBatchRefreshing
    }

    func refreshIfNeeded() async {
        guard !hasLoaded else { return }
        await loadRepositories()
    }

    func runAutomaticRefreshLoop() async {
        if settings.general.isAutomaticRefreshEnabled {
            await refreshAutomatically()
        }

        while !Task.isCancelled {
            do {
                let interval = settings.general.isAutomaticRefreshEnabled ? settings.refreshIntervalSeconds : 60
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }

            guard settings.general.isAutomaticRefreshEnabled else { continue }
            await refreshAutomatically()
        }
    }

    func loadRepositories() async {
        hasLoaded = true
        let selectedRepository = selection?.selectedRepository ?? selectedRepositoryMemory.selectedRepository
        state = .loadingRepositories

        do {
            await updateAuthenticationStatus()
            repositories = try await fetchConfiguredRepositories()
            let selection = makeSelection(selectedRepository: selectedRepository)
            state = .loaded(selection, isLoadingSelectedRepository: true, isBatchRefreshing: false)
            selectedRepositoryMemory.saveSelectedRepository(selection.selectedRepository)
            lastUpdated = Date()
            await loadSelectedRepository(force: false)
        } catch {
            state = .failed(error.localizedDescription)
            lastUpdated = Date()
        }
    }

    func refreshFromButton() {
        Task {
            switch state {
            case .loaded(let selection, _, _):
                if selection.hasMultipleRepositories {
                    await batchRefresh()
                } else {
                    await loadSelectedRepository(force: true)
                }
            case .idle, .failed:
                await loadRepositories()
            case .loadingRepositories:
                break
            }
        }
    }

    func launchAgentReview(for pullRequest: PullRequest, using agentTool: AgentReviewTool) {
        agentReviewLaunchErrorMessage = nil
        Task {
            do {
                try await agentReviewLauncher.launchReview(for: pullRequest, using: agentTool)
            } catch {
                agentReviewLaunchErrorMessage = error.localizedDescription
            }
        }
    }

    func configuredAgentReviewTool(for pullRequest: PullRequest) -> AgentReviewTool? {
        guard agentReviewLauncher.isSupported(pullRequest: pullRequest) else {
            return nil
        }

        return settings.agentReview.reviewProfile(for: pullRequest.repository)?.agentTool
    }

    func clearAgentReviewLaunchError() {
        agentReviewLaunchErrorMessage = nil
    }

    func saveSettings(_ newSettings: GHMenuBarSettings) {
        let oldSettings = settings
        settingsStorage.save(newSettings)
        settings = settingsStorage.settings
        client = GitHubCLI(settings: settings)
        agentReviewLauncher = PullRequestAgentReviewLauncher(settings: settings.agentReview)

        if settings.repositoryFilter != oldSettings.repositoryFilter {
            selectedRepositoryMemory.saveSelectedRepository(nil)
            repositories = []
            cachedPullRequestsByRepository = [:]
            hasLoaded = false
            state = .idle
            lastUpdated = nil
            Task {
                await loadRepositories()
            }
        }
    }

    func selectNextRepository() {
        updateLoadedSelection { $0.selectNextRepository() }
        loadSelectedRepositoryFromSelection()
    }

    func selectPreviousRepository() {
        updateLoadedSelection { $0.selectPreviousRepository() }
        loadSelectedRepositoryFromSelection()
    }

    func selectRepository(_ repository: String) {
        updateLoadedSelection { $0.selectRepository(repository) }
        loadSelectedRepositoryFromSelection()
    }

    private func updateLoadedSelection(_ update: (inout PullRequestRepositorySelection) -> Void) {
        guard case .loaded(var selection, _, let isBatchRefreshing) = state else { return }
        update(&selection)
        state = .loaded(selection, isLoadingSelectedRepository: false, isBatchRefreshing: isBatchRefreshing)
        selectedRepositoryMemory.saveSelectedRepository(selection.selectedRepository)
    }

    private func loadSelectedRepositoryFromSelection() {
        Task {
            await loadSelectedRepository(force: false)
        }
    }

    private func refreshAutomatically() async {
        switch state {
        case .loaded:
            await loadSelectedRepository(force: true)
        case .idle, .loadingRepositories, .failed:
            await loadRepositories()
        }
    }

    private func loadSelectedRepository(force: Bool) async {
        guard let selectedRepository = selection?.selectedRepository else { return }

        if !force,
           let cachedPullRequests = cachedPullRequestsByRepository[selectedRepository],
           cachedPullRequests.allSatisfy(\.hasReviewMetadata) {
            state = .loaded(makeSelection(selectedRepository: selectedRepository), isLoadingSelectedRepository: false, isBatchRefreshing: isBatchRefreshing)
            return
        }

        state = .loaded(makeSelection(selectedRepository: selectedRepository), isLoadingSelectedRepository: true, isBatchRefreshing: isBatchRefreshing)

        do {
            await updateAuthenticationStatus()
            let pullRequests = try await client.fetchOpenPullRequests(repository: selectedRepository)
            cachedPullRequestsByRepository[selectedRepository] = pullRequests

            guard selection?.selectedRepository == selectedRepository else { return }

            state = .loaded(makeSelection(selectedRepository: selectedRepository), isLoadingSelectedRepository: false, isBatchRefreshing: isBatchRefreshing)
            lastUpdated = Date()
        } catch {
            guard selection?.selectedRepository == selectedRepository else { return }

            state = .failed(error.localizedDescription)
            lastUpdated = Date()
        }
    }

    private func batchRefresh() async {
        guard case .loaded(let selection, let isLoadingSelectedRepository, _) = state else {
            await loadRepositories()
            return
        }

        state = .loaded(selection, isLoadingSelectedRepository: isLoadingSelectedRepository, isBatchRefreshing: true)

        do {
            await updateAuthenticationStatus()
            let pullRequests = try await fetchConfiguredOpenPullRequests()
            cachedPullRequestsByRepository = Dictionary(grouping: pullRequests, by: \.repository)

            let selectedRepository = selection.selectedRepository
            state = .loaded(makeSelection(selectedRepository: selectedRepository), isLoadingSelectedRepository: false, isBatchRefreshing: false)
            lastUpdated = Date()
            await loadSelectedRepository(force: false)
        } catch {
            state = .failed(error.localizedDescription)
            lastUpdated = Date()
        }
    }

    private func makeSelection(selectedRepository: String?) -> PullRequestRepositorySelection {
        let filteredRepositories = settings.repositoryFilter.filteredRepositories(repositories)
        return PullRequestRepositorySelection(
            pullRequests: cachedPullRequestsByRepository.values
                .flatMap { $0 }
                .filter { settings.repositoryFilter.allows(repository: $0.repository) },
            selectedRepository: selectedRepository,
            repositories: filteredRepositories
        )
    }

    private func fetchConfiguredRepositories() async throws -> [String] {
        let organizations = settings.repositoryFilter.organizations
        let repositories: [String]

        if organizations.isEmpty {
            repositories = try await client.fetchRepositories()
        } else {
            var scopedRepositories: [String] = []
            for organization in organizations {
                scopedRepositories.append(contentsOf: try await client.fetchRepositories(owner: organization))
            }
            repositories = Array(Set(scopedRepositories)).sorted()
        }

        return settings.repositoryFilter.filteredRepositories(repositories)
    }

    private func fetchConfiguredOpenPullRequests() async throws -> [PullRequest] {
        let organizations = settings.repositoryFilter.organizations
        let pullRequests: [PullRequest]

        if organizations.isEmpty {
            pullRequests = try await client.fetchOpenPullRequests()
        } else {
            var scopedPullRequests: [PullRequest] = []
            for organization in organizations {
                scopedPullRequests.append(contentsOf: try await client.fetchOpenPullRequests(owner: organization))
            }
            pullRequests = scopedPullRequests
        }

        return pullRequests.filter { settings.repositoryFilter.allows(repository: $0.repository) }
    }

    private func updateAuthenticationStatus() async {
        authenticationStatus = await client.authenticationStatus()

        if case .authenticated(let login) = authenticationStatus {
            currentUserLogin = login
        } else {
            currentUserLogin = nil
        }
    }
}

struct PullRequestMenuView: View {
    static let settingsWindowID = "settings"

    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: PullRequestStore
    @State private var repositorySearch = ""
    @State private var repositorySearchNavigation = PullRequestRepositorySearchNavigation(matchCount: 0)
    private static let maximumVisiblePullRequestRows = 7
    private static let estimatedPullRequestRowHeight: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)

            Divider()

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)

            Divider()

            footer
                .padding(14)
        }
        .alert(
            "Couldn’t Start Review",
            isPresented: Binding(
                get: { store.agentReviewLaunchErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.clearAgentReviewLaunchError()
                    }
                }
            )
        ) {
            Button("OK") {
                store.clearAgentReviewLaunchError()
            }
        } message: {
            Text(store.agentReviewLaunchErrorMessage ?? "The review agent could not be launched.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 16, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub Pull Requests")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                AuthenticationStatusBadge(status: store.authenticationStatus)

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: Self.settingsWindowID)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
                .help("Settings")

                Button {
                    store.refreshFromButton()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
                .help("Refresh")
            }

            repositoryPicker
        }
    }

    @ViewBuilder
    private var repositoryPicker: some View {
        if let selection = store.selection,
           store.shouldShowRepositoryPicker,
           let selectedRepository = selection.selectedRepositoryName {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        store.selectPreviousRepository()
                        repositorySearch = ""
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
                    .disabled(!selection.hasMultipleRepositories)
                    .help("Previous repository")

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField(
                            "Search repositories",
                            text: $repositorySearch,
                            prompt: Text(selectedRepository)
                        )
                        .textFieldStyle(.plain)
                        .onSubmit {
                            selectHighlightedRepository(from: selection)
                        }
                        .onMoveCommand { direction in
                            moveHighlightedRepository(direction, in: selection)
                        }
                        .onChange(of: repositorySearch) {
                            resetRepositorySearchNavigation(for: selection)
                        }

                        if !repositorySearch.isEmpty {
                            Button {
                                repositorySearch = ""
                                repositorySearchNavigation.update(matchCount: 0)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .pointingHandCursor()
                            .help("Clear repository search")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                    Button {
                        store.selectNextRepository()
                        repositorySearch = ""
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
                    .disabled(!selection.hasMultipleRepositories)
                    .help("Next repository")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                searchResults(for: selection)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func searchResults(for selection: PullRequestRepositorySelection) -> some View {
        let query = repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let matches = repositoryMatches(for: selection)
            if matches.isEmpty {
                Text("No matching repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches.indices, id: \.self) { index in
                        let match = matches[index]
                        Button {
                            store.selectRepository(match.repository)
                            repositorySearch = ""
                            repositorySearchNavigation.update(matchCount: 0)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: match.repository == selection.selectedRepository ? "checkmark" : "folder")
                                    .frame(width: 14)
                                    .foregroundStyle(.secondary)

                                Text(match.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()
                            }
                            .font(.caption)
                            .contentShape(Rectangle())
                            .padding(.vertical, 3)
                            .background(
                                index == repositorySearchNavigation.highlightedIndex ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
                .padding(.leading, 28)
            }
        }
    }

    private func repositoryMatches(for selection: PullRequestRepositorySelection) -> [PullRequestRepositoryMatch] {
        let query = repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Array(selection.repositoryMatches(matching: query).prefix(6))
    }

    private func resetRepositorySearchNavigation(for selection: PullRequestRepositorySelection) {
        repositorySearchNavigation = PullRequestRepositorySearchNavigation(matchCount: repositoryMatches(for: selection).count)
    }

    private func moveHighlightedRepository(_ direction: MoveCommandDirection, in selection: PullRequestRepositorySelection) {
        repositorySearchNavigation.update(matchCount: repositoryMatches(for: selection).count)

        switch direction {
        case .up:
            repositorySearchNavigation.moveUp()
        case .down:
            repositorySearchNavigation.moveDown()
        default:
            break
        }
    }

    private func selectHighlightedRepository(from selection: PullRequestRepositorySelection) {
        let matches = repositoryMatches(for: selection)
        repositorySearchNavigation.update(matchCount: matches.count)

        guard let highlightedIndex = repositorySearchNavigation.highlightedIndex,
              matches.indices.contains(highlightedIndex)
        else {
            return
        }

        store.selectRepository(matches[highlightedIndex].repository)
        repositorySearch = ""
        repositorySearchNavigation.update(matchCount: 0)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle:
            StateRow(symbol: "arrow.clockwise", title: "Ready to sync", message: "Click refresh to load repositories from gh.")
        case .loadingRepositories:
            LoadingStateRow(
                title: "Loading repositories",
                message: "Fetching repositories from gh."
            )
        case .failed(let message):
            StateRow(symbol: "exclamationmark.triangle", title: "Could not sync", message: message)
        case .loaded(let selection, true, _):
            LoadingStateRow(
                title: "Loading \(selection.selectedRepositoryName ?? "repository")",
                message: "Fetching open pull requests for the selected repository."
            )
        case .loaded(let selection, false, _) where store.visiblePullRequests.isEmpty:
            StateRow(
                symbol: "checkmark.circle",
                title: "No pull requests need review",
                message: "\(selection.selectedRepositoryName ?? "Selected repository") has no unreviewed pull requests or updates after your last review."
            )
        case .loaded(_, false, _):
            let pullRequests = store.visiblePullRequests
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(pullRequests) { pullRequest in
                            PullRequestRow(
                                pullRequest: pullRequest,
                                currentUserLogin: store.currentUserLogin,
                                configuredAgentTool: store.configuredAgentReviewTool(for: pullRequest),
                                onLaunchAgentReview: { agentTool in
                                    store.launchAgentReview(for: pullRequest, using: agentTool)
                                },
                                onConfigureAgentReview: {
                                    store.selectedSettingsTab = .agentReview
                                    NSApp.activate(ignoringOtherApps: true)
                                    openWindow(id: Self.settingsWindowID)
                                }
                            )
                        }
                    }
                }
                .frame(height: pullRequestListHeight(for: pullRequests.count))
            }
        }
    }

    private func pullRequestListHeight(for count: Int) -> CGFloat {
        let visibleRows = min(count, Self.maximumVisiblePullRequestRows)
        return CGFloat(visibleRows) * Self.estimatedPullRequestRowHeight
    }

    private func pullRequestCountText(for count: Int) -> String {
        count == 1 ? "1 pull request" : "\(count) pull requests"
    }

    private var footer: some View {
        HStack {
            if let footerPullRequestCountText {
                Text(footerPullRequestCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .pointingHandCursor()
        }
    }

    private var footerPullRequestCountText: String? {
        guard case .loaded(_, false, _) = store.state,
              !store.visiblePullRequests.isEmpty
        else {
            return nil
        }

        return pullRequestCountText(for: store.visiblePullRequests.count)
    }

    private var statusText: String {
        if store.isBatchRefreshing {
            return "Batch syncing..."
        }

        if store.isLoadingSelectedRepository {
            return "Loading repository..."
        }

        if let lastUpdated = store.lastUpdated {
            return "Updated \(Self.relativeFormatter.localizedString(for: lastUpdated, relativeTo: Date()))"
        }

        return "Not synced yet"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

enum PullRequestSettingsTab: Hashable {
    case general
    case repositories
    case agentReview
}

struct PullRequestSettingsView: View {
    let onSave: (GHMenuBarSettings) -> Void
    @Binding var selectedTab: PullRequestSettingsTab
    let authenticationStatus: GitHubAuthenticationStatus
    let currentUserLogin: String?
    let lastUpdated: Date?
    let onSyncNow: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: GHMenuBarSettingsDraft
    @State private var availableAccounts: [String] = []
    @State private var repositoriesByAccount: [String: [String]] = [:]
    @State private var isLoadingAccounts = false
    @State private var isLoadingRepositories = false
    @State private var repositoryLoadMessage: String?
    private let settingsClient = GitHubCLI()

    init(
        settings: GHMenuBarSettings,
        selectedTab: Binding<PullRequestSettingsTab> = .constant(.general),
        authenticationStatus: GitHubAuthenticationStatus = .unknown,
        currentUserLogin: String? = nil,
        lastUpdated: Date? = nil,
        onSyncNow: @escaping () -> Void = {},
        onSave: @escaping (GHMenuBarSettings) -> Void
    ) {
        self.onSave = onSave
        _selectedTab = selectedTab
        self.authenticationStatus = authenticationStatus
        self.currentUserLogin = currentUserLogin
        self.lastUpdated = lastUpdated
        self.onSyncNow = onSyncNow
        _draft = State(initialValue: GHMenuBarSettingsDraft(settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            Divider()

            TabView(selection: $selectedTab) {
                generalSettingsTab
                .tag(PullRequestSettingsTab.general)
                .tabItem {
                    Label("General", systemImage: "slider.horizontal.3")
                }

                repositoriesSettingsTab
                .tag(PullRequestSettingsTab.repositories)
                .task {
                    await loadAccountsIfNeeded()
                }
                .task(id: draft.organizations.joined(separator: "\u{1F}")) {
                    await loadRepositoriesForSelectedAccounts()
                }
                .tabItem {
                    Label("Repositories", systemImage: "folder")
                }

                agentReviewSettingsTab
                .tag(PullRequestSettingsTab.agentReview)
                .tabItem {
                    Label("Agent Review", systemImage: "sparkles")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider()

            settingsFooter
        }
        .frame(width: 820, height: 720)
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    LinearGradient(
                        colors: [GeneralSettingsPalette.sync, GeneralSettingsPalette.github],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 8)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Pull request preferences")
                    .font(.title3.weight(.semibold))

                Text("Choose watched repositories, sync behavior, and review automation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            AuthenticationStatusBadge(status: authenticationStatus)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var settingsFooter: some View {
        HStack(spacing: 10) {
            Text(draft.canSave ? "Changes are saved only when you click Save." : "Select at least one account or repository before saving.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                onSave(draft.settings)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .pointingHandCursor()
            .disabled(!draft.canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var generalSettingsTab: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: Self.generalColumns, alignment: .leading, spacing: 16) {
                settingsSection("Sync") {
                    GeneralSettingRow(
                        systemImage: "arrow.clockwise",
                        iconColor: GeneralSettingsPalette.sync,
                        title: "Automatic refresh",
                        detail: "Keep pull requests current in the menu bar."
                    ) {
                        Toggle("Automatic refresh", isOn: $draft.general.isAutomaticRefreshEnabled)
                            .labelsHidden()
                            .tint(GeneralSettingsPalette.sync)
                    }

                    GeneralSettingRow(
                        systemImage: "timer",
                        iconColor: GeneralSettingsPalette.sync,
                        title: "Refresh interval",
                        detail: "Minimum is 60 seconds."
                    ) {
                        HStack(spacing: 8) {
                            TextField("Refresh interval", value: $draft.refreshIntervalSeconds, formatter: Self.integerFormatter)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 78)

                            Text("seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GeneralSettingRow(
                        systemImage: "checkmark.circle",
                        iconColor: GeneralSettingsPalette.sync,
                        title: "Last sync",
                        detail: lastSyncDetail
                    ) {
                        StatusBadge(
                            symbol: "clock",
                            text: lastSyncValue,
                            color: lastUpdated == nil ? .secondary : .green
                        )
                    }

                    GeneralSettingRow(
                        systemImage: "arrow.clockwise.circle",
                        iconColor: GeneralSettingsPalette.sync,
                        title: "Manual refresh",
                        detail: "Useful after changing repository filters."
                    ) {
                        Button("Sync now") {
                            onSyncNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(GeneralSettingsPalette.sync)
                        .pointingHandCursor()
                    }
                }

                settingsSection("GitHub CLI") {
                    GeneralSettingRow(
                        systemImage: "terminal",
                        iconColor: GeneralSettingsPalette.github,
                        title: "Authentication",
                        detail: authenticationDetail
                    ) {
                        AuthenticationStatusBadge(status: authenticationStatus)
                    }

                    GeneralSettingRow(
                        systemImage: "person.crop.circle",
                        iconColor: GeneralSettingsPalette.github,
                        title: "Signed in as",
                        detail: "Repos and organizations come from this account."
                    ) {
                        Text(signedInAccountName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                settingsSection("Notifications") {
                    GeneralSettingRow(
                        systemImage: "plus.circle",
                        iconColor: GeneralSettingsPalette.notifications,
                        title: "New pull requests",
                        detail: "Notify when a matching repository gets a new PR."
                    ) {
                        Toggle("New pull requests", isOn: $draft.general.notifiesForNewPullRequests)
                            .labelsHidden()
                            .tint(GeneralSettingsPalette.notifications)
                    }

                    GeneralSettingRow(
                        systemImage: "eye",
                        iconColor: GeneralSettingsPalette.notifications,
                        title: "Review requested",
                        detail: "Notify when your review is requested."
                    ) {
                        Toggle("Review requested", isOn: $draft.general.notifiesForReviewRequests)
                            .labelsHidden()
                            .tint(GeneralSettingsPalette.notifications)
                    }

                    GeneralSettingRow(
                        systemImage: "xmark.circle",
                        iconColor: GeneralSettingsPalette.notifications,
                        title: "CI failures",
                        detail: "Notify when checks fail on visible pull requests."
                    ) {
                        Toggle("CI failures", isOn: $draft.general.notifiesForCIFailures)
                            .labelsHidden()
                            .tint(GeneralSettingsPalette.notifications)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var repositoriesSettingsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                AccountPickerColumn(
                    accounts: availableAccounts,
                    selectedAccounts: $draft.organizations,
                    isLoading: isLoadingAccounts,
                    message: repositoryLoadMessage
                )

                RepositoryPickerColumn(
                    repositories: availableRepositories,
                    selectedRepositories: $draft.includedRepositories,
                    selectsAllRepositories: $draft.selectsAllRepositories,
                    hasSelectedAccounts: !draft.organizations.isEmpty,
                    isLoading: isLoadingRepositories
                )
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var agentReviewSettingsTab: some View {
        ScrollView(.vertical) {
            AgentReviewScopeEditor(scopes: $draft.agentReview.reviewScopes)
                .padding(.bottom, 4)
        }
    }

    private var authenticationDetail: String {
        switch authenticationStatus {
        case .unknown:
            return "GitHub CLI status has not been checked yet."
        case .authenticated:
            return "Using the local GitHub CLI session."
        case .unauthenticated(let message):
            return message
        }
    }

    private var lastSyncValue: String {
        guard let lastUpdated else { return "Not synced" }
        return Self.relativeDateFormatter.localizedString(for: lastUpdated, relativeTo: Date())
    }

    private var lastSyncDetail: String {
        lastUpdated == nil ? "Click Sync now to load repositories." : "Most recent refresh timestamp."
    }

    private var signedInAccountName: String {
        guard let currentUserLogin, !currentUserLogin.isEmpty else { return "Unknown" }
        return currentUserLogin
    }

    private static let generalColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var availableRepositories: [String] {
        Array(Set(draft.organizations.flatMap { repositoriesByAccount[$0] ?? [] })).sorted()
    }

    @MainActor
    private func loadAccountsIfNeeded() async {
        guard availableAccounts.isEmpty, !isLoadingAccounts else { return }

        isLoadingAccounts = true
        repositoryLoadMessage = nil
        defer { isLoadingAccounts = false }

        do {
            let accounts = try await settingsClient.fetchAccounts()
            availableAccounts = accounts

            if draft.organizations.isEmpty, let viewerAccount = accounts.first {
                draft.organizations = [viewerAccount]
            }
        } catch {
            repositoryLoadMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadRepositoriesForSelectedAccounts() async {
        let selectedAccounts = draft.organizations
        guard !selectedAccounts.isEmpty else {
            draft.includedRepositories = []
            return
        }

        let accountsToLoad = selectedAccounts.filter { repositoriesByAccount[$0] == nil }
        guard !accountsToLoad.isEmpty else {
            normalizeSelectedRepositories()
            return
        }

        isLoadingRepositories = true
        repositoryLoadMessage = nil
        defer { isLoadingRepositories = false }

        do {
            for account in accountsToLoad {
                repositoriesByAccount[account] = try await settingsClient.fetchRepositories(owner: account)
            }

            normalizeSelectedRepositories()
        } catch {
            repositoryLoadMessage = error.localizedDescription
        }
    }

    private func normalizeSelectedRepositories() {
        let repositories = availableRepositories

        if draft.selectsAllRepositories {
            draft.includedRepositories = repositories
        } else {
            let repositorySet = Set(repositories)
            draft.includedRepositories = draft.includedRepositories.filter { repositorySet.contains($0) }
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 6)
    }

    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .frame(width: 130, alignment: .trailing)
                .foregroundStyle(.secondary)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func settingsEditor(
        title: String,
        text: Binding<String>,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(height: height)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: GHMenuBarSettings.minimumRefreshIntervalSeconds)
        return formatter
    }()
}

private enum GeneralSettingsPalette {
    static let sync = Color.blue
    static let github = Color.green
    static let notifications = Color.orange
}

private struct GeneralSettingRow<Accessory: View>: View {
    let systemImage: String
    let iconColor: Color
    let title: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(iconColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(iconColor.opacity(0.16), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            accessory()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 54)
                .opacity(0.65)
        }
    }
}

private struct AccountPickerColumn: View {
    let accounts: [String]
    @Binding var selectedAccounts: [String]
    let isLoading: Bool
    let message: String?
    @State private var searchText = ""

    var body: some View {
        PickerColumn(
            title: "Accounts",
            systemImage: "person.2",
            selectionSummary: selectionSummary,
            searchPrompt: "Search accounts",
            searchText: $searchText
        ) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if accounts.isEmpty {
                Text(message ?? "No accounts found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                PickerSelectAllToggle(
                    isOn: selectAllBinding,
                    isEnabled: !accounts.isEmpty
                )

                ForEach(filteredAccounts, id: \.self) { account in
                    PickerRow(
                        title: account,
                        isSelected: selectedAccounts.contains(account),
                        onToggle: {
                            binding(for: account).wrappedValue.toggle()
                        }
                    )
                }
            }
        }
    }

    private var filteredAccounts: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return accounts }

        return accounts.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var selectionSummary: String {
        "\(selectedAccounts.count) of \(accounts.count) selected"
    }

    private var selectAllBinding: Binding<Bool> {
        Binding {
            !accounts.isEmpty && selectedAccounts.count == accounts.count
        } set: { shouldSelectAll in
            if shouldSelectAll {
                selectedAccounts = accounts
            } else {
                selectedAccounts = []
            }
        }
    }

    private func binding(for account: String) -> Binding<Bool> {
        Binding {
            selectedAccounts.contains(account)
        } set: { isSelected in
            if isSelected {
                guard !selectedAccounts.contains(account) else { return }
                selectedAccounts.append(account)
            } else {
                selectedAccounts.removeAll { $0 == account }
            }
        }
    }
}

private struct RepositoryPickerColumn: View {
    let repositories: [String]
    @Binding var selectedRepositories: [String]
    @Binding var selectsAllRepositories: Bool
    let hasSelectedAccounts: Bool
    let isLoading: Bool
    @State private var searchText = ""

    var body: some View {
        PickerColumn(
            title: "Repositories",
            systemImage: "folder",
            selectionSummary: selectionSummary,
            searchPrompt: "Search repositories",
            searchText: $searchText
        ) {
            if !hasSelectedAccounts {
                Text("Select accounts first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if repositories.isEmpty {
                Text("No repositories found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                PickerSelectAllToggle(
                    isOn: selectAllBinding,
                    isEnabled: !repositories.isEmpty
                )

                ForEach(filteredRepositories, id: \.self) { repository in
                    PickerRow(
                        title: repository,
                        isSelected: selectedRepositories.contains(repository),
                        onToggle: {
                            binding(for: repository).wrappedValue.toggle()
                        }
                    )
                }
            }
        }
    }

    private var filteredRepositories: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositories }

        return repositories.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var selectionSummary: String {
        "\(selectedRepositories.count) of \(repositories.count) selected"
    }

    private var selectAllBinding: Binding<Bool> {
        Binding {
            !repositories.isEmpty && selectedRepositories.count == repositories.count
        } set: { shouldSelectAll in
            if shouldSelectAll {
                selectsAllRepositories = true
                selectedRepositories = repositories
            } else {
                selectsAllRepositories = false
                selectedRepositories = []
            }
        }
    }

    private func binding(for repository: String) -> Binding<Bool> {
        Binding {
            selectedRepositories.contains(repository)
        } set: { isSelected in
            selectsAllRepositories = false

            if isSelected {
                guard !selectedRepositories.contains(repository) else { return }
                selectedRepositories.append(repository)
                selectedRepositories.sort()
            } else {
                selectedRepositories.removeAll { $0 == repository }
            }
        }
    }
}

private struct PickerColumn<Content: View>: View {
    let title: String
    let systemImage: String
    let selectionSummary: String
    let searchPrompt: String
    @Binding var searchText: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PickerColumnHeader(
                title: title,
                systemImage: systemImage,
                selectionSummary: selectionSummary
            )

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(searchPrompt, text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.separator.opacity(0.22), lineWidth: 1)
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .scrollContentBackground(.hidden)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.28), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PickerColumnHeader: View {
    let title: String
    let systemImage: String
    let selectionSummary: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(title)
                .font(.subheadline.weight(.semibold))

            Spacer()

            Text(selectionSummary)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }
}

private struct PickerSelectAllToggle: View {
    @Binding var isOn: Bool
    let isEnabled: Bool

    var body: some View {
        Toggle("Select all", isOn: $isOn)
            .toggleStyle(.checkbox)
            .disabled(!isEnabled)
            .pointingHandCursor()
            .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption.weight(.medium))
    }
}

private struct PickerRow: View {
    let title: String
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)

                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor.opacity(0.25) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

private enum AgentReviewPalette {
    static let selectedScope = Color.blue
    static let local = Color.teal
    static let cloud = Color.orange
    static let disabled = Color.secondary
}

private struct AgentReviewScopeEditor: View {
    @Binding var scopes: [AgentReviewScopeDraft]
    @State private var selectedScopeID: AgentReviewScopeDraft.ID?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            scopeSidebar

            if let selectedScopeBinding {
                ScopeSettingsPanel(scope: selectedScopeBinding)
            } else {
                ContentUnavailableView(
                    "No review scopes",
                    systemImage: "sparkles",
                    description: Text("Add a global, organization, or repository scope to configure local reviews.")
                )
                .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .onAppear {
            ensureSelectedScope()
        }
        .onChange(of: scopes) { _, _ in
            ensureSelectedScope()
        }
    }

    private var scopeSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(AgentReviewPalette.selectedScope)
                Text("Scopes")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    addScope()
                } label: {
                    Label("Add scope", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach($scopes) { scopeBinding in
                        AgentReviewScopeRow(
                            scope: scopeBinding,
                            isSelected: selectedScopeID == scopeBinding.wrappedValue.id,
                            onSelect: {
                                selectedScopeID = scopeBinding.wrappedValue.id
                            },
                            onRemove: {
                                removeScope(withID: scopeBinding.wrappedValue.id)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .scrollContentBackground(.hidden)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.28), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 5)
        }
        .frame(minWidth: 260, idealWidth: 260, maxWidth: 260, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedScopeBinding: Binding<AgentReviewScopeDraft>? {
        guard let selectedScopeID,
              let index = scopes.firstIndex(where: { $0.id == selectedScopeID })
        else {
            return nil
        }

        return $scopes[index]
    }

    private func ensureSelectedScope() {
        if let selectedScopeID, scopes.contains(where: { $0.id == selectedScopeID }) {
            return
        }
        selectedScopeID = scopes.first?.id
    }

    private func addScope() {
        let scope = AgentReviewScopeDraft(pattern: scopes.isEmpty ? "*" : "owner/repo")
        scopes.append(scope)
        selectedScopeID = scope.id
    }

    private func removeScope(withID id: AgentReviewScopeDraft.ID) {
        scopes.removeAll { $0.id == id }
        ensureSelectedScope()
    }
}

private struct AgentReviewScopeRow: View {
    @Binding var scope: AgentReviewScopeDraft
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scope.displayPattern)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("Local: \(scope.localMode.displayName.lowercased()) · Cloud unavailable")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if !scope.isPatternValid {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help(scope.patternValidationMessage ?? "Invalid scope pattern")
                }

                Button {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
                .help("Remove scope")
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? AgentReviewPalette.selectedScope.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? AgentReviewPalette.selectedScope.opacity(0.65) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

private struct ScopeSettingsPanel: View {
    @Binding var scope: AgentReviewScopeDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scope settings")
                    .font(.subheadline.weight(.semibold))

                TextField("Scope pattern", text: $scope.pattern)
                    .textFieldStyle(.roundedBorder)

                Text("Accepted forms: *, owner/*, or owner/repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let validationMessage = scope.patternValidationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                AgentReviewWorkflowCard(
                    title: "Local review",
                    tint: AgentReviewPalette.local,
                    modeTitle: "Local review mode",
                    mode: $scope.localMode
                ) {
                    Picker("Runner", selection: $scope.localAgentTool) {
                        ForEach(AgentReviewTool.allCases) { tool in
                            Text(tool.displayName).tag(tool)
                        }
                    }

                    LabeledContent("Workspace") {
                        TextField("Workspace path or template", text: $scope.localWorkspacePathTemplate)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Prompt root") {
                        TextField("Optional prompt root path", text: $scope.localPromptRootPathTemplate)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $scope.localPromptTemplate)
                            .font(.system(.caption, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .frame(height: 76)
                    }
                }

                CloudReviewUnavailableCard(hasStoredConfiguration: scope.cloudMode == .override)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct CloudReviewUnavailableCard: View {
    let hasStoredConfiguration: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(AgentReviewPalette.cloud)
                    .frame(width: 8, height: 8)

                Text("Cloud review")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("Coming later")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Label("Unavailable", systemImage: "cloud.slash")
                .font(.headline)
                .foregroundStyle(AgentReviewPalette.cloud)

            Text("GHMenuBar does not currently have a cloud review executor. Cloud review cannot be configured or started from the app yet.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasStoredConfiguration {
                Text("Previously saved cloud settings are preserved, but remain inactive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AgentReviewPalette.cloud.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct AgentReviewWorkflowCard<Content: View>: View {
    let title: String
    let tint: Color
    let modeTitle: String
    @Binding var mode: AgentReviewDraftMode
    var warning: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.subheadline.weight(.semibold))

                if let warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AgentReviewPalette.cloud)
                        .help(warning)
                }

                Spacer()

                Text(mode == .override ? "Overrides" : mode.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(mode == .disabled ? AgentReviewPalette.disabled : tint)
            }

            Picker(modeTitle, selection: $mode) {
                ForEach(AgentReviewDraftMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .tint(tint)

            if mode == .disabled {
                Text("Local review is disabled for matching pull requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                content()
                    .disabled(mode == .inherit)
                    .opacity(mode == .inherit ? 0.65 : 1)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct GHMenuBarSettingsDraft {
    var githubOwner: String
    var refreshIntervalSeconds: Int
    var general: GeneralSettingsDraft
    var organizations: [String]
    var includedRepositories: [String]
    var selectsAllRepositories: Bool
    var agentReview: AgentReviewSettingsDraft

    init(settings: GHMenuBarSettings) {
        githubOwner = settings.githubOwner
        refreshIntervalSeconds = settings.refreshIntervalSeconds
        general = GeneralSettingsDraft(settings: settings.general)
        organizations = settings.repositoryFilter.organizations
        includedRepositories = settings.repositoryFilter.includedRepositories
        selectsAllRepositories = settings.repositoryFilter.includedRepositories.isEmpty
        agentReview = AgentReviewSettingsDraft(settings: settings)
    }

    var settings: GHMenuBarSettings {
        GHMenuBarSettings(
            githubOwner: githubOwner,
            refreshIntervalSeconds: refreshIntervalSeconds,
            general: general.settings,
            repositoryFilter: RepositoryFilterSettings(
                organizations: organizations,
                includedRepositories: selectsAllRepositories ? [] : includedRepositories,
                excludedRepositories: []
            ),
            agentReview: AgentReviewSettings(
                isEnabled: agentReview.enablesLocalReview,
                supportedRepository: "",
                workspacePath: "",
                agentTool: .claudeCode,
                agentToolOverrides: [:],
                reviewProfiles: [],
                reviewScopes: agentReview.reviewScopes.compactMap { $0.scope },
                globalPrompt: AgentReviewSettings.defaultPrompt,
                repositoryPromptOverrides: [:]
            )
        )
    }

    var canSave: Bool {
        guard agentReview.hasValidScopePatterns else {
            return false
        }

        if organizations.isEmpty {
            return selectsAllRepositories
        }

        return selectsAllRepositories || !includedRepositories.isEmpty
    }

    private static func promptOverrides(from text: String) -> [String: String] {
        text.components(separatedBy: .newlines)
            .reduce(into: [String: String]()) { overrides, line in
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }

                let repository = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let prompt = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !repository.isEmpty, !prompt.isEmpty else { return }

                overrides[repository] = prompt
            }
    }

    private static func agentToolOverrides(from text: String) -> [String: AgentReviewTool] {
        text.components(separatedBy: .newlines)
            .reduce(into: [String: AgentReviewTool]()) { overrides, line in
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }

                let pattern = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let toolName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pattern.isEmpty,
                      let tool = AgentReviewTool(userFacingName: toolName)
                else {
                    return
                }

                overrides[pattern] = tool
            }
    }

    fileprivate static func promptOverrideLines(from overrides: [String: String]) -> String {
        overrides
            .sorted { $0.key < $1.key }
            .map { "\($0.key) | \($0.value)" }
            .joined(separator: "\n")
    }

    fileprivate static func agentToolOverrideLines(from overrides: [String: AgentReviewTool]) -> String {
        overrides
            .sorted { $0.key < $1.key }
            .map { "\($0.key) | \($0.value.displayName)" }
            .joined(separator: "\n")
    }
}

private struct GeneralSettingsDraft {
    var isAutomaticRefreshEnabled: Bool
    var notifiesForNewPullRequests: Bool
    var notifiesForReviewRequests: Bool
    var notifiesForCIFailures: Bool

    init(settings: GeneralSettings) {
        isAutomaticRefreshEnabled = settings.isAutomaticRefreshEnabled
        notifiesForNewPullRequests = settings.notifiesForNewPullRequests
        notifiesForReviewRequests = settings.notifiesForReviewRequests
        notifiesForCIFailures = settings.notifiesForCIFailures
    }

    var settings: GeneralSettings {
        GeneralSettings(
            isAutomaticRefreshEnabled: isAutomaticRefreshEnabled,
            showsPullRequestCount: false,
            menuBarCountScope: .reviewRequests,
            hidesZeroPullRequestCount: true,
            notifiesForNewPullRequests: notifiesForNewPullRequests,
            notifiesForReviewRequests: notifiesForReviewRequests,
            notifiesForCIFailures: notifiesForCIFailures
        )
    }
}

private struct AgentReviewSettingsDraft {
    var reviewScopes: [AgentReviewScopeDraft]

    init(settings: GHMenuBarSettings) {
        if settings.agentReview.reviewScopes.isEmpty {
            reviewScopes = Self.legacyScopes(from: settings)
        } else {
            reviewScopes = settings.agentReview.reviewScopes.map {
                Self.repairedStoredScope(
                    $0,
                    includedRepositories: settings.repositoryFilter.includedRepositories
                )
            }
        }
    }

    var enablesLocalReview: Bool {
        reviewScopes.contains { $0.localMode != .disabled && $0.localMode != .inherit }
    }

    var hasValidScopePatterns: Bool {
        reviewScopes.allSatisfy(\.isPatternValid)
    }

    private static func repairedStoredScope(
        _ scope: AgentReviewScope,
        includedRepositories: [String]
    ) -> AgentReviewScopeDraft {
        var draft = AgentReviewScopeDraft(scope: scope)
        guard !draft.isPatternValid,
              let repositoryBasename = localPathBasename(scope.pattern)
        else {
            return draft
        }

        let matches = includedRepositories.filter { repository in
            repository.split(separator: "/", maxSplits: 1).last.map(String.init)?
                .caseInsensitiveCompare(repositoryBasename) == .orderedSame
        }
        guard matches.count == 1, let repository = matches.first else {
            return draft
        }

        draft.pattern = repository
        if draft.localMode == .override {
            draft.localWorkspacePathTemplate = scope.pattern
        }
        return draft
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

    private static func legacyScopes(from settings: GHMenuBarSettings) -> [AgentReviewScopeDraft] {
        let legacySettings = settings.agentReview
        let knownRepositories = (
            settings.repositoryFilter.includedRepositories +
            [legacySettings.supportedRepository]
        ).reduce(into: [String]()) { repositories, repository in
            let normalizedRepository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRepository.isEmpty,
                  !repositories.contains(normalizedRepository)
            else {
                return
            }
            repositories.append(normalizedRepository)
        }

        let repositoryScopes = knownRepositories.compactMap { repository -> AgentReviewScopeDraft? in
            guard let profile = legacySettings.reviewProfile(for: repository) else {
                return nil
            }

            return AgentReviewScopeDraft(
                pattern: repository,
                localMode: .override,
                cloudMode: .disabled,
                localAgentTool: profile.agentTool,
                localWorkspacePathTemplate: profile.workspacePath,
                localPromptRootPathTemplate: profile.promptRootPath ?? "",
                localPromptTemplate: profile.reviewCommand
            )
        }

        if !repositoryScopes.isEmpty {
            return repositoryScopes
        }

        if let wildcardProfile = legacySettings.reviewProfiles.first(where: { $0.pathPattern.hasSuffix("/*") }) {
            return [
                AgentReviewScopeDraft(
                    pattern: "*",
                    localMode: .override,
                    cloudMode: .disabled,
                    localAgentTool: wildcardProfile.agentTool,
                    localWorkspacePathTemplate: String(wildcardProfile.pathPattern.dropLast()) + "{repoName}",
                    localPromptRootPathTemplate: "",
                    localPromptTemplate: wildcardProfile.reviewCommand
                )
            ]
        }

        guard !legacySettings.workspacePath.isEmpty else { return [] }
        return [
            AgentReviewScopeDraft(
                pattern: legacySettings.supportedRepository.isEmpty ? "*" : legacySettings.supportedRepository,
                localMode: .override,
                cloudMode: .disabled,
                localAgentTool: legacySettings.agentTool,
                localWorkspacePathTemplate: legacySettings.workspacePath,
                localPromptRootPathTemplate: "",
                localPromptTemplate: legacySettings.globalPrompt
            )
        ]
    }
}

private enum AgentReviewDraftMode: String, CaseIterable, Identifiable {
    case inherit
    case override
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inherit:
            return "Inherit"
        case .override:
            return "Override"
        case .disabled:
            return "Disable"
        }
    }
}

private struct AgentReviewScopeDraft: Identifiable, Equatable {
    let id: UUID
    var pattern: String
    var localMode: AgentReviewDraftMode
    var cloudMode: AgentReviewDraftMode
    var localAgentTool: AgentReviewTool
    var localWorkspacePathTemplate: String
    var localPromptRootPathTemplate: String
    var localPromptTemplate: String
    var cloudWorkflowName: String
    var cloudTriggerTemplate: String
    var cloudReadinessRequirements: String

    init(
        id: UUID = UUID(),
        pattern: String = "*",
        localMode: AgentReviewDraftMode = .inherit,
        cloudMode: AgentReviewDraftMode = .disabled,
        localAgentTool: AgentReviewTool = .codexCLI,
        localWorkspacePathTemplate: String = "",
        localPromptRootPathTemplate: String = "",
        localPromptTemplate: String = "$requesting-code-review {pr}",
        cloudWorkflowName: String = "Codex cloud review",
        cloudTriggerTemplate: String = "@codex review for {pr}",
        cloudReadinessRequirements: String = "Codex cloud enabled\nReview runner configured\nCloud-visible review instructions available"
    ) {
        self.id = id
        self.pattern = pattern
        self.localMode = localMode
        self.cloudMode = cloudMode
        self.localAgentTool = localAgentTool
        self.localWorkspacePathTemplate = localWorkspacePathTemplate
        self.localPromptRootPathTemplate = localPromptRootPathTemplate
        self.localPromptTemplate = localPromptTemplate
        self.cloudWorkflowName = cloudWorkflowName
        self.cloudTriggerTemplate = cloudTriggerTemplate
        self.cloudReadinessRequirements = cloudReadinessRequirements
    }

    init(scope: AgentReviewScope) {
        let localMode: AgentReviewDraftMode
        let localWorkflow: AgentReviewLocalWorkflow?
        switch scope.localReview {
        case .inherit:
            localMode = .inherit
            localWorkflow = nil
        case .override(let workflow):
            localMode = .override
            localWorkflow = workflow
        case .disabled:
            localMode = .disabled
            localWorkflow = nil
        }

        let cloudMode: AgentReviewDraftMode
        let cloudWorkflow: AgentReviewCloudWorkflow?
        switch scope.cloudReview {
        case .inherit:
            cloudMode = .inherit
            cloudWorkflow = nil
        case .override(let workflow):
            cloudMode = .override
            cloudWorkflow = workflow
        case .disabled:
            cloudMode = .disabled
            cloudWorkflow = nil
        }

        self.init(
            pattern: scope.pattern,
            localMode: localMode,
            cloudMode: cloudMode,
            localAgentTool: localWorkflow?.agentTool ?? .codexCLI,
            localWorkspacePathTemplate: localWorkflow?.workspacePathTemplate ?? "",
            localPromptRootPathTemplate: localWorkflow?.promptRootPathTemplate ?? "",
            localPromptTemplate: localWorkflow?.promptTemplate ?? "$requesting-code-review {pr}",
            cloudWorkflowName: cloudWorkflow?.workflowName ?? "Codex cloud review",
            cloudTriggerTemplate: cloudWorkflow?.triggerTemplate ?? "@codex review for {pr}",
            cloudReadinessRequirements: cloudWorkflow?.readinessRequirements ?? "Codex cloud enabled\nReview runner configured\nCloud-visible review instructions available"
        )
    }

    var displayPattern: String {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedPattern.isEmpty ? "Untitled scope" : normalizedPattern
    }

    var patternValidationMessage: String? {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty else {
            return "Enter *, owner/*, or owner/repo."
        }
        guard normalizedPattern != "*" else {
            return nil
        }
        guard !normalizedPattern.hasPrefix("/"),
              !normalizedPattern.hasPrefix("~/"),
              !normalizedPattern.hasPrefix("./"),
              !normalizedPattern.hasPrefix("../"),
              !normalizedPattern.contains("\\")
        else {
            return "Invalid scope. Use *, owner/*, or owner/repo; filesystem paths belong in Workspace."
        }

        let components = normalizedPattern.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              components[0] != "*",
              components[0].allSatisfy(Self.isScopeNameCharacter),
              components[0].contains(where: { $0.isLetter || $0.isNumber }),
              (components[1] == "*" || (
                  components[1].allSatisfy(Self.isScopeNameCharacter)
                      && components[1].contains(where: { $0.isLetter || $0.isNumber })
              ))
        else {
            return "Invalid scope. Use *, owner/*, or owner/repo; filesystem paths belong in Workspace."
        }

        return nil
    }

    var isPatternValid: Bool {
        patternValidationMessage == nil
    }

    var scope: AgentReviewScope? {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPatternValid else { return nil }

        return AgentReviewScope(
            pattern: normalizedPattern,
            localReview: localSetting,
            cloudReview: cloudSetting
        )
    }

    private static func isScopeNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
    }

    private var localSetting: AgentReviewLocalSetting {
        switch localMode {
        case .inherit:
            return .inherit
        case .disabled:
            return .disabled
        case .override:
            return .override(AgentReviewLocalWorkflow(
                agentTool: localAgentTool,
                workspacePathTemplate: localWorkspacePathTemplate,
                promptRootPathTemplate: localPromptRootPathTemplate,
                promptTemplate: localPromptTemplate
            ))
        }
    }

    private var cloudSetting: AgentReviewCloudSetting {
        switch cloudMode {
        case .inherit:
            return .inherit
        case .disabled:
            return .disabled
        case .override:
            return .override(AgentReviewCloudWorkflow(
                workflowName: cloudWorkflowName,
                triggerTemplate: cloudTriggerTemplate,
                readinessRequirements: cloudReadinessRequirements
            ))
        }
    }
}

private struct AgentReviewProfileDraft: Identifiable, Equatable {
    let id: UUID
    var pathPattern: String
    var agentTool: AgentReviewTool
    var reviewCommand: String

    init(
        id: UUID = UUID(),
        pathPattern: String = "",
        agentTool: AgentReviewTool = .claudeCode,
        reviewCommand: String = "/review"
    ) {
        self.id = id
        self.pathPattern = pathPattern
        self.agentTool = agentTool
        self.reviewCommand = reviewCommand
    }

    init(profile: AgentReviewProfile) {
        self.init(
            pathPattern: profile.pathPattern,
            agentTool: profile.agentTool,
            reviewCommand: profile.reviewCommand
        )
    }

    var profile: AgentReviewProfile? {
        let normalizedPathPattern = pathPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReviewCommand = reviewCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPathPattern.isEmpty, !normalizedReviewCommand.isEmpty else { return nil }

        return AgentReviewProfile(
            pathPattern: normalizedPathPattern,
            agentTool: agentTool,
            reviewCommand: normalizedReviewCommand
        )
    }
}

struct PullRequestRow: View {
    let pullRequest: PullRequest
    let currentUserLogin: String?
    let configuredAgentTool: AgentReviewTool?
    let onLaunchAgentReview: (AgentReviewTool) -> Void
    let onConfigureAgentReview: () -> Void
    private static let reviewToolChoices: [AgentReviewTool] = [.claudeCode, .copilot, .codexCLI]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                NSWorkspace.shared.open(pullRequest.url)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    rowContent
                    Spacer(minLength: 6)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .pointingHandCursor()

            VStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(pullRequest.url)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
                .help("Open pull request")

                if let configuredAgentTool {
                    Menu {
                        ForEach(Self.reviewToolChoices) { agentTool in
                            Button {
                                onLaunchAgentReview(agentTool)
                            } label: {
                                if agentTool == configuredAgentTool {
                                    Label("\(agentTool.displayName) (Default)", systemImage: "checkmark")
                                } else {
                                    Text(agentTool.displayName)
                                }
                            }
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Review")
                                Text("\(configuredAgentTool.displayName) default")
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .pointingHandCursor()
                    .help("Choose review agent. Default: \(configuredAgentTool.displayName)")
                } else {
                    Button {
                        onConfigureAgentReview()
                    } label: {
                        Label {
                            Text("Set Up Review")
                        } icon: {
                            Image(systemName: "gearshape")
                        }
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
                    .help("Configure Agent Review settings")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: pullRequest.isDraft ? "doc.badge.clock" : "arrow.triangle.pull")
                .foregroundStyle(pullRequest.isDraft ? Color.secondary : Color.blue)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(pullRequest.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if pullRequest.isDraft {
                        Text("Draft")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }

                Text(pullRequest.rowByline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                reviewBadges

                Text("Updated \(Self.relativeFormatter.localizedString(for: pullRequest.updatedAt, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @ViewBuilder
    private var reviewBadges: some View {
        if let reviewSummary = pullRequest.reviewSummary {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusBadge(
                        symbol: "checkmark.seal.fill",
                        text: approvalText(for: reviewSummary.approvalCount),
                        color: reviewSummary.approvalCount > 0 ? .green : .secondary
                    )

                    StatusBadge(
                        symbol: ciSymbol(for: reviewSummary.ciState),
                        text: ciText(for: reviewSummary.ciState),
                        color: ciColor(for: reviewSummary.ciState)
                    )
                }

                if reviewSummary.isReviewRequested(for: currentUserLogin) || reviewSummary.hasChangesRequested {
                    HStack(spacing: 6) {
                        if reviewSummary.isReviewRequested(for: currentUserLogin) {
                            StatusBadge(
                                symbol: "person.crop.circle.badge.questionmark",
                                text: "Your review",
                                color: .blue
                            )
                        }

                        if reviewSummary.hasChangesRequested {
                            StatusBadge(
                                symbol: "xmark.octagon.fill",
                                text: "Changes requested",
                                color: .red
                            )
                        }
                    }
                }
            }
        }
    }

    private func approvalText(for count: Int) -> String {
        count == 1 ? "1 approval" : "\(count) approvals"
    }

    private func ciText(for state: PullRequestCIState) -> String {
        switch state {
        case .none:
            return "No CI"
        case .pending:
            return "CI pending"
        case .passing:
            return "CI passing"
        case .failing:
            return "CI failing"
        }
    }

    private func ciSymbol(for state: PullRequestCIState) -> String {
        switch state {
        case .none:
            return "minus.circle"
        case .pending:
            return "clock.fill"
        case .passing:
            return "checkmark.circle.fill"
        case .failing:
            return "xmark.circle.fill"
        }
    }

    private func ciColor(for state: PullRequestCIState) -> Color {
        switch state {
        case .none:
            return .secondary
        case .pending:
            return .orange
        case .passing:
            return .green
        case .failing:
            return .red
        }
    }
}

struct StatusBadge: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct AuthenticationStatusBadge: View {
    let status: GitHubAuthenticationStatus

    var body: some View {
        Label {
            Text("gh")
                .lineLimit(1)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .help(helpText)
    }

    private var symbol: String {
        switch status {
        case .unknown:
            return "circle.dashed"
        case .authenticated:
            return "checkmark.circle.fill"
        case .unauthenticated:
            return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .unknown:
            return .secondary
        case .authenticated:
            return .green
        case .unauthenticated:
            return .red
        }
    }

    private var helpText: String {
        switch status {
        case .unknown:
            return "gh authentication has not been checked yet"
        case .authenticated(let login):
            return "gh authenticated as \(login)"
        case .unauthenticated(let message):
            return "gh not authenticated: \(message)"
        }
    }
}

struct StateRow: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

struct LoadingStateRow: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Loading")

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}
