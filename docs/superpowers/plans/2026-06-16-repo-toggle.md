# Repo Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build repository toggling for open, non-draft pull requests in the selected organization.

**Architecture:** Keep `GitHubCLI` responsible for fetching open non-draft PRs. Add a small `PullRequestRepositorySelection` model in `GHCore` that derives available repositories, tracks the selected repository, and exposes filtered pull requests. Wire `PullRequestStore` and the SwiftUI menu to that model.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, GitHub CLI.

---

## File Structure

- Modify `Sources/GHCore/GitHubCLI.swift`: add the non-draft filter to the `gh search prs` command.
- Create `Sources/GHCore/PullRequestRepositorySelection.swift`: pure model for repo list, selected repo, filtered PRs, next/previous selection, and refresh fallback behavior.
- Modify `Tests/GHCoreTests/GitHubCLITests.swift`: update command expectations and add selection model tests.
- Modify `Sources/GHMenuBar/GHMenuBarApp.swift`: store loaded selection state and render repo navigation controls.

This workspace is not a git repository, so commit steps are intentionally omitted.

### Task 1: Core CLI Filter And Repository Selection

**Files:**
- Modify: `Sources/GHCore/GitHubCLI.swift`
- Create: `Sources/GHCore/PullRequestRepositorySelection.swift`
- Modify: `Tests/GHCoreTests/GitHubCLITests.swift`

- [ ] **Step 1: Write failing tests**

Add tests that expect the CLI command to exclude drafts and the selection model to filter and wrap repositories.

```swift
func testOpenPullRequestCommandExcludesDraftPullRequests() {
    XCTAssertTrue(GitHubCLI.openPullRequestsCommand(limit: 20).contains("--draft=false"))
}

func testRepositorySelectionStartsAtFirstSortedRepositoryAndFiltersPullRequests() {
    let selection = PullRequestRepositorySelection(pullRequests: [
        samplePullRequest(title: "B", repository: "acme/bravo"),
        samplePullRequest(title: "A", repository: "acme/alpha")
    ])

    XCTAssertEqual(selection.repositories, ["acme/alpha", "acme/bravo"])
    XCTAssertEqual(selection.selectedRepository, "acme/alpha")
    XCTAssertEqual(selection.visiblePullRequests.map(\\.title), ["A"])
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
    XCTAssertEqual(selection.visiblePullRequests.map(\\.title), ["B2"])
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
    XCTAssertEqual(selection.visiblePullRequests.map(\\.title), ["C"])
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
```

Add this helper inside `GitHubCLITests`:

```swift
private func samplePullRequest(title: String, repository: String) -> PullRequest {
    PullRequest(
        title: title,
        url: URL(string: "https://github.com/\(repository)/pull/\(title)")!,
        repository: repository,
        author: "dariana",
        updatedAt: Date(timeIntervalSince1970: 1_779_000_000),
        isDraft: false
    )
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test`

Expected: tests fail because `--draft=false` and `PullRequestRepositorySelection` do not exist yet.

- [ ] **Step 3: Implement core behavior**

Add `--draft=false` to `GitHubCLI.openPullRequestsCommand(limit:)` after `--state`, `"open"`.

Create `Sources/GHCore/PullRequestRepositorySelection.swift`:

```swift
import Foundation

public struct PullRequestRepositorySelection: Equatable, Sendable {
    public private(set) var pullRequests: [PullRequest]
    public private(set) var selectedRepository: String?

    public init(pullRequests: [PullRequest] = [], selectedRepository: String? = nil) {
        self.pullRequests = pullRequests
        self.selectedRepository = selectedRepository
        normalizeSelection()
    }

    public var repositories: [String] {
        Array(Set(pullRequests.map(\\.repository))).sorted()
    }

    public var visiblePullRequests: [PullRequest] {
        guard let selectedRepository else { return [] }
        return pullRequests.filter { $0.repository == selectedRepository }
    }

    public var hasMultipleRepositories: Bool {
        repositories.count > 1
    }

    public mutating func update(pullRequests: [PullRequest]) {
        self.pullRequests = pullRequests
        normalizeSelection()
    }

    public mutating func selectNextRepository() {
        selectRepository(offset: 1)
    }

    public mutating func selectPreviousRepository() {
        selectRepository(offset: -1)
    }

    private mutating func selectRepository(offset: Int) {
        let repositories = repositories
        guard !repositories.isEmpty else {
            selectedRepository = nil
            return
        }

        guard let selectedRepository,
              let currentIndex = repositories.firstIndex(of: selectedRepository)
        else {
            self.selectedRepository = repositories[0]
            return
        }

        let nextIndex = (currentIndex + offset + repositories.count) % repositories.count
        self.selectedRepository = repositories[nextIndex]
    }

    private mutating func normalizeSelection() {
        let repositories = repositories
        guard !repositories.isEmpty else {
            selectedRepository = nil
            return
        }

        if let selectedRepository, repositories.contains(selectedRepository) {
            return
        }

        selectedRepository = repositories[0]
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test`

Expected: all `GHCoreTests` pass.

### Task 2: Menu Store And UI Wiring

**Files:**
- Modify: `Sources/GHMenuBar/GHMenuBarApp.swift`

- [ ] **Step 1: Update store state**

Change `LoadState.loaded([PullRequest])` to `LoadState.loaded(PullRequestRepositorySelection)`. Add computed properties and selection methods:

```swift
var selection: PullRequestRepositorySelection? {
    guard case .loaded(let selection) = state else { return nil }
    return selection
}

var visiblePullRequests: [PullRequest] {
    selection?.visiblePullRequests ?? []
}

func selectNextRepository() {
    updateLoadedSelection { $0.selectNextRepository() }
}

func selectPreviousRepository() {
    updateLoadedSelection { $0.selectPreviousRepository() }
}

private func updateLoadedSelection(_ update: (inout PullRequestRepositorySelection) -> Void) {
    guard case .loaded(var selection) = state else { return }
    update(&selection)
    state = .loaded(selection)
}
```

In `refresh()`, preserve the current selected repository:

```swift
let selectedRepository = selection?.selectedRepository
let pullRequests = try await client.fetchOpenPullRequests()
state = .loaded(PullRequestRepositorySelection(
    pullRequests: pullRequests,
    selectedRepository: selectedRepository
))
```

- [ ] **Step 2: Update menu rendering**

In `menuBarTitle`, count `selection.visiblePullRequests`.

In `content`, use `store.visiblePullRequests` for the loaded list and keep the existing empty state when the filtered list is empty.

In `header`, add previous and next icon buttons and a selected repo label when a loaded selection has at least one repository:

```swift
if let selection = store.selection,
   let selectedRepository = selection.selectedRepository {
    HStack(spacing: 6) {
        Button {
            store.selectPreviousRepository()
        } label: {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .disabled(!selection.hasMultipleRepositories)
        .help("Previous repository")

        Text(selectedRepository)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 160)

        Button {
            store.selectNextRepository()
        } label: {
            Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
        .disabled(!selection.hasMultipleRepositories)
        .help("Next repository")
    }
}
```

- [ ] **Step 3: Build and test**

Run: `swift test`

Expected: all tests pass and the executable target compiles.
