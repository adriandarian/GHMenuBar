# Review Actionable PRs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Filter the menu bar app to PRs that still need the current user's review.

**Architecture:** Keep GitHub decoding and review actionability in `GHCore`, then have `PullRequestStore` expose only actionable selected-repository PRs to the SwiftUI menu. Repository-scoped fetches include commit metadata so the model can compare the latest commit against the user's latest review.

**Tech Stack:** Swift 6 package, XCTest, GitHub CLI JSON.

---

### Task 1: Model Review Actionability

**Files:**
- Modify: `Sources/GHCore/PullRequest.swift`
- Test: `Tests/GHCoreTests/GitHubCLITests.swift`

- [x] Write failing tests for `PullRequest.needsReview(from:)`.
- [x] Run `swift test --filter GitHubCLITests/testPullRequestNeedsReview`.
- [x] Add latest commit and reviewer timestamp data to `PullRequestReviewSummary`.
- [x] Implement `PullRequest.needsReview(from:)`.
- [x] Run the focused tests again.

### Task 2: Decode Commit And Review Timestamps

**Files:**
- Modify: `Sources/GHCore/GitHubCLI.swift`
- Modify: `Sources/GHCore/PullRequest.swift`
- Test: `Tests/GHCoreTests/GitHubCLITests.swift`

- [x] Write failing tests for repository command JSON fields and decoded timestamps.
- [x] Run `swift test --filter GitHubCLITests/testRepositoryOpenPullRequestCommandUsesRepoQualifier`.
- [x] Add `commits` to repository-scoped `gh pr list --json`.
- [x] Decode `latestReviews.submittedAt` and `commits.committedDate`.
- [x] Run the focused tests again.

### Task 3: Apply Filter In The Menu Store

**Files:**
- Modify: `Sources/GHMenuBar/GHMenuBarApp.swift`

- [x] Update `PullRequestStore.visiblePullRequests` and `menuBarTitle` to use `needsReview(from:)`.
- [x] Update empty-state copy to describe no review-needed PRs.
- [x] Run `swift test`.
