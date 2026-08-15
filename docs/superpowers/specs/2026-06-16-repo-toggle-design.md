# Repo Toggle For Open Pull Requests

## Context

GHMenuBar is a native macOS menu bar app backed by the local `gh` CLI. At the time of this design, it fetched open pull requests for one hard-coded owner and rendered one flat list. The app had no existing settings or persistence layer.

## Goal

Let the user toggle through repositories in the chosen organization, showing pull requests for one repository at a time.

Only open, non-draft pull requests are in scope. Closed, merged, and draft pull requests must not appear, and repositories with no matching pull requests should not appear in the toggle.

## Approach

Use the existing organization-wide pull request search as the single source of truth. Add a draft exclusion to the `gh search prs` command, then derive the available repositories from the returned pull requests.

This keeps the feature fast and avoids fetching every repository in the organization. It also means the repo toggle reflects the actionable PR queue instead of the full org repository catalog.

## Behavior

- On refresh, fetch open non-draft pull requests for the configured org.
- Group returned pull requests by `repository.nameWithOwner`.
- Sort repository names for stable previous/next navigation.
- Track the selected repository index in the menu store.
- Display only pull requests for the selected repository.
- Show previous and next controls in the header when more than one repository is available.
- Let the user search within repositories that currently have open non-draft pull requests.
- Show matching repositories while a search query is present, and switch repositories only when the user chooses a match.
- Keep previous and next controls available; using them clears the search query and moves through the full repository list.
- If the selected repository disappears after refresh, fall back to the first available repository.
- If no matching pull requests exist, show the existing empty state.

## Data Flow

`GitHubCLI` fetches open non-draft pull requests from `gh`. `PullRequestStore` owns the loaded list, computes available repositories, tracks selection, and exposes filtered pull requests to the SwiftUI menu. The view renders the selected repo label, navigation controls, and the filtered list.

## Error Handling

Existing CLI failure behavior remains unchanged. Command failures, process failures, and invalid JSON still surface through the failed load state. Repo selection controls are disabled or hidden when there are no repositories to select.

## Testing

Core tests should cover:

- `gh search prs` includes open state and draft exclusion.
- PR fetching still maps JSON into `PullRequest`.
- Store selection preserves the selected repo when it remains available.
- Store selection falls back when the selected repo disappears.
- Previous and next repo selection wraps through the available repo list.
- Repository search matches repo names case-insensitively.
- Selecting a searched repository updates the visible pull request list.
